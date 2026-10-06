// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../platform/launch_at_login.dart';
import '../widgets/receiver_strings.dart';

class LaunchAtLoginTile extends StatefulWidget {
  const LaunchAtLoginTile({super.key, this.service = const LaunchAtLogin()});
  final LaunchAtLogin service;

  @override
  State<LaunchAtLoginTile> createState() => _LaunchAtLoginTileState();
}

class _LaunchAtLoginTileState extends State<LaunchAtLoginTile>
    with WidgetsBindingObserver {
  bool? _enabled;
  bool _busy = false, _unsupported = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_run());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_run());
  }

  Future<void> _run([bool? requested]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final actual = requested == null
          ? await widget.service.isEnabled()
          : await widget.service.setEnabled(requested);
      if (!mounted) return;
      setState(() {
        _enabled = actual;
        _unsupported = false;
        if (requested != null && actual != requested) {
          _error = 'loginNotApplied';
        }
      });
    } catch (error) {
      if (!mounted) return;
      // A failed write can have partially succeeded; always reconcile by reading.
      bool? actual;
      Object? readError;
      try {
        actual = await widget.service.isEnabled();
      } catch (error) {
        readError = error;
      }
      if (!mounted) return;
      setState(() {
        final approvalRequired =
            (error is PlatformException && error.code == 'approval_required') ||
            (readError is PlatformException &&
                readError.code == 'approval_required');
        _enabled = approvalRequired ? false : actual;
        _unsupported =
            error is MissingPluginException ||
            (error is PlatformException && error.code == 'unsupported');
        _error = _unsupported
            ? 'loginUnavailable'
            : approvalRequired
            ? 'loginNotApplied'
            : 'loginError';
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = l10n(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const Key('launchAtLogin'),
          contentPadding: EdgeInsets.zero,
          title: Text(strings.launchAtLogin),
          subtitle: Text(strings.launchAtLoginHelp),
          value: _enabled ?? false,
          onChanged: _busy || _unsupported || _enabled == null
              ? null
              : (value) => unawaited(_run(value)),
        ),
        if (_busy) const LinearProgressIndicator(key: Key('loginLoading')),
        if (_error != null)
          Text(switch (_error) {
            'loginUnavailable' => strings.loginUnavailable,
            'loginNotApplied' => strings.loginNotApplied,
            _ => strings.loginError,
          }, style: TextStyle(color: Theme.of(context).colorScheme.error)),
        if (!_busy && _error == 'loginNotApplied')
          TextButton(
            key: const Key('cancelLoginRequest'),
            onPressed: () => unawaited(_run(false)),
            child: Text(strings.cancelLoginRequest),
          ),
        if (!_busy && !_unsupported)
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const Key('refreshLogin'),
              onPressed: () => unawaited(_run()),
              child: Text(strings.refreshLogin),
            ),
          ),
      ],
    );
  }
}
