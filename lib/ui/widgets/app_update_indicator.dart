// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../platform/app_updates.dart';

class AppUpdateIndicator extends StatelessWidget {
  const AppUpdateIndicator({
    super.key,
    required this.status,
    required this.tooltip,
    required this.onPressed,
    this.progress,
    this.dark = false,
  });

  final UpdateStatus status;
  final String tooltip;
  final VoidCallback onPressed;
  final double? progress;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final color = dark ? Colors.white : Theme.of(context).colorScheme.primary;
    final busy = switch (status) {
      UpdateStatus.checking ||
      UpdateStatus.downloading ||
      UpdateStatus.extracting ||
      UpdateStatus.installing => true,
      _ => false,
    };
    final ready = status == UpdateStatus.ready;
    final value =
        progress?.isFinite == true &&
            (status == UpdateStatus.downloading ||
                status == UpdateStatus.extracting)
        ? progress!.clamp(0.0, 1.0)
        : null;
    final icon = ready
        ? Icons.check_rounded
        : status == UpdateStatus.installing
        ? Icons.restart_alt_rounded
        : Icons.arrow_downward_rounded;

    return IconButton(
      key: const Key('appUpdateIndicator'),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      style: IconButton.styleFrom(
        foregroundColor: color,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      icon: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: color.withValues(alpha: ready ? .14 : .07),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: .10)),
        ),
        child: Stack(
          alignment: Alignment.center,
          children: [
            if (busy)
              SizedBox(
                width: 25,
                height: 25,
                child: CircularProgressIndicator(
                  key: const Key('appUpdateIndicatorProgress'),
                  value: value,
                  color: color,
                  backgroundColor: color.withValues(alpha: .15),
                  strokeWidth: 2,
                  strokeCap: StrokeCap.round,
                ),
              ),
            Icon(icon, size: busy ? 14 : 18),
            if (status == UpdateStatus.available)
              Positioned(
                top: 4,
                right: 4,
                child: Container(
                  width: 4,
                  height: 4,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
