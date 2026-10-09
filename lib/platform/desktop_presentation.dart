// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import '../l10n/generated/app_localizations.dart';
import '../receiver/receiver_model.dart';
import 'window_controller.dart';
import 'app_updates.dart';
import '../ui/widgets/app_update_strings.dart';
import 'desktop_window_sizing.dart';
import 'desktop_tray_icon.dart';

/// Owns desktop presentation resources for one mounted receiver screen.
/// The receiver remains the source of truth for settings and playback state.
class DesktopPresentation {
  DesktopPresentation({
    required this.window,
    required this.model,
    required this.onAction,
    required this.onError,
    this.updates,
  });

  final void Function(PlatformException) onError;
  final WindowController window;
  final ReceiverModel model;
  final AppUpdates? updates;
  final Future<void> Function(WindowAction, bool) onAction;
  native.TrayIcon? _tray;
  native.Menu? _menu;
  final _items = <native.MenuItem>[];
  final _itemListeners = <int>[];
  final _visibleItems = <int>[];
  final _images = <native.Image>[];
  int? _trayListener, _menuListener, _windowListener, _windowId;
  Timer? _autoHide;
  Future<void> _pending = Future.value();
  bool _ready = false, _disposed = false, _playing = false;
  bool _openedForSession = false, _expanded = false, _transitioning = false;
  bool _fullscreen = false, _trayVisible = false;
  bool _menuOpen = false;
  String _signature = '';
  late final _sizing = DesktopWindowSizing(
    window,
    initiallyEnabled: false,
    integerGeometry: model.platform == 'linux',
  );
  AppLocalizations? _strings;

  @visibleForTesting
  native.Menu? get menuForTesting => _menu;

  Future<void> update(AppLocalizations strings, {bool reduceMotion = false}) {
    _strings = strings;
    if (_disposed || !model.loaded || !model.supportsWindowPreferences) {
      return Future.value();
    }
    final geometry = _sizing.update(
      connected: model.status == 'streaming',
      width: model.hasVideo ? model.videoWidth : 0,
      height: model.hasVideo ? model.videoHeight : 0,
      reduceMotion: reduceMotion,
    );
    final signature = jsonEncode([
      strings.localeName,
      model.receivingName,
      model.status,
      model.message,
      model.clientName,
      model.hasVideo,
      model.videoWidth,
      model.videoHeight,
      model.audioPlaying,
      model.videoPaused,
      model.busy,
      model.desktopOptions,
      updates?.initialized,
      updates?.enabled,
      updates?.status.name,
      updates?.version,
      updates?.canCheck,
      updates?.canShowUpdate,
    ]);
    if (signature == _signature) {
      return Future.wait([_pending, geometry]).then((_) {});
    }
    _signature = signature;
    // Serialize creation and updates; receiver events can arrive during PNG encoding.
    final operation = _pending.then((_) async {
      if (_disposed) return;
      if (!_ready) {
        try {
          if (!await window.initializeDesktop() || _disposed) return;
          if (!ui.isRunningOnPlatformThread) {
            throw PlatformException(
              code: 'platform_thread_required',
              message: 'Desktop callbacks require the platform thread',
            );
          }
          await _createTray();
          if (_disposed) return;
          await window.withWindow((value) {
            _windowId = value.id;
          });
          if (_disposed) return;
          _windowListener = native.WindowManager.instance.addListener((event) {
            if (event.windowId == _windowId &&
                (event is native.WindowResizedEvent ||
                    event is native.WindowMovedEvent)) {
              Timer.run(() {
                if (!_disposed) {
                  unawaited(
                    _sizing.observeWindow().catchError((Object error) {
                      if (!_disposed && error is PlatformException) {
                        onError(error);
                      }
                    }),
                  );
                }
              });
            }
            if (event.windowId == _windowId &&
                (event is native.WindowMaximizedEvent ||
                    event is native.WindowRestoredEvent)) {
              // Leave the native callback before querying or changing the window.
              Timer.run(() {
                if (!_disposed) {
                  unawaited(
                    onAction(WindowAction.nativeWindowStateChanged, false),
                  );
                }
              });
            }
          });
          // A visible icon alone is not enough: its Open and Quit actions must
          // be available before the host commits to a background-only launch.
          _updateMenu();
          _ready = true;
          _trayVisible = await window.finishDesktopStartup(
            trayAvailable: _trayVisible,
          );
          if (_disposed) return;
          await window.setClosePolicy(canHide);
        } catch (_) {
          _ready = false;
          _releaseResources();
          try {
            await window.setClosePolicy(false);
          } finally {
            await window.finishDesktopStartup(trayAvailable: false);
          }
          rethrow;
        }
      }
      await _sizing.enable();
      await geometry;
      await _apply();
    });
    // Keep the queue usable after errors; return the failure to the UI caller.
    _pending = operation.catchError((Object _) {
      _signature = '';
    });
    return Future.wait([operation, geometry]).then((_) {});
  }

  Future<void> _createTray() async {
    if (!native.TrayManager.instance.isSupported()) return;
    // One shared symbol and state palette, encoded in memory for all desktop hosts.
    for (final color in [
      0xffa0a9ae,
      0xff32958a,
      0xffe4b55e,
      0xff20bfa9,
      0xfff06a6a,
    ]) {
      final image = await createDesktopTrayIcon(ui.Color(color));
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (_disposed) return;
      final nativeImage = bytes == null
          ? null
          : native.Image.fromBase64(
              base64Encode(
                bytes.buffer.asUint8List(
                  bytes.offsetInBytes,
                  bytes.lengthInBytes,
                ),
              ),
            );
      if (nativeImage == null) {
        throw PlatformException(
          code: 'tray_icon_failed',
          message: 'Unable to create tray icon',
        );
      }
      _images.add(nativeImage);
    }
    _tray = native.TrayIcon.create();
    if (_tray == null) {
      throw PlatformException(
        code: 'tray_unavailable',
        message: 'Unable to create tray',
      );
    }
    _tray!.iconSize = const native.Size(width: 22, height: 22);
    _tray!.isIconTemplate = model.platform == 'macos';
    _tray!.setContextMenuTrigger(
      model.platform == 'macos'
          ? native.ContextMenuTrigger.clicked
          : native.ContextMenuTrigger.rightClicked,
    );
    _trayListener = _tray!.addListener((event) {
      if (event is native.TrayIconRightClickedEvent &&
          model.platform == 'macos') {
        Timer.run(() {
          if (!_disposed) _tray?.openContextMenu();
        });
      } else if (event is native.TrayIconClickedEvent &&
          model.platform != 'macos') {
        Timer.run(() {
          if (!_disposed) unawaited(onAction(WindowAction.openApp, false));
        });
      }
    });
    _tray!.icon = _images[1];
    _trayVisible = _tray!.setVisible(true);
    if (!_trayVisible) {
      throw PlatformException(
        code: 'tray_unavailable',
        message: 'Unable to show tray',
      );
    }
  }

  Future<void> _apply() async {
    if (_disposed) return;
    final playing = model.hasVideo;
    await window.withWindow((value) {
      value.isAlwaysOnTop =
          playing &&
          !_transitioning &&
          !value.isFullScreen &&
          model.desktopOptions['alwaysOnTop']!;
    });
    if (playing && !_playing) {
      _autoHide?.cancel();
      bool hidden = false;
      await window.withWindow((value) {
        hidden = !value.isVisible || value.isMinimized;
      });
      if (hidden && model.desktopOptions['showOnConnect']!) {
        await show(userInitiated: false);
        _openedForSession = true;
      }
      if (model.desktopOptions['fullscreenOnConnect']!) {
        await window.execute(WindowCommand.enterFullscreen);
      }
    } else if (!playing && _playing && _openedForSession) {
      _autoHide?.cancel();
      _autoHide = Timer(const Duration(seconds: 3), () {
        if (!_disposed && !model.hasVideo && _openedForSession && canHide) {
          unawaited(
            hide().catchError((Object error) {
              if (!_disposed && error is PlatformException) onError(error);
            }),
          );
        }
      });
    }
    _playing = playing;
    if (_disposed) return;
    _updateMenu();
    await window.setClosePolicy(canHide);
  }

  bool get canHide => _trayVisible && model.desktopOptions['keepInMenuBar']!;

  Future<void> show({bool userInitiated = true}) async {
    if (!_ready || _disposed) return;
    if (userInitiated) {
      _autoHide?.cancel();
      _openedForSession = false;
    }
    await window.setDockVisible(true);
    if (_disposed) return;
    await window.withWindow((value) {
      if (value.isMinimized) value.restore();
      value.show();
      value.focus();
    });
    if (!_transitioning) await _sizing.resume();
  }

  Future<void> hide() async {
    if (!canHide || _disposed) return;
    _autoHide?.cancel();
    _openedForSession = false;
    await window.withWindow((value) => value.hide());
    await window.setDockVisible(false);
  }

  Future<void> resize({bool actualSize = false}) async {
    if (!_ready || _transitioning || _disposed) return;
    await _sizing.fit(actualSize: actualSize);
  }

  void transitionStarted() {
    _transitioning = true;
    _sizing.suspend();
  }

  Future<bool> stateChanged({bool transitionCompleted = false}) async {
    if (_transitioning && !transitionCompleted) return _expanded;
    if (!_ready || _disposed) return false;
    bool expanded = false;
    await window.withWindow((value) {
      _fullscreen = value.isFullScreen;
      expanded = _fullscreen || value.isMaximized;
      final onTop =
          model.hasVideo &&
          !_fullscreen &&
          model.desktopOptions['alwaysOnTop']!;
      // nativeapi 0.4's X11 getter reads GDK state, which omits EWMH ABOVE.
      // Apply the desired state on Linux even when that getter says false.
      if (model.platform == 'linux' || value.isAlwaysOnTop != onTop) {
        value.isAlwaysOnTop = onTop;
      }
    });
    _transitioning = false;
    _expanded = expanded;
    if (!expanded) await _sizing.resume();
    if (!_disposed) _updateMenu();
    return expanded;
  }

  void _updateMenu() {
    final tray = _tray, strings = _strings;
    if (tray == null || strings == null) return;
    // Keep item identities stable while a native popup is open.
    if (_menu == null) {
      _menu = native.Menu.create();
      if (_menu == null) {
        throw PlatformException(
          code: 'tray_menu_failed',
          message: 'Unable to create tray menu',
        );
      }
      void add(
        WindowAction? action, {
        native.MenuItemType type = native.MenuItemType.normal,
      }) {
        final item = native.MenuItem.createWithLabelAndType('', type);
        if (item == null) {
          throw PlatformException(
            code: 'tray_menu_failed',
            message: 'Unable to create tray menu item',
          );
        }
        _items.add(item);
        _itemListeners.add(
          action == null
              ? 0
              : item.addListener((event) {
                  if (event is native.MenuItemClickedEvent) {
                    Timer.run(() {
                      if (!_disposed) unawaited(onAction(action, false));
                    });
                  }
                }),
        );
      }

      add(null);
      add(null);
      add(null, type: native.MenuItemType.separator);
      add(WindowAction.openApp);
      add(WindowAction.disconnectSession);
      add(WindowAction.toggleReceiver);
      add(null, type: native.MenuItemType.separator);
      add(WindowAction.toggleFullscreen);
      add(WindowAction.toggleOnTop, type: native.MenuItemType.checkbox);
      add(null, type: native.MenuItemType.separator);
      add(WindowAction.openSettings);
      add(WindowAction.openLogs);
      add(null, type: native.MenuItemType.separator);
      // Exit stays on the host so receiver teardown completes before termination.
      add(WindowAction.quitApp);
      add(WindowAction.checkForUpdates);
      _menuListener = _menu!.addListener((event) {
        if (event is native.MenuOpenedEvent) _menuOpen = true;
        if (event is native.MenuClosedEvent) {
          _menuOpen = false;
          Timer.run(() {
            if (!_disposed) _updateMenu();
          });
        }
      });
    }
    final transitioning = {
      'checking',
      'starting',
      'stopping',
    }.contains(model.status);
    final client = model.clientName;
    final status = switch (model.status) {
      'error' => strings.receiverFailed,
      'checking' => strings.loading,
      'starting' => strings.starting,
      'stopping' => strings.stopping,
      'streaming' =>
        model.videoPaused
            ? strings.videoPaused
            : model.hasVideo
            ? strings.mirroring
            : model.audioPlaying
            ? strings.audioPlaying
            : strings.connectionInProgress,
      'waiting' => strings.waitingForConnection,
      _ => strings.off,
    };
    final statusLabel = model.status == 'streaming' && client != null
        ? '$status · $client'
        : status;
    final labels = [
      model.receivingName,
      statusLabel,
      '',
      strings.showWindow,
      strings.disconnectConnection,
      model.active ? strings.stopReceiver : strings.startReceiver,
      '',
      _fullscreen ? strings.exitFullscreen : strings.enterFullscreen,
      strings.alwaysOnTop,
      '',
      '${strings.settings}…',
      '${strings.viewLogs}…',
      '',
      strings.quitApp,
      updates == null
          ? strings.checkForUpdates
          : updateActionLabel(strings, updates!, tray: true),
    ];
    for (var i = 0; i < _items.length; i++) {
      _items[i].label = labels[i];
      _items[i].isEnabled = switch (i) {
        0 || 1 => false,
        4 => model.status == 'streaming' && model.canStop,
        5 => !transitioning && (model.canStart || model.canStop),
        7 => model.hasVideo,
        8 => model.hasVideo && model.editable,
        14 => updates != null && updates!.initialized,
        _ => true,
      };
    }
    _items[8].state = model.desktopOptions['alwaysOnTop']!
        ? native.MenuItemState.checked
        : native.MenuItemState.unchecked;
    // Native menus have no shared visibility property. Keep item identities and
    // positions stable during tracking, then reconcile membership after closing.
    if (!_menuOpen) {
      final visible = [
        0,
        1,
        2,
        3,
        if (model.status == 'streaming') 4,
        5,
        if (model.hasVideo) ...[6, 7, 8],
        9,
        10,
        if (model.platform == 'macos' && updates != null) 14,
        11,
        12,
        13,
      ];
      for (var i = _visibleItems.length - 1; i >= 0; i--) {
        if (!visible.contains(_visibleItems[i])) {
          _menu!.removeItem(_items[_visibleItems.removeAt(i)]);
        }
      }
      for (var i = 0; i < visible.length; i++) {
        if (i >= _visibleItems.length || _visibleItems[i] != visible[i]) {
          _menu!.insertItem(i, _items[visible[i]]);
          _visibleItems.insert(i, visible[i]);
        }
      }
      // Linux's exported D-Bus menu only announces changes when reattached.
      // Publish the populated menu, and defer refreshes while it is tracking.
      tray.setContextMenu(_menu);
    }
    tray.setTooltip('${model.receivingName} · $statusLabel');
    final index = model.status == 'error'
        ? 4
        : transitioning ||
              (model.status == 'streaming' &&
                  !model.hasVideo &&
                  !model.audioPlaying)
        ? 2
        : model.hasVideo || model.audioPlaying
        ? 3
        : model.active
        ? 1
        : 0;
    tray.isIconTemplate = model.platform == 'macos' && index < 3;
    tray.icon = _images[index];
  }

  Future<void> dispose() {
    if (_disposed) return _pending;
    _disposed = true;
    _sizing.dispose();
    _autoHide?.cancel();
    if (_ready) unawaited(window.setClosePolicy(false));
    _releaseResources();
    // Let in-flight initialization finish before releasing the window wrapper.
    return _pending;
  }

  void _releaseResources() {
    if (_windowListener != null) {
      native.WindowManager.instance.removeListener(_windowListener!);
      _windowListener = null;
    }
    final tray = _tray;
    if (tray != null) {
      if (_trayListener != null) tray.removeListener(_trayListener!);
      tray.setVisible(false);
      tray.setContextMenu(null);
      tray.dispose();
    }
    for (var i = 0; i < _items.length; i++) {
      if (_itemListeners[i] != 0) _items[i].removeListener(_itemListeners[i]);
    }
    if (_menuListener != null) _menu?.removeListener(_menuListener!);
    _menu?.clear();
    _menu?.dispose();
    for (final item in _items) {
      item.dispose();
    }
    for (final image in _images) {
      image.dispose();
    }
    _tray = null;
    _menu = null;
    _trayListener = null;
    _menuListener = null;
    _menuOpen = false;
    _trayVisible = false;
    _items.clear();
    _visibleItems.clear();
    _itemListeners.clear();
    _images.clear();
  }
}
