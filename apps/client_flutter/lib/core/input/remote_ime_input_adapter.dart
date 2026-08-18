import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum RemoteImeInputEventType { composition, commit, key, diagnostic }

@immutable
class RemoteImeInputEvent {
  const RemoteImeInputEvent({
    required this.clientId,
    required this.type,
    this.text = '',
    this.key = '',
    this.compositionLength = 0,
    this.diagnosticName = '',
    this.markedLength = 0,
    this.containsCjk = false,
  });

  final String clientId;
  final RemoteImeInputEventType type;
  final String text;
  final String key;
  final int compositionLength;
  final String diagnosticName;
  final int markedLength;
  final bool containsCjk;

  static RemoteImeInputEvent? tryParse(Object? value) {
    if (value is! Map<Object?, Object?>) return null;
    final clientId = value['clientId'];
    final type = value['type'];
    if (clientId is! String || type is! String) return null;
    final parsedType = switch (type) {
      'composition' => RemoteImeInputEventType.composition,
      'commit' => RemoteImeInputEventType.commit,
      'key' => RemoteImeInputEventType.key,
      'diagnostic' => RemoteImeInputEventType.diagnostic,
      _ => null,
    };
    if (parsedType == null) return null;
    return RemoteImeInputEvent(
      clientId: clientId,
      type: parsedType,
      text: value['text'] is String ? value['text']! as String : '',
      key: value['key'] is String ? value['key']! as String : '',
      compositionLength: (value['compositionLength'] as num?)?.toInt() ?? 0,
      diagnosticName: value['name'] is String ? value['name']! as String : '',
      markedLength: (value['markedLength'] as num?)?.toInt() ?? 0,
      containsCjk: value['containsCjk'] == true,
    );
  }
}

abstract interface class RemoteImeInputAdapter {
  Stream<RemoteImeInputEvent> get events;

  Future<bool> show({
    required String clientId,
    bool immediatePinyinCommit = true,
  });

  Future<void> hide({required String clientId});

  Future<void> reset({required String clientId});
}

class MethodChannelRemoteImeInputAdapter implements RemoteImeInputAdapter {
  static const _methodChannel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/remote_ime',
  );
  static const _eventChannel = EventChannel(
    'com.crossdesktopremote.cross_desktop_remote/remote_ime_events',
  );

  static final Stream<RemoteImeInputEvent> _events = _eventChannel
      .receiveBroadcastStream()
      .map(RemoteImeInputEvent.tryParse)
      .where((event) => event != null)
      .cast<RemoteImeInputEvent>();

  @override
  Stream<RemoteImeInputEvent> get events => _events;

  @override
  Future<bool> show({
    required String clientId,
    bool immediatePinyinCommit = true,
  }) async {
    final shown = await _methodChannel.invokeMethod<bool>('show', {
      'clientId': clientId,
      'immediatePinyinCommit': immediatePinyinCommit,
    });
    return shown == true;
  }

  @override
  Future<void> hide({required String clientId}) =>
      _methodChannel.invokeMethod<void>('hide', {'clientId': clientId});

  @override
  Future<void> reset({required String clientId}) =>
      _methodChannel.invokeMethod<void>('reset', {'clientId': clientId});
}
