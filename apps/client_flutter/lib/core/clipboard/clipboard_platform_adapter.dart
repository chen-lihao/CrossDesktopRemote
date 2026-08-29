import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const int maxTextClipboardBytes = 256 * 1024;

class ClipboardSnapshot {
  const ClipboardSnapshot({
    required this.revision,
    required this.hasText,
    required this.tooLarge,
    required this.utf8Bytes,
    this.filePaths = const [],
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
      filePaths: (value['filePaths'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((path) => path.isNotEmpty)
          .toList(growable: false),
      text: value['text'] as String?,
    );
  }

  final int revision;
  final bool hasText;
  final bool tooLarge;
  final int utf8Bytes;
  final List<String> filePaths;
  final String? text;

  bool get hasFiles => filePaths.isNotEmpty;
}

abstract interface class ClipboardPlatformAdapter {
  bool get supported;
  bool get fileClipboardSupported;
  bool get automaticMonitoringSupported;
  Stream<ClipboardSnapshot> get changes;
  Future<ClipboardSnapshot> readSnapshot();
  Future<ClipboardSnapshot> writeText(String text);
  Future<ClipboardSnapshot> writeFiles(List<String> paths);
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
  bool get fileClipboardSupported => supported;

  @override
  bool get automaticMonitoringSupported => true;

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

  @override
  Future<ClipboardSnapshot> writeFiles(List<String> paths) async {
    if (paths.isEmpty) throw ArgumentError.value(paths, 'paths', '文件列表为空');
    return ClipboardSnapshot.fromMap(
      await _methodChannel.invokeMethod<Object?>('writeFiles', {
        'paths': paths,
      }),
    );
  }
}

typedef ClipboardTextReader = Future<String?> Function();
typedef ClipboardTextWriter = Future<void> Function(String text);

/// iOS/iPadOS must only inspect the pasteboard after an explicit user action.
/// This adapter intentionally exposes no background change stream.
class UserInitiatedClipboardPlatformAdapter
    implements ClipboardPlatformAdapter {
  UserInitiatedClipboardPlatformAdapter({
    ClipboardTextReader? readText,
    ClipboardTextWriter? writeText,
  }) : _readText = readText ?? _readSystemText,
       _writeText = writeText ?? _writeSystemText;

  final ClipboardTextReader _readText;
  final ClipboardTextWriter _writeText;
  int _revision = 0;

  @override
  bool get supported => true;

  @override
  bool get fileClipboardSupported => false;

  @override
  bool get automaticMonitoringSupported => false;

  @override
  Stream<ClipboardSnapshot> get changes => const Stream.empty();

  @override
  Future<ClipboardSnapshot> readSnapshot() async {
    final text = await _readText();
    return _snapshot(text);
  }

  @override
  Future<ClipboardSnapshot> writeText(String text) async {
    await _writeText(text);
    return _snapshot(text);
  }

  @override
  Future<ClipboardSnapshot> writeFiles(List<String> paths) {
    throw UnsupportedError('iPad 暂不支持系统文件剪贴板');
  }

  ClipboardSnapshot _snapshot(String? text) {
    final bytes = text == null ? 0 : utf8.encode(text).length;
    return ClipboardSnapshot(
      revision: ++_revision,
      hasText: text != null,
      tooLarge: bytes > maxTextClipboardBytes,
      utf8Bytes: bytes,
      text: bytes > maxTextClipboardBytes ? null : text,
    );
  }

  static Future<String?> _readSystemText() async =>
      (await Clipboard.getData('text/plain'))?.text;

  static Future<void> _writeSystemText(String text) =>
      Clipboard.setData(ClipboardData(text: text));
}

class UnsupportedClipboardPlatformAdapter implements ClipboardPlatformAdapter {
  const UnsupportedClipboardPlatformAdapter();

  @override
  bool get supported => false;

  @override
  bool get fileClipboardSupported => false;

  @override
  bool get automaticMonitoringSupported => false;

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

  @override
  Future<ClipboardSnapshot> writeFiles(List<String> paths) {
    throw UnsupportedError('File clipboard synchronization is unavailable');
  }
}

ClipboardPlatformAdapter createClipboardPlatformAdapter() {
  if (Platform.isMacOS || Platform.isWindows) {
    return MethodChannelClipboardPlatformAdapter();
  }
  if (Platform.isIOS) return UserInitiatedClipboardPlatformAdapter();
  return const UnsupportedClipboardPlatformAdapter();
}
