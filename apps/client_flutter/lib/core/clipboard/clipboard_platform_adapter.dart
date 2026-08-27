import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

const int maxTextClipboardBytes = 256 * 1024;

class ClipboardSnapshot {
  const ClipboardSnapshot({
    required this.revision,
    required this.hasText,
    required this.tooLarge,
    required this.utf8Bytes,
    this.text,
  });

  factory ClipboardSnapshot.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('Invalid native clipboard snapshot');
    }
    return ClipboardSnapshot(
      revision: (value['revision'] as num?)?.toInt() ?? 0,
      hasText: value['hasText'] == true,
      tooLarge: value['tooLarge'] == true,
      utf8Bytes: (value['utf8Bytes'] as num?)?.toInt() ?? 0,
      text: value['text'] as String?,
    );
  }

  final int revision;
  final bool hasText;
  final bool tooLarge;
  final int utf8Bytes;
  final String? text;
}

abstract interface class ClipboardPlatformAdapter {
  bool get supported;
  Stream<ClipboardSnapshot> get changes;
  Future<ClipboardSnapshot> readSnapshot();
  Future<ClipboardSnapshot> writeText(String text);
}

class MethodChannelClipboardPlatformAdapter
    implements ClipboardPlatformAdapter {
  MethodChannelClipboardPlatformAdapter({
    MethodChannel? methodChannel,
    EventChannel? eventChannel,
  }) : _methodChannel =
           methodChannel ??
           const MethodChannel(
             'com.crossdesktopremote.cross_desktop_remote/clipboard',
           ),
       _eventChannel =
           eventChannel ??
           const EventChannel(
             'com.crossdesktopremote.cross_desktop_remote/clipboard_events',
           );

  final MethodChannel _methodChannel;
  final EventChannel _eventChannel;

  @override
  bool get supported => Platform.isMacOS || Platform.isWindows;

  @override
  Stream<ClipboardSnapshot> get changes =>
      _eventChannel.receiveBroadcastStream().map(ClipboardSnapshot.fromMap);

  @override
  Future<ClipboardSnapshot> readSnapshot() async {
    return ClipboardSnapshot.fromMap(
      await _methodChannel.invokeMethod<Object?>('getSnapshot'),
    );
  }

  @override
  Future<ClipboardSnapshot> writeText(String text) async {
    return ClipboardSnapshot.fromMap(
      await _methodChannel.invokeMethod<Object?>('writeText', {'text': text}),
    );
  }
}

class UnsupportedClipboardPlatformAdapter implements ClipboardPlatformAdapter {
  const UnsupportedClipboardPlatformAdapter();

  @override
  bool get supported => false;

  @override
  Stream<ClipboardSnapshot> get changes => const Stream.empty();

  @override
  Future<ClipboardSnapshot> readSnapshot() {
    throw UnsupportedError('Clipboard synchronization is unavailable');
  }

  @override
  Future<ClipboardSnapshot> writeText(String text) {
    throw UnsupportedError('Clipboard synchronization is unavailable');
  }
}

ClipboardPlatformAdapter createClipboardPlatformAdapter() {
  if (Platform.isMacOS || Platform.isWindows) {
    return MethodChannelClipboardPlatformAdapter();
  }
  return const UnsupportedClipboardPlatformAdapter();
}
