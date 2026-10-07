// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';

/// Keeps transient chrome available while the user is interacting with it.
class ControlInteractionRegion extends StatefulWidget {
  const ControlInteractionRegion({
    super.key,
    required this.onChanged,
    required this.child,
  });
  final ValueChanged<bool> onChanged;
  final Widget child;

  @override
  State<ControlInteractionRegion> createState() =>
      _ControlInteractionRegionState();
}

class _ControlInteractionRegionState extends State<ControlInteractionRegion> {
  bool _hovered = false, _focused = false, _reported = false;
  final _pointers = <int>{};

  void _report() {
    final active = _hovered || _focused || _pointers.isNotEmpty;
    if (active == _reported) return;
    _reported = active;
    widget.onChanged(active);
  }

  @override
  Widget build(BuildContext context) => Focus(
    canRequestFocus: false,
    onFocusChange: (value) {
      _focused = value;
      _report();
    },
    child: MouseRegion(
      onEnter: (event) {
        _hovered = event.kind == PointerDeviceKind.mouse;
        _report();
      },
      onExit: (_) {
        _hovered = false;
        _report();
      },
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (event) {
          _pointers.add(event.pointer);
          _report();
        },
        onPointerUp: (event) {
          _pointers.remove(event.pointer);
          _report();
        },
        onPointerCancel: (event) {
          _pointers.remove(event.pointer);
          _report();
        },
        child: widget.child,
      ),
    ),
  );
}
