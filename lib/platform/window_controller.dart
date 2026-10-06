// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi' as ffi;
import 'dart:math' as math;
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

  Future<void> setClosePolicy(bool hide) =>
      _channel.invokeMethod<void>('setClosePolicy', hide);

  Future<void> setDockVisible(bool visible) =>
      _channel.invokeMethod<void>('setDockVisible', visible);

  Future<void> setMode({
    required bool playing,
    required int width,
    required int height,
    bool actualSize = false,
  }) => withWindow((window) {
    if (window.isFullScreen || window.isMaximized) return;
    final displays = getDisplays();
    try {
      if (displays.isEmpty) {
        throw PlatformException(
          code: 'display_unavailable',
          message: 'No display is available',
        );
      }
      final previous = window.bounds;
      // Prefer the monitor containing most of the window, including negative origins.
      double overlap(native.Display display) {
        final area = display.workArea;
        return math.max(
              0,
              math.min(previous.x + previous.width, area.x + area.width) -
                  math.max(previous.x, area.x),
            ) *
            math.max(
              0,
              math.min(previous.y + previous.height, area.y + area.height) -
                  math.max(previous.y, area.y),
            );
      }

      final display = displays.reduce(
        (a, b) => overlap(a) >= overlap(b) ? a : b,
      );
      final video = playing && width > 0 && height > 0;
      final target = fitBounds(
        previous: previous,
        workArea: display.workArea,
        videoWidth: video ? width : 0,
        videoHeight: video ? height : 0,
        scaleFactor: display.scaleFactor,
        actualSize: actualSize,
      );
      window.aspectRatio = 0;
      window.minimumSize = video
          ? const native.Size(width: 160, height: 160)
          : native.Size(
              width: math.min(360, display.workArea.width),
              height: math.min(480, display.workArea.height),
            );
      window.contentSize = native.Size(
        width: target.width,
        height: target.height,
      );
      if (video) window.aspectRatio = width / height;
      // Content and frame sizes differ on decorated hosts.
      final frame = window.size;
      final work = display.workArea;
      window.position = native.Point(
        x: (previous.x + previous.width / 2 - frame.width / 2).clamp(
          work.x,
          math.max(work.x, work.x + work.width - frame.width),
        ),
        y: (previous.y + previous.height / 2 - frame.height / 2).clamp(
          work.y,
          math.max(work.y, work.y + work.height - frame.height),
        ),
      );
    } finally {
      for (final display in displays) {
        display.dispose();
      }
    }
  });

  static native.Rectangle fitBounds({
    required native.Rectangle previous,
    required native.Rectangle workArea,
    required int videoWidth,
    required int videoHeight,
    double scaleFactor = 1,
    bool actualSize = false,
  }) {
    double width = math.min(440, workArea.width),
        height = math.min(560, workArea.height);
    if (videoWidth > 0 && videoHeight > 0) {
      final ratio = videoWidth / videoHeight;
      final fitWidth = math.min(
        workArea.width * .8,
        workArea.height * .8 * ratio,
      );
      width = actualSize
          ? math.min(videoWidth / math.max(1, scaleFactor), fitWidth)
          : fitWidth;
      height = width / ratio;
    }
    return native.Rectangle(
      x: (previous.x + (previous.width - width) / 2).clamp(
        workArea.x,
        math.max(workArea.x, workArea.x + workArea.width - width),
      ),
      y: (previous.y + (previous.height - height) / 2).clamp(
        workArea.y,
        math.max(workArea.y, workArea.y + workArea.height - height),
      ),
      width: width,
      height: height,
    );
  }

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
