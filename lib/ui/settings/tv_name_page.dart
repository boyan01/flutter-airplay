// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../../receiver/receiver_model.dart';
import '../widgets/receiver_strings.dart';
import '../widgets/receiver_name_field.dart';
import '../receiver_back.dart';

class TvNamePage extends StatefulWidget {
  const TvNamePage({super.key, required this.model});
  final ReceiverModel model;
  @override
  State<TvNamePage> createState() => TvNamePageState();
}

class TvNamePageState extends State<TvNamePage> {
  late final _name = TextEditingController(text: widget.model.name);
  String? _error;

  Future<void> _save() async {
    if (!mounted) return;
    setState(() => _error = widget.model.validateName(_name.text));
    if (_error != null || _name.text.trim() == widget.model.name) return;
    await widget.model.save(_name.text, widget.model.path);
    if (mounted) setState(() => _error = widget.model.commandError);
  }

  @override
  void dispose() {
    if (_name.text.trim() != widget.model.name &&
        widget.model.validateName(_name.text) == null) {
      unawaited(widget.model.save(_name.text, widget.model.path));
    }
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) => PopScope(
      canPop: !widget.model.busy,
      child: CallbackShortcuts(
        bindings: receiverBackShortcuts(widget.model.platform, () {
          if (!widget.model.busy) Navigator.pop(context);
        }),
        child: Scaffold(
          appBar: AppBar(title: Text(l10n(context).name)),
          body: SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(48),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ReceiverNameField(
                    controller: _name,
                    defaultName: widget.model.defaultName,
                    television: true,
                    enabled: widget.model.loaded,
                    error: _error,
                    onGenerated: _save,
                    onSubmitted: _save,
                  ),
                  const SizedBox(height: 24),
                  Text(l10n(context).settingsApplyHelp),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
