// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:nativeapi/nativeapi.dart' as native;

final _gtkWindow = ffi.DynamicLibrary.process()
    .lookupFunction<
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>),
      ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>)
    >('gtk_widget_get_window');
final _xid = ffi.DynamicLibrary.process()
    .lookupFunction<
      ffi.UnsignedLong Function(ffi.Pointer<ffi.Void>),
      int Function(ffi.Pointer<ffi.Void>)
    >('gdk_x11_window_get_xid');

/// Check the real WM state, not nativeapi 0.4's known-false GDK ABOVE getter.
/// Linux desktop integration requires X11 and xprop, supplied by the shared
/// desktop runner. This neither focuses a window nor changes any WM property.
Future<bool> readWindowAlwaysOnTop(native.Window window) async {
  if (!Platform.isLinux) return window.isAlwaysOnTop;
  final xid = _xid(_gtkWindow(window.nativeObject));
  if (xid == 0) {
    throw StateError(
      'The Linux desktop integration suite requires an X11 window',
    );
  }
  final result = await Process.run('xprop', [
    '-id',
    '0x${xid.toRadixString(16)}',
    '_NET_WM_STATE',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Cannot read the test window WM state: ${result.stderr}');
  }
  return RegExp(r'\b_NET_WM_STATE_ABOVE\b').hasMatch(result.stdout.toString());
}
