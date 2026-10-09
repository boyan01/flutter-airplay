// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
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

void logDesktopPhase(String message) => debugPrintSynchronously(
  '[desktop-window ${Platform.operatingSystem} ${DateTime.now().toIso8601String()}] $message',
);

/// Keep deadlines inside runAsync so they also use real timers in widget tests.
/// Propagate errors after runAsync returns, rather than accepting its null result.
Future<T> runDesktopPhase<T>(
  WidgetTester tester,
  String phase,
  Future<T> Function() action, {
  Duration timeout = const Duration(seconds: 5),
  bool log = true,
  String Function()? details,
}) async {
  final clock = Stopwatch()..start();
  if (log) logDesktopPhase('BEGIN $phase; timeout=${timeout.inMilliseconds}ms');
  late T result;
  Object? failure;
  StackTrace? failureStack;
  await tester.runAsync(() async {
    try {
      result = await Future<T>.sync(action).timeout(
        timeout,
        onTimeout: () => throw TimeoutException(
          '$phase timed out; ${details?.call() ?? 'operation did not complete'}',
          timeout,
        ),
      );
    } catch (error, stack) {
      failure = error;
      failureStack = stack;
    }
  });
  if (failure != null) {
    logDesktopPhase(
      'FAIL $phase after ${clock.elapsedMilliseconds}ms: $failure; '
      '${details?.call() ?? ''}',
    );
    Error.throwWithStackTrace(failure!, failureStack!);
  }
  if (log) logDesktopPhase('END $phase after ${clock.elapsedMilliseconds}ms');
  return result;
}

/// Attempt every cleanup step and preserve the first failure and its stack.
Future<void> cleanUpDesktop(
  WidgetTester tester,
  List<({String phase, Future<void> Function() action})> steps,
) async {
  Object? failure;
  StackTrace? failureStack;
  for (final step in steps) {
    try {
      await runDesktopPhase(tester, 'tearDown: ${step.phase}', step.action);
    } catch (error, stack) {
      failure ??= error;
      failureStack ??= stack;
    }
  }
  if (failure != null) Error.throwWithStackTrace(failure, failureStack!);
}

/// Unlike Process.run().timeout(), this also terminates and reaps the child.
Future<ProcessResult> runDesktopProcess(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final command = '$executable ${arguments.join(' ')}';
  final clock = Stopwatch()..start();
  bool expired = false;
  final starting = Process.start(executable, arguments).then((process) {
    // Process creation itself can complete after its deadline.
    if (expired) process.kill(ProcessSignal.sigkill);
    return process;
  });
  late Process process;
  try {
    process = await starting.timeout(timeout);
  } on TimeoutException {
    expired = true;
    throw TimeoutException('Starting $command timed out', timeout);
  }
  final stdout = StringBuffer(), stderr = StringBuffer();
  final outputDone = Completer<void>(), errorDone = Completer<void>();
  final output = process.stdout
      .transform(utf8.decoder)
      .listen(
        stdout.write,
        onDone: outputDone.complete,
        onError: outputDone.completeError,
      );
  final errors = process.stderr
      .transform(utf8.decoder)
      .listen(
        stderr.write,
        onDone: errorDone.complete,
        onError: errorDone.completeError,
      );
  final exit = process.exitCode;
  try {
    final remaining = timeout - clock.elapsed;
    final results = await Future.wait<Object?>([
      exit,
      outputDone.future,
      errorDone.future,
    ]).timeout(remaining > Duration.zero ? remaining : Duration.zero);
    return ProcessResult(
      process.pid,
      results.first! as int,
      '$stdout',
      '$stderr',
    );
  } on TimeoutException {
    final killed = process.kill(ProcessSignal.sigkill);
    logDesktopPhase(
      'TIMEOUT $command; pid=${process.pid}, killed=$killed, '
      'stdout=$stdout, stderr=$stderr',
    );
    try {
      await exit.timeout(const Duration(seconds: 1));
    } on TimeoutException {
      logDesktopPhase('Process reap timed out: $command; pid=${process.pid}');
    }
    throw TimeoutException('$command timed out; pid=${process.pid}', timeout);
  } finally {
    // Pipe cancellation must not replace an earlier process failure.
    try {
      await Future.wait([output.cancel(), errors.cancel()])
          .timeout(const Duration(seconds: 1));
    } catch (error) {
      logDesktopPhase('Process pipe cleanup failed: $command; $error');
    }
  }
}

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
  final result = await runDesktopProcess('xprop', [
    '-id',
    '0x${xid.toRadixString(16)}',
    '_NET_WM_STATE',
  ]);
  if (result.exitCode != 0) {
    throw StateError('Cannot read the test window WM state: ${result.stderr}');
  }
  return RegExp(r'\b_NET_WM_STATE_ABOVE\b').hasMatch(result.stdout.toString());
}
