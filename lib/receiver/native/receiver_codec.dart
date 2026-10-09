// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:json_annotation/json_annotation.dart';

import '../receiver_state.dart';

part 'receiver_codec.g.dart';

@JsonSerializable(createToJson: false)
class ReceiverReply {
  const ReceiverReply({
    required this.request,
    this.data = const {},
    this.error,
  });
  factory ReceiverReply.fromJson(Map<String, dynamic> json) =>
      _$ReceiverReplyFromJson(json);
  final int request;
  final Map<String, dynamic> data;
  final String? error;
}

// The native snapshot keeps desired settings flat and uses an empty object
// when no session has active settings. Normalize only this envelope here.
Map<String, dynamic> _stateJson(Map<String, dynamic> data) => {
  ...data,
  'settings': data,
  'activeSettings': switch (data['activeSettings']) {
    Map(isEmpty: true) => null,
    final value => value,
  },
};
ReceiverState decodeReceiverState(Map<String, dynamic> data) =>
    ReceiverState.fromJson(_stateJson(data));

ReceiverEvent decodeReceiverEvent(Map<String, dynamic> data) =>
    ReceiverEvent.fromJson({
      ...data,
      if (data['type'] == 'snapshot')
        'data': _stateJson(Map<String, dynamic>.from(data['data'] as Map)),
    });

ReceiverSettings validatedReceiverSettings(Map<String, dynamic> values) {
  final name = (values['name'] as String).trim();
  final path = (values['path'] as String? ?? '').trim();
  if (name.isEmpty ||
      utf8.encode(name).length > 50 ||
      name.runes.any((value) => value < 32 || (value >= 127 && value <= 159))) {
    throw StateError('Invalid receiver name');
  }
  if (path.isNotEmpty) {
    throw StateError('Playback uses the built-in receiver core');
  }
  final buffer = values['playbackBufferMs'];
  if (buffer != null &&
      (buffer is! int ||
          !ReceiverSettings.playbackBufferOptions.contains(buffer))) {
    throw StateError('Invalid playback buffer');
  }
  try {
    return ReceiverSettings.fromJson({...values, 'name': name, 'path': path});
  } on ArgumentError {
    throw StateError('Invalid receiver settings');
  }
}
