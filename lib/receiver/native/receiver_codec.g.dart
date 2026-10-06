// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'receiver_codec.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

ReceiverReply _$ReceiverReplyFromJson(Map<String, dynamic> json) =>
    ReceiverReply(
      request: (json['request'] as num).toInt(),
      data: json['data'] as Map<String, dynamic>? ?? const {},
      error: json['error'] as String?,
    );
