// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as native;
import 'package:window_manager/window_manager.dart' as desktop;

enum WindowCommand {
  closeWindow,
  minimizeWindow,
  toggleMaximize,
  toggleFullscreen,
  exitFullscreen,
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
}

/// System interaction stays here; navigation and focus stay in the shared UI.
class WindowController {
  const WindowController();
  static const _channel = MethodChannel('tech.soit.flutterairplay/window');

  Future<void> execute(WindowCommand command) =>
      _channel.invokeMethod<void>(command.name);

  Future<void> setStrings(Map<String, String> strings) =>
      _channel.invokeMethod<void>('setStrings', strings);

  Future<void> setMode({
    required bool playing,
    required int width,
    required int height,
  }) => _channel.invokeMethod<void>('setMode', {
    'mode': playing ? 'player' : 'home',
    'width': width,
    'height': height,
  });

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

  void startDragging(String platform) {
    if (platform == 'windows') {
      _channel.invokeMethod<void>('startDragging');
    } else if (platform == 'linux') {
      desktop.windowManager.startDragging();
    } else {
      final window = native.WindowManager.instance.getCurrent();
      if (window != null && !window.isFullScreen) window.startDragging();
    }
  }
}
