// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:mixin_logger/mixin_logger.dart';
import 'package:nativeapi/nativeapi.dart' as native;

import 'window_controller.dart';

/// Session geometry, separate from tray/menu refreshes. Connection boundaries
/// are recorded synchronously, even when several receiver events share a frame.
class DesktopWindowSizing {
  DesktopWindowSizing(
    this.window, {
    bool initiallyEnabled = true,
    this.integerGeometry = false,
  }) : _enabled = initiallyEnabled;

  final WindowController window;
  final bool integerGeometry;
  Future<void> _pending = Future.value();
  bool _connected = false, _disposed = false, _suspended = false;
  bool _reduceMotion = false, _applying = false, _actualSize = false;
  bool _dirty = false;
  bool _enabled;
  int _width = 0, _height = 0, _revision = 0, _scheduled = 0;
  int _correctedRevision = -1;
  native.Rectangle? _baseline, _lastApplied;
  native.Size? _baselineMinimum;
  double _baselineAspect = 0;
  double? _manualArea;
  double? _appliedRatio;

  Future<void> update({
    required bool connected,
    required int width,
    required int height,
    bool reduceMotion = false,
  }) {
    if (_disposed) return Future.value();
    final boundary = connected != _connected;
    final motionChanged = reduceMotion != _reduceMotion;
    _reduceMotion = reduceMotion;
    if (boundary) {
      _connected = connected;
      _width = _height = 0;
      _manualArea = null;
      _appliedRatio = null;
      _actualSize = false;
      // Keep an outstanding baseline across an immediate disconnect/reconnect.
      // It must never be replaced by the previous device's video rectangle.
    }
    final validVideo = connected && width > 0 && height > 0;
    final changed = validVideo && (width != _width || height != _height);
    if (validVideo) {
      _width = width;
      _height = height;
    }
    // A decoder reset, pause or audio-only interval is not a session end.
    if (!boundary && !changed && !motionChanged) {
      return _dirty && _scheduled == 0 ? _schedule() : _pending;
    }
    return _schedule();
  }

  Future<void> enable() {
    if (_enabled) return _pending;
    _enabled = true;
    return _schedule();
  }

  void suspend() {
    _suspended = true;
    _revision++;
  }

  Future<void> resume() {
    if (!_suspended && _scheduled > 0) return _pending;
    _suspended = false;
    return _schedule();
  }

  Future<void> fit({bool actualSize = false}) {
    _manualArea = null;
    _appliedRatio = null;
    _actualSize = actualSize;
    return _schedule();
  }

  /// Native resize events include our own writes. Compare with the final
  /// applied geometry rather than treating every callback as user intent.
  Future<void> observeWindow() async {
    if (_disposed || _applying || _suspended || _baseline == null) return;
    await window.withWindow((value) {
      if (_disposed || _applying || _suspended || _expanded(value)) return;
      if (_lastApplied != null && !_same(value.bounds, _lastApplied!)) {
        final size = value.contentSize;
        if (_connected &&
            size.width > 0 &&
            size.height > 0 &&
            ((value.bounds.width - _lastApplied!.width).abs() > 2 ||
                (value.bounds.height - _lastApplied!.height).abs() > 2)) {
          _manualArea = size.width * size.height;
          _actualSize = false;
        }
        _lastApplied = value.bounds;
      }
    });
  }

  bool _expanded(native.Window value) =>
      value.isFullScreen || value.isMaximized || value.isMinimized;

  Future<void> _schedule() {
    _dirty = true;
    final revision = ++_revision;
    _scheduled++;
    final operation = _pending
        .then((_) async {
          if (_disposed || !_enabled || revision != _revision || _suspended) {
            return;
          }
          await _apply(revision);
        })
        .whenComplete(() => _scheduled--);
    _pending = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> _apply(int revision) async {
    native.Rectangle? from, target;
    native.Size? minimum;
    double aspect = 0;
    bool restore = false;
    final connected = _connected;
    final width = _width, height = _height;
    final ratio = width > 0 && height > 0 ? width / height : null;
    final hasCurrentVideo = connected && ratio != null;
    // Coalesce transient orientation reports. First video and disconnect are
    // immediate; a newer request cancels this one before any native write.
    if (connected && _appliedRatio != null && ratio != _appliedRatio) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    if (_disposed || revision != _revision || _suspended) return;
    await window.withWindow((value) {
      if (_disposed ||
          revision != _revision ||
          _suspended ||
          _expanded(value) ||
          !value.isVisible) {
        return; // Deferred, never recorded as successfully applied.
      }
      if (!hasCurrentVideo && _baseline == null) {
        _dirty = false;
        return;
      }
      final displays = window.getDisplays();
      try {
        if (displays.isEmpty) {
          throw PlatformException(
            code: 'display_unavailable',
            message: 'No display is available',
          );
        }
        final current = value.bounds;
        final reference = !hasCurrentVideo ? _baseline! : current;
        final display = displays.reduce(
          (a, b) =>
              _overlap(reference, a.workArea) >= _overlap(reference, b.workArea)
              ? a
              : b,
        );
        final work = display.workArea;
        from = current;
        if (!hasCurrentVideo) {
          restore = true;
          target = _clamp(_baseline!, work);
          minimum = native.Size(
            width: math.min(_baselineMinimum!.width, work.width),
            height: math.min(_baselineMinimum!.height, work.height),
          );
          aspect = _baselineAspect;
        } else {
          if (_baseline == null) {
            _baseline = current;
            final nativeMinimum = value.minimumSize;
            // Wrapped GTK windows do not import the runner's initial hints.
            // Fall back to the application's idle minimum when it is missing.
            _baselineMinimum = native.Size(
              width: nativeMinimum.width > 0
                  ? nativeMinimum.width
                  : math.min(360, current.width),
              height: nativeMinimum.height > 0
                  ? nativeMinimum.height
                  : math.min(480, current.height),
            );
            _baselineAspect = value.aspectRatio;
          }
          final content = value.contentSize;
          // Resolution-only updates must not enlarge a manually sized window.
          if (_appliedRatio != null &&
              (ratio - _appliedRatio!).abs() < .001 &&
              content.height > 0 &&
              (content.width / content.height - ratio).abs() < .003 &&
              !_actualSize) {
            _lastApplied = current;
            _dirty = false;
            return;
          }
          final borderWidth = math.max(0.0, current.width - content.width);
          final borderHeight = math.max(0.0, current.height - content.height);
          final availableWidth = math.max(1.0, work.width - borderWidth);
          final availableHeight = math.max(1.0, work.height - borderHeight);
          final fitWidth = math.min(
            availableWidth * .8,
            availableHeight * .8 * ratio,
          );
          var contentWidth = _manualArea == null
              ? fitWidth
              : math.sqrt(_manualArea! * ratio);
          if (_actualSize) {
            contentWidth = width / math.max(1, display.scaleFactor);
          }
          contentWidth = math.min(
            contentWidth,
            math.min(availableWidth, availableHeight * ratio),
          );
          var contentHeight = contentWidth / ratio;
          if (integerGeometry) {
            // GTK sizes are integer logical pixels. Derive height from the
            // realizable width so portrait rounding cannot miss by several px.
            contentWidth = math.max(1, contentWidth.floorToDouble());
            contentHeight = math.max(1, (contentWidth / ratio).floorToDouble());
          }
          final frameWidth = contentWidth + borderWidth;
          final frameHeight = contentHeight + borderHeight;
          target = _clamp(
            native.Rectangle(
              x: current.x + (current.width - frameWidth) / 2,
              y: current.y + (current.height - frameHeight) / 2,
              width: frameWidth,
              height: frameHeight,
            ),
            work,
          );
          // GTK implicitly uses the minimum as its aspect-ratio base. A
          // square minimum conflicts with non-square video in X11 WMs (e.g.
          // Openbox). Keep the content minimum on the same aspect-ratio line.
          if (integerGeometry) {
            final divisor = width.gcd(height);
            final unitWidth = width ~/ divisor, unitHeight = height ~/ divisor;
            final maximumScale = math
                .min(contentWidth / unitWidth, contentHeight / unitHeight)
                .floor();
            final scale = math.min(
              maximumScale,
              (160 / math.min(unitWidth, unitHeight)).ceil(),
            );
            // A fractional minimum is truncated by GTK, recreating the base
            // mismatch. Use an exact integer ratio, or no explicit minimum if
            // even its smallest basis cannot fit this undecorated GTK window.
            minimum = scale <= 0
                ? const native.Size(width: 0, height: 0)
                : native.Size(
                    width: unitWidth * scale + borderWidth,
                    height: unitHeight * scale + borderHeight,
                  );
          } else {
            final minimumScale = math.min(
              1.0,
              160 / math.min(contentWidth, contentHeight),
            );
            minimum = native.Size(
              width: contentWidth * minimumScale + borderWidth,
              height: contentHeight * minimumScale + borderHeight,
            );
          }
          aspect = ratio;
        }
      } finally {
        for (final display in displays) {
          display.dispose();
        }
      }
    });
    if (target == null || from == null || revision != _revision || _disposed) {
      return;
    }
    _applying = true;
    _appliedRatio = null;
    try {
      // GTK applies resize requests asynchronously. Changing geometry hints on
      // every tick (or immediately after the final resize) can replace a pending
      // resize. Relax constraints once, animate geometry, then lock the final
      // aspect only after the actual window has reached its target.
      var deferred = false;
      await window.withWindow((value) {
        if (_disposed ||
            revision != _revision ||
            _suspended ||
            _expanded(value) ||
            !value.isVisible) {
          deferred = true;
          return;
        }
        if (value.aspectRatio != 0) value.aspectRatio = 0;
        final transitionalMinimum = native.Size(
          width: math.min(minimum!.width, from!.width),
          height: math.min(minimum!.height, from!.height),
        );
        if (value.minimumSize != transitionalMinimum) {
          value.minimumSize = transitionalMinimum;
        }
      });
      if (deferred || _disposed || revision != _revision) return;
      // Let native constraint updates leave the platform event queue before
      // issuing a resize, including the reduced-motion single-write path.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      i(
        '[Window geometry] video=${width}x$height connected=$connected '
        'from=$from target=$target restore=$restore',
      );
      // One frame rectangle per tick, not separate content-size/position writes.
      // nativeapi's animate flag is macOS-only; use this bounded common path.
      final duration = _reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 200);
      final clock = Stopwatch()..start();
      while (true) {
        if (_disposed || revision != _revision || _suspended) return;
        final progress = duration == Duration.zero
            ? 1.0
            : (clock.elapsedMicroseconds / duration.inMicroseconds).clamp(
                0.0,
                1.0,
              );
        final eased = 1 - math.pow(1 - progress, 3).toDouble();
        deferred = false;
        await window.withWindow((value) {
          if (_disposed ||
              revision != _revision ||
              _suspended ||
              _expanded(value) ||
              !value.isVisible) {
            deferred = true;
            return;
          }
          value.bounds = _interpolate(from!, target!, eased);
          _lastApplied = value.bounds;
        });
        if (deferred || revision != _revision || _disposed) return;
        if (progress == 1) break;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      // Both verification phases share one budget and at most one final snap.
      final settling = Stopwatch()..start();
      if (!await _settle(revision, target!, settling)) return;
      deferred = false;
      await window.withWindow((value) {
        if (_disposed ||
            revision != _revision ||
            _suspended ||
            _expanded(value) ||
            !value.isVisible) {
          deferred = true;
          return;
        }
        if (value.minimumSize != minimum) value.minimumSize = minimum!;
        if (value.aspectRatio != aspect) value.aspectRatio = aspect;
      });
      if (deferred) return;
      // The final native constraints can themselves cause a configure event.
      await Future<void>.delayed(const Duration(milliseconds: 32));
      if (!await _settle(revision, target!, settling)) return;
      _dirty = false;
      if (restore) {
        _baseline = null;
        _baselineMinimum = null;
        _lastApplied = null;
        _manualArea = null;
        _appliedRatio = null;
      } else {
        _appliedRatio = ratio;
      }
    } finally {
      _applying = false;
    }
  }

  Future<bool> _settle(
    int revision,
    native.Rectangle target,
    Stopwatch clock,
  ) async {
    const stableInterval = Duration(milliseconds: 64);
    Stopwatch? stableTarget, stableMismatch;
    native.Rectangle? observed, previousMismatch;
    while (clock.elapsed < const Duration(seconds: 1)) {
      if (_disposed || revision != _revision || _suspended) return false;
      var deferred = false;
      await window.withWindow((value) {
        if (_disposed ||
            revision != _revision ||
            _suspended ||
            _expanded(value) ||
            !value.isVisible) {
          deferred = true;
          return;
        }
        observed = value.bounds;
      });
      if (deferred || _disposed || revision != _revision) return false;
      if (observed != null && _same(observed!, target)) {
        stableMismatch = null;
        previousMismatch = null;
        stableTarget ??= Stopwatch()..start();
        // A single matching allocation can precede a late native configure.
        if (stableTarget.elapsed >= stableInterval) {
          _lastApplied = observed;
          return true;
        }
      } else if (observed != null) {
        stableTarget = null;
        if (previousMismatch == null || !_same(observed!, previousMismatch)) {
          stableMismatch = Stopwatch()..start();
        }
        previousMismatch = observed;
        if (_correctedRevision != revision &&
            stableMismatch!.elapsed >= stableInterval) {
          // Recover one overwritten/dropped final resize without restarting
          // animation or altering the session baseline. Persistent refusal
          // still fails within the original shared deadline.
          await window.withWindow((value) {
            if (_disposed ||
                revision != _revision ||
                _suspended ||
                _expanded(value) ||
                !value.isVisible) {
              deferred = true;
              return;
            }
            if (clock.elapsed >= const Duration(seconds: 1)) return;
            _correctedRevision = revision;
            value.bounds = target;
          });
          if (deferred || _disposed || revision != _revision) return false;
          stableMismatch = null;
          previousMismatch = null;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    if (_disposed || revision != _revision || _suspended) return false;
    final message =
        'Window resize did not settle: target=$target actual=$observed';
    w(message);
    throw PlatformException(code: 'window_resize_failed', message: message);
  }

  static double _overlap(native.Rectangle a, native.Rectangle b) =>
      math.max(0, math.min(a.x + a.width, b.x + b.width) - math.max(a.x, b.x)) *
      math.max(
        0,
        math.min(a.y + a.height, b.y + b.height) - math.max(a.y, b.y),
      );

  static native.Rectangle _clamp(
    native.Rectangle bounds,
    native.Rectangle work,
  ) {
    final width = math.min(bounds.width, work.width);
    final height = math.min(bounds.height, work.height);
    return native.Rectangle(
      x: bounds.x.clamp(work.x, work.x + work.width - width),
      y: bounds.y.clamp(work.y, work.y + work.height - height),
      width: width,
      height: height,
    );
  }

  static bool _same(native.Rectangle a, native.Rectangle b) =>
      (a.x - b.x).abs() <= 2 &&
      (a.y - b.y).abs() <= 2 &&
      (a.width - b.width).abs() <= 2 &&
      (a.height - b.height).abs() <= 2;

  static native.Rectangle _interpolate(
    native.Rectangle a,
    native.Rectangle b,
    double t,
  ) => t == 1
      ? b
      : native.Rectangle(
          x: a.x + (b.x - a.x) * t,
          y: a.y + (b.y - a.y) * t,
          width: a.width + (b.width - a.width) * t,
          height: a.height + (b.height - a.height) * t,
        );

  void dispose() {
    _disposed = true;
    _revision++;
  }
}
