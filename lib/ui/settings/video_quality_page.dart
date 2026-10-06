// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../tv_focus.dart';
import '../receiver_back.dart';

import 'settings_labels.dart';

class VideoQualityPage extends StatefulWidget {
  const VideoQualityPage({super.key, required this.model});
  final ReceiverModel model;
  @override
  State<VideoQualityPage> createState() => VideoQualityPageState();
}

class VideoQualityPageState extends State<VideoQualityPage> {
  Future<void> _select(String value) => widget.model.save(
    widget.model.name,
    widget.model.path,
    videoQuality: value,
  );

  Widget _qualityOption(BuildContext context, String value) {
    final model = widget.model;
    final supported = model.videoQualities.contains(value);
    final enabled = model.editable && supported;
    final title = Text(qualityLabel(context, value));
    final subtitle = supported ? null : Text(l10n(context).qualityUnsupported);
    final autofocus = value == model.videoQuality;
    return model.isTelevision
        ? TvFocus(
            child: ListTile(
              key: Key('quality$value'),
              autofocus: autofocus,
              enabled: enabled,
              title: title,
              subtitle: subtitle,
              trailing: Icon(
                value == model.videoQuality
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              selected: value == model.videoQuality,
              onTap: enabled ? () => _select(value) : null,
            ),
          )
        : RadioListTile<String>(
            key: Key('quality$value'),
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            value: value,
            autofocus: autofocus,
            enabled: enabled,
            title: title,
            subtitle: subtitle,
          );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final model = widget.model;
      return PopScope(
        canPop: !model.busy,
        child: CallbackShortcuts(
          bindings: receiverBackShortcuts(model.platform, () {
            if (!model.busy) Navigator.pop(context);
          }),
          child: Scaffold(
            appBar: AppBar(title: Text(l10n(context).videoQuality)),
            body: SafeArea(
              child: Column(
                crossAxisAlignment: model.isTelevision
                    ? CrossAxisAlignment.center
                    : CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: EdgeInsets.all(model.isTelevision ? 48 : 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          RadioGroup<String>(
                            groupValue: model.videoQuality,
                            onChanged: (value) {
                              if (value != null && model.editable) {
                                _select(value);
                              }
                            },
                            child: Column(
                              children: [
                                for (final value in const [
                                  'auto',
                                  '720',
                                  '1080',
                                  '1440',
                                  '2160',
                                ])
                                  _qualityOption(context, value),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(l10n(context).qualityHelp),
                          const SizedBox(height: 8),
                          Text(l10n(context).settingsApplyHelp),
                          if (model.commandError != null)
                            Text(
                              localizedMessage(context, model.commandError!),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}
