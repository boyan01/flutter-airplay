// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import '../l10n/generated/app_localizations.dart';
import '../receiver/receiver_model.dart';
import 'window_controller.dart';

/// Owns desktop presentation resources for one mounted receiver screen.
/// The receiver remains the source of truth for settings and playback state.
class DesktopPresentation {
  DesktopPresentation({
    required this.window,
    required this.model,
    required this.onAction,
    required this.onError,
  });

  final void Function(PlatformException) onError;
  final WindowController window;
  final ReceiverModel model;
  final Future<void> Function(WindowAction, bool) onAction;
  native.TrayIcon? _tray;
  native.Menu? _menu;
  final _items = <native.MenuItem>[];
  final _itemListeners = <int>[];
  final _images = <native.Image>[];
  int? _trayListener, _windowListener, _windowId;
  Timer? _autoHide;
  Future<void> _pending = Future.value();
  bool _ready = false, _disposed = false, _playing = false;
  bool _openedForSession = false, _expanded = false, _transitioning = false;
  bool _fullscreen = false, _trayVisible = false;
  String _signature = '', _mode = '';
  AppLocalizations? _strings;

  Future<void> update(AppLocalizations strings) {
    _strings = strings;
    if (_disposed || !model.loaded || !model.supportsWindowPreferences) {
      return Future.value();
    }
    final signature = jsonEncode([
      strings.localeName,
      model.name,
      model.status,
      model.message,
      model.clientName,
      model.hasVideo,
      model.videoWidth,
      model.videoHeight,
      model.audioPlaying,
      model.desktopOptions,
    ]);
    if (signature == _signature) return _pending;
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
          _windowListener = native.WindowManager.instance.addListener((event) {
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
      await _apply();
    });
    // Keep the queue usable after errors; return the failure to the UI caller.
    _pending = operation.catchError((Object _) {
      _signature = '';
    });
    return operation;
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
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final paint = ui.Paint()
        ..color = ui.Color(color)
        ..strokeWidth = 3
        ..style = ui.PaintingStyle.stroke;
      canvas.drawPath(
        ui.Path()
          ..moveTo(9, 22)
          ..lineTo(4, 22)
          ..lineTo(4, 5)
          ..lineTo(28, 5)
          ..lineTo(28, 22)
          ..lineTo(23, 22),
        paint,
      );
      paint.style = ui.PaintingStyle.fill;
      canvas.drawPath(
        ui.Path()
          ..moveTo(16, 17)
          ..lineTo(5, 28)
          ..lineTo(27, 28)
          ..close(),
        paint,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(32, 32);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
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
    final mode = '$playing:${model.videoWidth}:${model.videoHeight}';
    if (_mode != mode) {
      await resize();
      _mode = mode;
    }
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
            hide(disconnect: false).catchError((Object error) {
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
  }

  Future<void> hide({bool disconnect = true}) async {
    if (!canHide || _disposed) return;
    _autoHide?.cancel();
    _openedForSession = false;
    await window.withWindow((value) => value.hide());
    await window.setDockVisible(false);
    if (!_disposed && disconnect && model.status == 'streaming') {
      await model.disconnect();
    }
  }

  Future<void> resize({bool actualSize = false}) async {
    if (!_ready || _transitioning || _disposed) return;
    await window.setMode(
      playing: model.hasVideo,
      width: model.videoWidth,
      height: model.videoHeight,
      actualSize: actualSize,
    );
  }

  void transitionStarted() => _transitioning = true;

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
      // nativeapi 0.4's Linux getter can report false for an X11 ABOVE window.
      // Apply the desired state there even when its cached getter agrees.
      if (model.platform == 'linux' || value.isAlwaysOnTop != onTop) {
        value.isAlwaysOnTop = onTop;
      }
    });
    final restore = _transitioning || (_expanded && !expanded);
    _transitioning = false;
    _expanded = expanded;
    if (restore && !expanded) await resize();
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
      void add(String label, WindowAction? action, {bool checked = false}) {
        final item = native.MenuItem.createWithLabelAndType(
          label,
          checked ? native.MenuItemType.checkbox : native.MenuItemType.normal,
        );
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
        _menu!.addItem(item);
      }

      add('', null);
      add('', null);
      add('', null);
      _menu!.addSeparator();
      add('', WindowAction.openApp);
      add('', WindowAction.toggleReceiver, checked: true);
      add('', WindowAction.disconnectSession);
      _menu!.addSeparator();
      add('', WindowAction.toggleFullscreen);
      add('', WindowAction.actualSize);
      add('', WindowAction.fitScreen);
      add('', WindowAction.toggleOnTop, checked: true);
      _menu!.addSeparator();
      add('', WindowAction.openSettings);
      add('', WindowAction.openLogs);
      _menu!.addSeparator();
      // Exit stays on the host so receiver teardown completes before termination.
      add('', WindowAction.quitApp);
      tray.setContextMenu(_menu);
    }
    final transitioning = {
      'checking',
      'starting',
      'stopping',
    }.contains(model.status);
    final status = model.status == 'error'
        ? model.message
        : model.hasVideo
        ? strings.playing
        : model.audioPlaying
        ? strings.audioPlaying
        : transitioning
        ? strings.starting
        : model.active
        ? strings.discoverable
        : strings.off;
    final labels = [
      model.name,
      status,
      model.hasVideo ? '${model.videoWidth} × ${model.videoHeight}' : '',
      model.hasVideo ? strings.showPlayer : strings.openApp,
      strings.receive,
      strings.disconnect,
      _fullscreen ? strings.exitFullscreen : strings.enterFullscreen,
      strings.actualSize,
      strings.fitScreen,
      strings.alwaysOnTop,
      strings.settings,
      strings.logs,
      strings.quitApp,
    ];
    for (var i = 0; i < _items.length; i++) {
      _items[i].label = labels[i];
      _items[i].isEnabled = switch (i) {
        0 || 1 || 2 => false,
        4 => !transitioning,
        5 => model.status == 'streaming',
        7 || 8 => model.hasVideo && !_expanded,
        9 => model.hasVideo,
        _ => true,
      };
    }
    _items[4].state = model.active
        ? native.MenuItemState.checked
        : native.MenuItemState.unchecked;
    _items[9].state = model.desktopOptions['alwaysOnTop']!
        ? native.MenuItemState.checked
        : native.MenuItemState.unchecked;
    tray.setTooltip('${model.name} · $status');
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

  void dispose() {
    _disposed = true;
    _autoHide?.cancel();
    if (_ready) unawaited(window.setClosePolicy(false));
    _releaseResources();
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
    _trayVisible = false;
    _items.clear();
    _itemListeners.clear();
    _images.clear();
  }
}
