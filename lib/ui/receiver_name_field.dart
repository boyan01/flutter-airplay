// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math';

import 'package:flutter/material.dart';

import 'receiver_strings.dart';
import 'tv_focus.dart';

class ReceiverNameField extends StatelessWidget {
  const ReceiverNameField({
    super.key,
    required this.controller,
    required this.enabled,
    required this.defaultName,
    required this.onGenerated,
    required this.onSubmitted,
    this.autofocus = false,
    this.television = false,
    this.error,
  });

  final TextEditingController controller;
  final String defaultName;
  final bool enabled, autofocus, television;
  final String? error;
  final VoidCallback onGenerated, onSubmitted;
  static final _random = Random();

  void _generate(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    final adjectives = chinese
        ? const ['快乐', '悠闲', '灵动', '闪亮', '轻快', '安静', '勇敢', '好奇']
        : const [
            'Happy',
            'Cozy',
            'Sunny',
            'Bright',
            'Swift',
            'Quiet',
            'Brave',
            'Curious',
          ];
    final animals = chinese
        ? const ['熊猫', '海豚', '狐狸', '企鹅', '松鼠', '水獭', '小鹿', '白鲸']
        : const [
            'Panda',
            'Dolphin',
            'Fox',
            'Penguin',
            'Squirrel',
            'Otter',
            'Deer',
            'Beluga',
          ];
    String name;
    do {
      final adjective = adjectives[_random.nextInt(adjectives.length)];
      final animal = animals[_random.nextInt(animals.length)];
      final number = 1000 + _random.nextInt(9000);
      name = chinese
          ? '$adjective$animal $number'
          : '$adjective $animal $number';
    } while (name == controller.text);
    controller.value = TextEditingValue(
      text: name,
      selection: TextSelection.collapsed(offset: name.length),
    );
    onGenerated();
  }

  void _reset() {
    controller.value = TextEditingValue(
      text: defaultName,
      selection: TextSelection.collapsed(offset: defaultName.length),
    );
    onGenerated();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        key: const Key('receiverName'),
        controller: controller,
        autofocus: autofocus,
        enabled: enabled,
        onSubmitted: (_) => onSubmitted(),
        decoration: InputDecoration(
          labelText: l10n(context).name,
          helperText: l10n(context).nameHelp,
          helperMaxLines: 2,
          errorText: error == null ? null : localizedMessage(context, error!),
        ),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          TvFocus(
            outline: television,
            child: TextButton.icon(
              key: const Key('randomReceiverName'),
              autofocus: television,
              onPressed: enabled ? () => _generate(context) : null,
              icon: const Icon(Icons.casino_outlined),
              label: Text(l10n(context).randomName),
            ),
          ),
          TvFocus(
            outline: television,
            child: TextButton.icon(
              key: const Key('resetReceiverName'),
              onPressed: enabled ? _reset : null,
              icon: const Icon(Icons.restart_alt),
              label: Text(l10n(context).reset),
            ),
          ),
        ],
      ),
    ],
  );
}
