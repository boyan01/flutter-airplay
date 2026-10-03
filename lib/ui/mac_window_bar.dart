// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import 'receiver_strings.dart';

/// Flutter owns the window surface; AppKit only executes window operations.
class MacWindowBar extends StatelessWidget {
  const MacWindowBar({super.key, required this.title, this.dark = false});
  final String title;
  final bool dark;
  static const channel = MethodChannel('org.flutterairplay/window');

  Future<void> _command(String method, [Object? arguments]) async {
    await channel.invokeMethod<void>(method, arguments);
  }

  Widget _button(
    String key,
    String tooltip,
    Color color,
    IconData icon,
    String method,
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
        onPressed: () => _command(method),
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

  @override
  Widget build(BuildContext context) => SizedBox(
    key: const Key('macWindowBar'),
    height: 36,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _button(
            'windowClose',
            l10n(context).close,
            const Color(0xffff5f57),
            Icons.close,
            'closeWindow',
          ),
          _button(
            'windowMinimize',
            l10n(context).minimize,
            const Color(0xffffbd2e),
            Icons.remove,
            'minimizeWindow',
          ),
          _button(
            'windowFullscreen',
            l10n(context).fullscreen,
            const Color(0xff28c840),
            Icons.fullscreen,
            'toggleFullscreen',
          ),
          Expanded(
            child: GestureDetector(
              key: const Key('windowDragArea'),
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) {
                final window = native.WindowManager.instance.getCurrent();
                if (window != null && !window.isFullScreen) {
                  window.startDragging();
                }
              },
              onDoubleTap: () => _command('toggleFullscreen'),
              child: Align(
                alignment: Alignment.center,
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
          const SizedBox(width: 8),
        ],
      ),
    ),
  );
}
