// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../tv_focus.dart';
import '../receiver_back.dart';

import 'settings_labels.dart';

class AudioOutputPage extends StatefulWidget {
  const AudioOutputPage({super.key, required this.model});
  final ReceiverModel model;
  @override
  State<AudioOutputPage> createState() => AudioOutputPageState();
}

class AudioOutputPageState extends State<AudioOutputPage> {
  Future<void> _select(String value) => widget.model.save(
    widget.model.name,
    widget.model.path,
    audioOutput: value,
  );

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
            appBar: AppBar(title: Text(l10n(context).audioOutput)),
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
                            groupValue: model.audioOutput,
                            onChanged: (value) {
                              if (value != null && model.editable) {
                                _select(value);
                              }
                            },
                            child: Column(
                              children: [
                                for (final value in const [
                                  'auto',
                                  'aaudio',
                                  'audiotrack',
                                ])
                                  model.isTelevision
                                      ? TvFocus(
                                          child: ListTile(
                                            key: Key('audioOutput$value'),
                                            autofocus:
                                                value == model.audioOutput,
                                            enabled: model.editable,
                                            title: Text(
                                              audioOutputLabel(context, value),
                                            ),
                                            subtitle: value == 'auto'
                                                ? Text(
                                                    l10n(context)
                                                        .audioOutputAutoHelp,
                                                  )
                                                : null,
                                            trailing: Icon(
                                              value == model.audioOutput
                                                  ? Icons.radio_button_checked
                                                  : Icons
                                                        .radio_button_unchecked,
                                            ),
                                            selected:
                                                value == model.audioOutput,
                                            onTap: model.editable
                                                ? () => _select(value)
                                                : null,
                                          ),
                                        )
                                      : RadioListTile<String>(
                                          key: Key('audioOutput$value'),
                                          contentPadding: EdgeInsets.zero,
                                          controlAffinity:
                                              ListTileControlAffinity.trailing,
                                          value: value,
                                          enabled: model.editable,
                                          title: Text(
                                            audioOutputLabel(context, value),
                                          ),
                                          subtitle: value == 'auto'
                                              ? Text(
                                                  l10n(context)
                                                      .audioOutputAutoHelp,
                                                )
                                              : null,
                                        ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 16),
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
