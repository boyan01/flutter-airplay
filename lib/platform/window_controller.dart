// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui' show isRunningOnPlatformThread, runOnPlatformThread;

import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:nativeapi/nativeapi.dart' as native;

enum WindowCommand {
  closeWindow,
  minimizeWindow,
  toggleMaximize,
  toggleFullscreen,
  enterFullscreen,
  exitFullscreen,
  startDragging,
  titlebarDoubleClick,
  quitApp,
  requestBackgroundLaunch,
  openAppSettings,
}

enum WindowAction {
  openSettings,
  openLogs,
  toggleReceiver,
  disconnectSession,
  toggleOnTop,
  windowStateChanged,
  toggleFullscreen,
  enterFullscreen,
  minimizeWindow,
  toggleMaximize,
  openApp,
  closeRequested,
  actualSize,
  fitScreen,
  windowTransitionStarted,
  nativeWindowStateChanged,
  quitApp,
  checkForUpdates,
  updateCheckDue,
}

/// System interaction stays here; navigation and focus stay in the shared UI.
class WindowController {
  const WindowController({
    this.withWindow = _withNativeWindow,
    this.getDisplays = _getDisplays,
  });

  final List<native.Display> Function() getDisplays;
  static List<native.Display> _getDisplays() =>
      native.DisplayManager.instance.getAll();

  final Future<void> Function(void Function(native.Window)) withWindow;
  static const _channel = MethodChannel('tech.soit.flutterairplay/window');
  static Future<int>? _applicationWindowHandle;
  static native.Window? _applicationWindow;

  // The host channel owns the runner window, not injected window adapters.
  bool get usesNativeResize =>
      Platform.isMacOS && withWindow == _withNativeWindow;

  Future<bool> resizeBounds(native.Rectangle bounds, Duration duration) async =>
      await _channel.invokeMethod<bool>('resizeWindow', {
        'x': bounds.x,
        'y': bounds.y,
        'width': bounds.width,
        'height': bounds.height,
        'duration': duration.inMicroseconds / 1000000,
      }) ==
      true;

  Future<void> cancelResize() =>
      _channel.invokeMethod<void>('cancelWindowResize');

  static Future<int> _getApplicationWindowHandle() async {
    final handle = await _channel.invokeMethod<int>('getNativeWindowHandle');
    if (handle == null || handle == 0) {
      throw PlatformException(
        code: 'window_unavailable',
        message: 'The application window has not been created',
      );
    }
    return handle;
  }

  Future<void> execute(WindowCommand command) async {
    switch (command) {
      case WindowCommand.minimizeWindow:
      case WindowCommand.toggleMaximize:
      case WindowCommand.toggleFullscreen:
      case WindowCommand.enterFullscreen:
      case WindowCommand.exitFullscreen:
      case WindowCommand.startDragging:
        await withWindow((window) {
          switch (command) {
            case WindowCommand.minimizeWindow:
              window.minimize();
            case WindowCommand.toggleMaximize:
              if (window.isFullScreen) {
                window.isFullScreen = false;
              } else if (window.isMaximized) {
                window.unmaximize();
              } else {
                window.maximize();
              }
            case WindowCommand.toggleFullscreen:
              if (!window.isFullScreen) window.isAlwaysOnTop = false;
              window.isFullScreen = !window.isFullScreen;
            case WindowCommand.enterFullscreen:
              window.isAlwaysOnTop = false;
              window.isFullScreen = true;
            case WindowCommand.exitFullscreen:
              window.isFullScreen = false;
            case WindowCommand.startDragging:
              if (!window.isFullScreen) window.startDragging();
            default:
              break;
          }
        });
      default:
        // Closing must preserve receiver cleanup and the tray policy.
        // nativeapi 0.4 has no window-close operation.
        await _channel.invokeMethod<void>(command.name);
    }
  }

  static Future<void> _withNativeWindow(
    void Function(native.Window) action,
  ) async {
    // AppKit can synchronously deliver another engine frame while resizing.
    // Leave Flutter's begin/draw frame pair before entering a native window call.
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      await Future<void>(() => _withNativeWindow(action));
      return;
    }
    // Bind the runner's window once. An active-window query cannot find a
    // hidden window, and can target a different window when focus changes.
    late int handle;
    if (_applicationWindow == null) {
      final handleFuture = _applicationWindowHandle ??=
          _getApplicationWindowHandle();
      try {
        handle = await handleFuture;
      } catch (_) {
        if (identical(_applicationWindowHandle, handleFuture)) {
          _applicationWindowHandle = null;
        }
        rethrow;
      }
    }
    // The host lookup can complete during a new frame. Check again after the
    // asynchronous boundary before calling APIs that can pump OS messages.
    if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
      await Future<void>(() => _withNativeWindow(action));
      return;
    }
    void apply() {
      final window = _applicationWindow ??=
          native.Window.createWithNativeWindow(
            ffi.Pointer<ffi.Void>.fromAddress(handle),
          );
      if (window == null) {
        throw PlatformException(
          code: 'window_unavailable',
          message: 'No application window is available',
        );
      }
      action(window);
    }

    // Merged engines already run Dart on the platform thread. Their platform
    // isolate support can be disabled, so do not call runOnPlatformThread there.
    if (isRunningOnPlatformThread) {
      apply();
      return;
    }
    await runOnPlatformThread(apply);
  }

  Future<void> releaseNativeWindow() async {
    if (withWindow != _withNativeWindow) return;
    _applicationWindowHandle = null;
    void release() {
      _applicationWindow?.dispose();
      _applicationWindow = null;
    }

    if (isRunningOnPlatformThread) {
      release();
    } else {
      await runOnPlatformThread(release);
    }
  }

  Future<void> setPlaybackOrientation({
    required bool playing,
    required int width,
    required int height,
  }) => _channel.invokeMethod<void>('setPlaybackOrientation', {
    'playing': playing,
    'width': width,
    'height': height,
  });

  Future<bool> initializeDesktop() async =>
      await _channel.invokeMethod<bool>('desktopReady') == true;

  /// Complete startup only after the tray and its Open/Quit menu are usable.
  /// Hosts keep a fallback timer until this decision reaches them.
  Future<bool> finishDesktopStartup({required bool trayAvailable}) async =>
      await _channel.invokeMethod<bool>(
        'finishDesktopStartup',
        trayAvailable,
      ) ==
      true;

  Future<void> setClosePolicy(bool hide) =>
      _channel.invokeMethod<void>('setClosePolicy', hide);

  Future<void> setDockVisible(bool visible) =>
      _channel.invokeMethod<void>('setDockVisible', visible);

  void listen(
    Future<void> Function(WindowAction action, bool expanded)? handler,
  ) {
    _channel.setMethodCallHandler(
      handler == null
          ? null
          : (call) async {
              final action = WindowAction.values
                  .where((value) => value.name == call.method)
                  .firstOrNull;
              if (action == null) return;
              final state = call.arguments;
              final expanded =
                  state is Map &&
                  (state['maximized'] == true || state['fullscreen'] == true);
              await handler(action, expanded);
            },
    );
  }
}
