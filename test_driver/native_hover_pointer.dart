// SPDX-License-Identifier: GPL-3.0-or-later
// Real OS cursor events for an opt-in, isolated desktop integration test.
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _Point extends Struct {
  @Double()
  external double x;
  @Double()
  external double y;
}

final class _WinPoint extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

class NativeHoverPointer {
  NativeHoverPointer() {
    if (Platform.isMacOS) {
      _library = DynamicLibrary.open(
        '/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics',
      );
      final allowed = _library.lookupFunction<Bool Function(), bool Function()>(
        'CGPreflightPostEventAccess',
      )();
      if (!allowed) {
        throw StateError(
          'Native hover testing requires existing macOS input-posting permission; no permission is requested automatically.',
        );
      }
    } else if (Platform.isWindows) {
      _library = DynamicLibrary.open('user32.dll');
    } else if (Platform.isLinux) {
      if (Platform.environment['XDG_SESSION_TYPE'] == 'wayland') {
        throw StateError(
          'This native cursor fixture requires X11, not Wayland.',
        );
      }
      _library = DynamicLibrary.open('libX11.so.6');
      _display = _library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Utf8>),
            Pointer<Void> Function(Pointer<Utf8>)
          >('XOpenDisplay')(nullptr);
      if (_display == nullptr) throw StateError('No X11 display available');
    } else {
      throw UnsupportedError('Desktop pointer injection only');
    }
  }

  late final DynamicLibrary _library;
  Pointer<Void> _display = nullptr;

  double scaleForWindow(Pointer<Void> handle) {
    if (Platform.isWindows) {
      return _library.lookupFunction<
            Uint32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('GetDpiForWindow')(handle) /
          96;
    }
    if (Platform.isLinux) {
      return DynamicLibrary.open('libgtk-3.so.0')
          .lookupFunction<
            Int32 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('gtk_widget_get_scale_factor')(handle)
          .toDouble();
    }
    return 1;
  }

  ({double x, double y}) get position {
    if (Platform.isWindows) {
      final point = calloc<_WinPoint>();
      try {
        if (_library.lookupFunction<
              Int32 Function(Pointer<_WinPoint>),
              int Function(Pointer<_WinPoint>)
            >('GetCursorPos')(point) ==
            0) {
          throw StateError('GetCursorPos failed');
        }
        return (x: point.ref.x.toDouble(), y: point.ref.y.toDouble());
      } finally {
        calloc.free(point);
      }
    }
    if (Platform.isMacOS) {
      final event = _library
          .lookupFunction<
            Pointer<Void> Function(Pointer<Void>),
            Pointer<Void> Function(Pointer<Void>)
          >('CGEventCreate')(nullptr);
      if (event == nullptr) throw StateError('CGEventCreate failed');
      final point = _library
          .lookupFunction<
            _Point Function(Pointer<Void>),
            _Point Function(Pointer<Void>)
          >('CGEventGetLocation')(event);
      final result = (x: point.x, y: point.y);
      DynamicLibrary.open(
        '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
      ).lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('CFRelease')(event);
      return result;
    }
    final roots = calloc<Uint64>(2);
    final coordinates = calloc<Int32>(4);
    final mask = calloc<Uint32>();
    try {
      final root = _library
          .lookupFunction<
            Uint64 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('XDefaultRootWindow')(_display);
      final success =
          _library.lookupFunction<
            Int32 Function(
              Pointer<Void>,
              Uint64,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Uint32>,
            ),
            int Function(
              Pointer<Void>,
              int,
              Pointer<Uint64>,
              Pointer<Uint64>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Int32>,
              Pointer<Uint32>,
            )
          >('XQueryPointer')(
            _display,
            root,
            roots,
            roots + 1,
            coordinates,
            coordinates + 1,
            coordinates + 2,
            coordinates + 3,
            mask,
          );
      if (success == 0) throw StateError('XQueryPointer failed');
      return (x: coordinates[0].toDouble(), y: coordinates[1].toDouble());
    } finally {
      calloc.free(roots);
      calloc.free(coordinates);
      calloc.free(mask);
    }
  }

  void move(double x, double y) {
    if (Platform.isWindows) {
      final result = _library
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'SetCursorPos',
          )(x.round(), y.round());
      if (result == 0) throw StateError('SetCursorPos failed');
    } else if (Platform.isMacOS) {
      final point = calloc<_Point>();
      try {
        point.ref.x = x;
        point.ref.y = y;
        final event = _library
            .lookupFunction<
              Pointer<Void> Function(Pointer<Void>, Uint32, _Point, Uint32),
              Pointer<Void> Function(Pointer<Void>, int, _Point, int)
            >('CGEventCreateMouseEvent')(nullptr, 5, point.ref, 0);
        if (event == nullptr) {
          throw StateError('CGEventCreateMouseEvent failed');
        }
        _library.lookupFunction<
          Void Function(Uint32, Pointer<Void>),
          void Function(int, Pointer<Void>)
        >('CGEventPost')(0, event);
        DynamicLibrary.open(
          '/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation',
        ).lookupFunction<
          Void Function(Pointer<Void>),
          void Function(Pointer<Void>)
        >('CFRelease')(event);
      } finally {
        calloc.free(point);
      }
    } else {
      final root = _library
          .lookupFunction<
            Uint64 Function(Pointer<Void>),
            int Function(Pointer<Void>)
          >('XDefaultRootWindow')(_display);
      _library.lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Uint64,
          Uint64,
          Int32,
          Int32,
          Uint32,
          Uint32,
          Int32,
          Int32,
        ),
        int Function(Pointer<Void>, int, int, int, int, int, int, int, int)
      >('XWarpPointer')(_display, 0, root, 0, 0, 0, 0, x.round(), y.round());
      _library.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XFlush')(_display);
    }
  }

  void dispose() {
    if (_display != nullptr) {
      _library.lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('XCloseDisplay')(_display);
    }
  }
}
