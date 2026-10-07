// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../platform/window_controller.dart';

import 'receiver_strings.dart';

/// Shared window controls delegate system operations to WindowController.
class DesktopWindowBar extends StatelessWidget {
  const DesktopWindowBar({
    super.key,
    required this.title,
    required this.platform,
    this.dark = false,
    this.maximized = false,
    this.window = const WindowController(),
  });
  static const double height = 44;
  final String title;
  final bool dark, maximized;
  final String platform;
  final WindowController window;

  Widget _button(
    String key,
    String tooltip,
    Color color,
    IconData icon,
    WindowCommand command,
  ) => Tooltip(
    message: tooltip,
    child: SizedBox(
      width: 26,
      height: height,
      child: IconButton(
        key: Key(key),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: () => window.execute(command),
        icon: Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: Icon(
            icon,
            size: 10,
            color: Colors.black54,
            semanticLabel: tooltip,
          ),
        ),
      ),
    ),
  );

  Widget _windowsButton(
    String key,
    String tooltip,
    IconData icon,
    WindowCommand command,
  ) => SizedBox(
    width: 46,
    height: height,
    child: IconButton(
      key: Key(key),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(),
        foregroundColor: dark ? Colors.white : null,
        hoverColor: key == 'windowClose' ? const Color(0xffc42b1c) : null,
      ),
      onPressed: () => window.execute(command),
      icon: Icon(icon, size: 16),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final windows = platform != 'macos';
    final titleArea = Expanded(
      child: GestureDetector(
        key: const Key('windowDragArea'),
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => window.execute(WindowCommand.startDragging),
        onDoubleTap: () => window.execute(
          windows
              ? WindowCommand.toggleMaximize
              : WindowCommand.titlebarDoubleClick,
        ),
        child: Align(
          alignment: windows ? Alignment.centerLeft : Alignment.center,
          child: Padding(
            padding: EdgeInsets.only(left: windows ? 12 : 0),
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                color: dark
                    ? Colors.white
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
    if (!windows) {
      return SizedBox(
        key: const Key('macWindowBar'),
        height: height,
        child: Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                key: const Key('windowDragArea'),
                behavior: HitTestBehavior.opaque,
                onPanStart: (_) => window.execute(WindowCommand.startDragging),
                onDoubleTap: () =>
                    window.execute(WindowCommand.titlebarDoubleClick),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 86),
                  child: Center(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: dark
                            ? Colors.white
                            : Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _button(
                      'windowClose',
                      l10n(context).close,
                      const Color(0xffff5f57),
                      Icons.close,
                      WindowCommand.closeWindow,
                    ),
                    _button(
                      'windowMinimize',
                      l10n(context).minimize,
                      const Color(0xffffbd2e),
                      Icons.remove,
                      WindowCommand.minimizeWindow,
                    ),
                    _button(
                      'windowFullscreen',
                      l10n(context).fullscreen,
                      const Color(0xff28c840),
                      Icons.fullscreen,
                      WindowCommand.toggleFullscreen,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      key: Key('${platform}WindowBar'),
      height: height,
      child: Row(
        children: [
          titleArea,
          _windowsButton(
            'windowMinimize',
            l10n(context).minimize,
            Icons.remove,
            WindowCommand.minimizeWindow,
          ),
          _windowsButton(
            'windowMaximize',
            maximized ? l10n(context).restore : l10n(context).maximize,
            maximized ? Icons.filter_none : Icons.crop_square,
            WindowCommand.toggleMaximize,
          ),
          _windowsButton(
            'windowClose',
            l10n(context).close,
            Icons.close,
            WindowCommand.closeWindow,
          ),
        ],
      ),
    );
  }
}
