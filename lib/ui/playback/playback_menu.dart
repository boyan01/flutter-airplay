// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared card menus for playback actions and crop settings.
class PlaybackMenu<T> extends StatefulWidget {
  const PlaybackMenu({
    super.key,
    required this.tooltip,
    required this.child,
    required this.items,
    required this.onSelected,
    this.onOpened,
    this.onCanceled,
    this.width = 220,
  });
  final String tooltip;
  final Widget child;
  final List<PopupMenuEntry<T>> items;
  final ValueChanged<T> onSelected;
  final VoidCallback? onOpened, onCanceled;
  final double width;
  @override
  State<PlaybackMenu<T>> createState() => _PlaybackMenuState<T>();
}

class _PlaybackMenuState<T> extends State<PlaybackMenu<T>> {
  final _focus = FocusNode();
  final _anchor = GlobalKey();
  bool _menuOpen = false;
  bool _keyboardInteraction = false;
  PopupRoute<dynamic>? _route;

  bool _keyUsed(KeyEvent event) {
    if (event is KeyDownEvent) _keyboardInteraction = true;
    return false;
  }

  void _closed() {
    HardwareKeyboard.instance.removeHandler(_keyUsed);
    _route = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_keyboardInteraction) {
        _focus.requestFocus();
      } else {
        _focus.unfocus(disposition: UnfocusDisposition.previouslyFocusedChild);
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_keyUsed);
    final route = _route;
    if (route != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    _focus.dispose();
    super.dispose();
  }

  Future<void> _open() async {
    if (_menuOpen) return;
    _focus.requestFocus();
    FocusManager.instance.applyFocusChangesIfNeeded();
    HardwareKeyboard.instance.addHandler(_keyUsed);
    setState(() => _menuOpen = true);
    widget.onOpened?.call();
    final colors = Theme.of(context).colorScheme;
    final menuHeight = widget.items.fold<double>(
      12,
      (height, item) => height + item.height,
    );
    final anchor = _anchor.currentContext!.findRenderObject()! as RenderBox;
    final overlay =
        Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
    var position = RelativeRect.fill;
    final value = await showMenu<T>(
      context: context,
      positionBuilder: (menuContext, constraints) {
        final route = ModalRoute.of(menuContext);
        if (route is PopupRoute) _route = route;
        if (!anchor.attached || !overlay.attached) return position;
        final origin = anchor.localToGlobal(Offset.zero, ancestor: overlay);
        position = RelativeRect.fromRect(
          Rect.fromLTWH(
            origin.dx,
            origin.dy - menuHeight - 8,
            anchor.size.width,
            anchor.size.height,
          ),
          Offset.zero & overlay.size,
        );
        return position;
      },
      constraints: BoxConstraints.tightFor(
        width: math.min(widget.width, MediaQuery.sizeOf(context).width - 32),
      ),
      menuPadding: const EdgeInsets.all(6),
      color: colors.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: .18),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: colors.outlineVariant.withValues(alpha: .5)),
      ),
      clipBehavior: Clip.antiAlias,
      requestFocus: true,
      items: widget.items,
    );
    if (!mounted) return;
    _closed();
    setState(() => _menuOpen = false);
    if (value == null) {
      widget.onCanceled?.call();
    } else {
      widget.onSelected(value);
    }
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (_) => _keyboardInteraction = false,
    child: Focus(
      focusNode: _focus,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            {
              LogicalKeyboardKey.enter,
              LogicalKeyboardKey.select,
              LogicalKeyboardKey.space,
            }.contains(event.logicalKey)) {
          _keyboardInteraction = true;
          _open();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Semantics(
        container: true,
        button: true,
        expanded: _menuOpen,
        child: Tooltip(
          message: widget.tooltip,
          child: InkWell(
            key: _anchor,
            canRequestFocus: false,
            onTap: _open,
            borderRadius: BorderRadius.circular(12),
            child: widget.child,
          ),
        ),
      ),
    ),
  );
}

PopupMenuItem<T> playbackMenuItem<T>(
  BuildContext context, {
  Key? key,
  required T value,
  required String label,
  required IconData icon,
  bool selected = false,
  bool enabled = true,
  bool television = false,
}) {
  final theme = Theme.of(context);
  final colors = theme.colorScheme;
  final foreground = !enabled
      ? colors.onSurface.withValues(alpha: .38)
      : selected
      ? colors.primary
      : colors.onSurface;
  final height = math.max(
    television ? 56.0 : 48.0,
    MediaQuery.textScalerOf(context)
                .scale(theme.textTheme.bodyMedium!.fontSize!) *
            1.5 +
        20,
  );
  return PopupMenuItem<T>(
    key: key,
    value: value,
    enabled: enabled,
    height: height,
    padding: EdgeInsets.zero,
    child: Semantics(
      selected: selected,
      child: Container(
        height: height,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: selected ? colors.primary.withValues(alpha: .1) : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(icon, size: 20, color: foreground),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: foreground,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 20,
              child: selected
                  ? Icon(Icons.check_rounded, size: 20, color: foreground)
                  : null,
            ),
          ],
        ),
      ),
    ),
  );
}
