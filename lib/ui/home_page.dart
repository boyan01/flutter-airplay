// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../receiver/receiver_model.dart';
import 'receiver_strings.dart';
import 'tv_focus.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.model,
    required this.actionFocus,
    required this.onToggle,
    required this.onSettings,
    required this.onLogs,
  });
  final ReceiverModel model;
  final FocusNode actionFocus;
  final VoidCallback onToggle, onLogs;
  final Future<void> Function({bool editName}) onSettings;
  bool get error => model.status == 'error' || model.commandError != null;
  bool get transitioning =>
      !model.loaded ||
      model.busy ||
      {'checking', 'starting', 'stopping'}.contains(model.status);

  String label(BuildContext context) => error
      ? l10n(context).unavailable
      : switch (model.status) {
          'waiting' =>
            model.isTelevision
                ? l10n(context).discoverable
                : l10n(context).ready,
          'streaming' => l10n(
            context,
          ).clientConnecting(model.clientName ?? 'iPhone'),
          'checking' || 'starting' => l10n(context).starting,
          'stopping' => l10n(context).stopping,
          _ => model.loaded ? l10n(context).off : l10n(context).loading,
        };

  Widget _start(BuildContext context) => FilledButton(
    key: const Key('start'),
    focusNode: model.canStart ? actionFocus : null,
    onPressed: model.canStart ? onToggle : null,
    child: Text(error ? l10n(context).retry : l10n(context).start),
  );

  Widget _identity(BuildContext context, {bool compact = false}) {
    final tv = model.isTelevision;
    final colors = Theme.of(context).colorScheme;
    final color = error
        ? colors.error
        : model.active
        ? colors.primary
        : colors.onSurfaceVariant;
    return Column(
      crossAxisAlignment: tv
          ? CrossAxisAlignment.start
          : CrossAxisAlignment.center,
      children: [
        if (!tv) ...[
          Container(
            width: compact ? 56 : 72,
            height: compact ? 56 : 72,
            decoration: BoxDecoration(
              color: color.withValues(alpha: .08),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(
              error ? Icons.warning_amber_rounded : Icons.airplay_rounded,
              size: compact ? 28 : 34,
              color: color,
            ),
          ),
          SizedBox(height: compact ? 12 : 20),
        ],
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                model.name,
                key: const Key('homeDeviceName'),
                textAlign: tv ? TextAlign.start : TextAlign.center,
                style: TextStyle(
                  fontSize: tv ? 28 : 20,
                  fontWeight: FontWeight.w500,
                  height: 1.3,
                ),
              ),
            ),
            if (!tv)
              IconButton(
                key: Key(
                  model.platform == 'macos' ? 'openSettings' : 'editName',
                ),
                focusNode: model.platform == 'macos' && !model.canStart
                    ? actionFocus
                    : null,
                tooltip: l10n(context).rename,
                onPressed: () => onSettings(editName: true),
                icon: const Icon(Icons.edit_outlined, size: 18),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Semantics(
          liveRegion: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (transitioning || model.status == 'streaming')
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: color,
                  ),
                )
              else
                Icon(
                  model.active ? Icons.circle : Icons.circle_outlined,
                  size: 8,
                  color: color,
                ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label(context),
                  key: const Key('statusLabel'),
                  textAlign: tv ? TextAlign.start : TextAlign.center,
                  style: TextStyle(
                    color: color,
                    fontSize: tv ? 18 : 14,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _instructions(BuildContext context) {
    final tv = model.isTelevision;
    final colors = Theme.of(context).colorScheme;
    final steps = tv
        ? [
            l10n(context).sameWifiTv,
            l10n(context).controlCenter,
            l10n(context).selectReceiver(model.name),
          ]
        : [
            l10n(context).openControlCenter,
            l10n(context).tapMirroring,
            l10n(context).selectReceiver(model.name),
          ];
    return Container(
      key: const Key('homeInstructions'),
      width: double.infinity,
      padding: EdgeInsets.all(tv ? 0 : 18),
      decoration: tv
          ? null
          : BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: colors.outlineVariant.withValues(alpha: .5),
              ),
            ),
      child: model.status == 'streaming' && !tv
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n(context).awaitingFrame),
                const SizedBox(height: 8),
                Text(
                  l10n(context).reconnectHelp,
                  style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: i == steps.length - 1
                          ? 0
                          : tv
                          ? 16
                          : 12,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: tv ? 32 : 24,
                          child: Text(
                            '${i + 1}',
                            style: TextStyle(
                              color: colors.primary,
                              fontSize: tv ? 20 : 14,
                              height: 1.6,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            steps[i],
                            style: TextStyle(
                              fontSize: tv ? 20 : 14,
                              height: 1.6,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _errorCard(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(18),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.errorContainer,
      borderRadius: BorderRadius.circular(14),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          liveRegion: true,
          child: Text(
            localizedMessage(
              context,
              model.commandError ?? model.message,
            ).split('\n').first,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onErrorContainer,
              height: 1.5,
            ),
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!model.isTelevision) _start(context),
            if (model.supportsExecutablePath)
              TextButton(
                key: const Key('check'),
                onPressed: model.canStart
                    ? () => model.check(model.path)
                    : null,
                child: Text(l10n(context).check),
              ),
            TextButton(onPressed: onLogs, child: Text(l10n(context).viewLogs)),
          ],
        ),
      ],
    ),
  );

  Widget _footer(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const Key('homeFooter'),
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        SwitchListTile(
          key: const Key('receiveSwitch'),
          contentPadding: EdgeInsets.zero,
          title: Text(
            l10n(context).receive,
            style: const TextStyle(fontSize: 15),
          ),
          value: model.active,
          onChanged: transitioning ? null : (_) => onToggle(),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: Text(
            model.platform == 'ios'
                ? l10n(context).foregroundReceive
                : model.platform == 'android'
                ? l10n(context).backgroundReceive
                : l10n(context).deviceAudioHelp,
            style: TextStyle(
              fontSize: 12,
              height: 1.5,
              color: colors.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (model.isTelevision) return _television(context);
    final phone = model.isMobile;
    return Column(
      children: [
        if (phone)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              key: const Key('homeToolbar'),
              children: [
                const Expanded(
                  child: Text(
                    'Flutter AirPlay',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
                  ),
                ),
                IconButton(
                  key: const Key('openSettings'),
                  focusNode: model.canStart ? null : actionFocus,
                  tooltip: l10n(context).settings,
                  onPressed: () => onSettings(),
                  icon: const Icon(Icons.settings_outlined),
                ),
              ],
            ),
          ),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxHeight < 420;
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Padding(
                    padding: EdgeInsets.fromLTRB(
                      24,
                      compact
                          ? 20
                          : phone
                          ? 48
                          : 32,
                      24,
                      24,
                    ),
                    child: Center(
                      child: phone && constraints.maxWidth >= 600
                          ? Row(
                              children: [
                                Expanded(
                                  child: _identity(context, compact: true),
                                ),
                                const SizedBox(width: 24),
                                Expanded(child: _guidance(context)),
                              ],
                            )
                          : ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 392),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _identity(context, compact: compact),
                                  SizedBox(height: compact ? 20 : 28),
                                  _guidance(context),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 392),
              child: _footer(context),
            ),
          ),
        ),
      ],
    );
  }

  Widget _guidance(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      if (error)
        _errorCard(context)
      else if (model.status == 'stopped' && model.loaded)
        _start(context)
      else
        _instructions(context),
      if (model.notice != null && !error)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            localizedMessage(context, model.notice!),
            textAlign: TextAlign.center,
          ),
        ),
    ],
  );

  Widget _television(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.airplay_rounded,
                    size: 64,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 28),
                  Expanded(child: _identity(context)),
                ],
              ),
              const SizedBox(height: 28),
              Text(
                l10n(context).tvHeading,
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 20),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 760),
                child: error ? _errorCard(context) : _instructions(context),
              ),
              SizedBox(
                height: (constraints.maxHeight - 440).clamp(24, 160).toDouble(),
              ),
              Row(
                children: [
                  Expanded(
                    child: Wrap(
                      spacing: 16,
                      runSpacing: 12,
                      children: [
                        if (model.canStart) TvFocus(child: _start(context)),
                        TvFocus(
                          child: OutlinedButton.icon(
                            key: const Key('openSettings'),
                            focusNode: model.canStart ? null : actionFocus,
                            onPressed: () => onSettings(),
                            icon: const Icon(Icons.settings_outlined),
                            label: Text(l10n(context).settings),
                          ),
                        ),
                        TvFocus(
                          child: OutlinedButton.icon(
                            key: const Key('openLogs'),
                            onPressed: onLogs,
                            icon: const Icon(Icons.receipt_long_outlined),
                            label: Text(l10n(context).logsShort),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    l10n(context).drmNotice,
                    style: TextStyle(
                      fontSize: 14,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
