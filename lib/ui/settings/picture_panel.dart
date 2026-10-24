// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../tv_focus.dart';
import 'settings_labels.dart';

// Common presets; Settings keeps the full playback buffer list.
const pictureLatencyOptions = [40, 0, 150];
const _qualityOrder = ['auto', '720', '1080', '1440', '2160'];

String latencyLabel(BuildContext context, ReceiverModel model) =>
    switch (model.playbackBufferMs) {
      40 => l10n(context).playbackBufferLowLatency,
      0 => l10n(context).latencyStandard,
      150 => l10n(context).playbackBufferSmooth,
      final value => l10n(context).playbackBufferValue(value),
    };

String _latencyDetail(BuildContext context, ReceiverModel model, int value) =>
    value == 0
    ? l10n(context).playbackBufferDefault(model.defaultPlaybackBufferMs)
    : l10n(context).playbackBufferValue(value);

/// A single picture setting, opened from its home row.
enum PictureSection { quality, latency }

/// Quality and latency for the next connection, beside the home page or video.
/// A [section] shows only that setting.
Future<void> showPicturePanel(
  BuildContext context,
  ReceiverModel model, {
  PictureSection? section,
}) => showGeneralDialog<void>(
  context: context,
  barrierDismissible: true,
  barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: Colors.black38,
  pageBuilder: (context, _, _) => PicturePanel(model: model, section: section),
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(.2, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOut)),
    child: FadeTransition(opacity: animation, child: child),
  ),
);

class PicturePanel extends StatefulWidget {
  const PicturePanel({super.key, required this.model, this.section});
  final ReceiverModel model;
  final PictureSection? section;

  @override
  State<PicturePanel> createState() => _PicturePanelState();
}

class _PicturePanelState extends State<PicturePanel> {
  final _reconnect = FocusNode(debugLabel: 'Picture reconnect');

  ReceiverModel get model => widget.model;

  @override
  void dispose() {
    _reconnect.dispose();
    super.dispose();
  }

  // Waiting receivers apply at once, so a choice closes the panel. While
  // streaming, the panel stays to offer the reconnect that applies it.
  Future<void> _choose(Future<void> Function()? save) async {
    await save?.call();
    if (!mounted || model.commandError != null) return;
    if (model.status != 'streaming') {
      Navigator.pop(context);
      return;
    }
    await WidgetsBinding.instance.endOfFrame;
    if (mounted && _reconnect.context != null) _reconnect.requestFocus();
  }

  Widget _heading(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Text(
      text,
      style: Theme.of(context).textTheme.titleSmall
          ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    ),
  );

  Widget _option(
    BuildContext context, {
    required String key,
    required String title,
    String? subtitle,
    required bool selected,
    required bool autofocus,
    required Future<void> Function() onSelected,
  }) => TvFocus(
    child: ListTile(
      key: Key(key),
      autofocus: autofocus,
      enabled: model.editable,
      selected: selected,
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      ),
      // Selecting the current choice confirms it without saving.
      onTap: () => _choose(selected ? null : onSelected),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: model,
    builder: (context, _) {
      final section = widget.section;
      final qualities =
          model.supportsVideoQuality && section != PictureSection.latency
          ? _qualityOrder.where(model.videoQualities.contains).toList()
          : const <String>[];
      final showLatency = section != PictureSection.quality;
      // Start on the current choice; a custom buffer starts on the first preset.
      final focusQuality = qualities.contains(model.videoQuality);
      final focusLatency =
          pictureLatencyOptions.contains(model.playbackBufferMs)
          ? model.playbackBufferMs
          : pictureLatencyOptions.first;
      final colors = Theme.of(context).colorScheme;
      final pending = model.settingsPending && model.status == 'streaming';
      final width = MediaQuery.sizeOf(context).width;
      return Align(
        alignment: Alignment.centerRight,
        child: SizedBox(
          key: const Key('picturePanel'),
          width: width < 520 ? width : 440,
          height: double.infinity,
          child: Material(
            color: colors.surfaceContainer,
            elevation: 8,
            child: SafeArea(
              left: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(switch (section) {
                        PictureSection.quality => l10n(context).videoQuality,
                        PictureSection.latency => l10n(context).latency,
                        null => l10n(context).picture,
                      }, style: Theme.of(context).textTheme.headlineSmall),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (qualities.isNotEmpty) ...[
                              if (section == null)
                                _heading(context, l10n(context).videoQuality),
                              for (final value in qualities)
                                _option(
                                  context,
                                  key: 'pictureQuality$value',
                                  title: qualityLabel(context, value),
                                  selected: value == model.videoQuality,
                                  autofocus:
                                      value == model.videoQuality ||
                                      (!focusQuality &&
                                          !showLatency &&
                                          value == qualities.first),
                                  onSelected: () => model.save(
                                    model.name,
                                    model.path,
                                    videoQuality: value,
                                  ),
                                ),
                            ],
                            if (showLatency && section == null)
                              _heading(context, l10n(context).latency),
                            if (showLatency)
                              for (final value in pictureLatencyOptions)
                                _option(
                                  context,
                                  key: 'pictureLatency$value',
                                  title: switch (value) {
                                    40 => l10n(
                                      context,
                                    ).playbackBufferLowLatency,
                                    150 => l10n(context).playbackBufferSmooth,
                                    _ => l10n(context).latencyStandard,
                                  },
                                  subtitle: _latencyDetail(
                                    context,
                                    model,
                                    value,
                                  ),
                                  selected: value == model.playbackBufferMs,
                                  autofocus:
                                      !focusQuality && value == focusLatency,
                                  onSelected: () => model.save(
                                    model.name,
                                    model.path,
                                    playbackBufferMs: value,
                                  ),
                                ),
                            if (model.commandError != null)
                              Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  localizedMessage(
                                    context,
                                    model.commandError!,
                                  ),
                                  style: TextStyle(color: colors.error),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (pending) ...[
                      const Divider(height: 24),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 20,
                              color: colors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                l10n(context).pictureApplyAfterReconnect,
                                key: const Key('pictureApplyHint'),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      TvFocus(
                        child: OutlinedButton.icon(
                          key: const Key('pictureReconnect'),
                          focusNode: _reconnect,
                          onPressed: model.canStop
                              ? () {
                                  // Close first: the player behind leaves the tree.
                                  Navigator.pop(context);
                                  model.disconnect();
                                }
                              : null,
                          icon: const Icon(Icons.eject_rounded),
                          label: Text(l10n(context).pictureReconnect),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}
