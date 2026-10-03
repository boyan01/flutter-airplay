// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

// Keep the native button focus semantics while making TV focus visible at a distance.
class TvFocus extends StatefulWidget {
  const TvFocus({super.key, required this.child, this.outline = false});
  final Widget child;
  final bool outline;
  @override
  State<TvFocus> createState() => _TvFocusState();
}

class _TvFocusState extends State<TvFocus> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: (focused) => setState(() => _focused = focused),
    child: AnimatedScale(
      scale: _focused ? 1.05 : 1,
      duration: const Duration(milliseconds: 150),
      child: Container(
        foregroundDecoration: widget.outline
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _focused
                      ? Theme.of(context).colorScheme.primary
                      : Colors.transparent,
                  width: 3,
                ),
              )
            : null,
        child: widget.child,
      ),
    ),
  );
}
