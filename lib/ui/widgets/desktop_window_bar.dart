// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../platform/window_controller.dart';

import 'receiver_strings.dart';

/// Flutter owns the window surface; the platform host executes window operations.
class DesktopWindowBar extends StatelessWidget {
  const DesktopWindowBar({
    super.key,
    required this.title,
    required this.platform,
    this.dark = false,
    this.maximized = false,
  });
  final String title;
  final bool dark, maximized;
  final String platform;
  static const _window = WindowController();

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
      height: 32,
      child: IconButton(
        key: Key(key),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(),
        onPressed: () => _window.execute(command),
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
    height: 36,
    child: IconButton(
      key: Key(key),
      tooltip: tooltip,
      style: IconButton.styleFrom(
        shape: const RoundedRectangleBorder(),
        foregroundColor: dark ? Colors.white : null,
        hoverColor: key == 'windowClose' ? const Color(0xffc42b1c) : null,
      ),
      onPressed: () => _window.execute(command),
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
        onPanStart: (_) => _window.startDragging(platform),
        onDoubleTap: () => _window.execute(
          windows
              ? WindowCommand.toggleMaximize
              : WindowCommand.toggleFullscreen,
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
    return SizedBox(
      key: Key(windows ? '${platform}WindowBar' : 'macWindowBar'),
      height: 36,
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: windows ? 0 : 8),
        child: Row(
          children: windows
              ? [
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
                ]
              : [
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
                  titleArea,
                  const SizedBox(width: 8),
                ],
        ),
      ),
    );
  }
}
