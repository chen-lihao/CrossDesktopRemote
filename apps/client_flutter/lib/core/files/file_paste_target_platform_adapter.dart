import 'dart:collection';
import 'dart:io';

import 'package:flutter/services.dart';

class FilePasteTarget {
  const FilePasteTarget({
    required this.path,
    required this.displayName,
    required this.application,
    required this.directoryIdentity,
    required this.writable,
  });

  factory FilePasteTarget.fromMap(Object? value) {
    if (value is! Map) {
      throw const FormatException('目标目录响应无效');
    }
    final path = value['path'];
    final displayName = value['displayName'];
    final application = value['application'];
    final directoryIdentity = value['directoryIdentity'];
    final writable = value['writable'];
    if (path is! String ||
        path.isEmpty ||
        displayName is! String ||
        application is! String ||
        directoryIdentity is! String ||
        directoryIdentity.isEmpty ||
        writable is! bool) {
      throw const FormatException('目标目录字段无效');
    }
    return FilePasteTarget(
      path: path,
      displayName: displayName,
      application: application,
      directoryIdentity: directoryIdentity,
      writable: writable,
    );
  }

  final String path;
  final String displayName;
  final String application;
  final String directoryIdentity;
  final bool writable;
}

abstract interface class FilePasteTargetPlatformAdapter {
  bool get supported;
  Stream<String> get pasteIntents;

  /// Captures the active Finder/Explorer folder at the instant Paste is
  /// requested. The returned path is local to the destination endpoint.
  Future<FilePasteTarget> captureActiveTarget();
  Future<bool> validateTarget(FilePasteTarget target);

  /// Registers one session as owning a remote file offer. Native paste
  /// interception remains enabled until every owner releases its offer.
  Future<void> setRemoteOfferAvailable({
    required String ownerId,
    required bool available,
  });
}

class MethodChannelFilePasteTargetPlatformAdapter
    implements FilePasteTargetPlatformAdapter {
  MethodChannelFilePasteTargetPlatformAdapter({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'com.crossdesktopremote.cross_desktop_remote/file_paste_target',
          );

  final MethodChannel _channel;
  static const EventChannel _eventChannel = EventChannel(
    'com.crossdesktopremote.cross_desktop_remote/file_paste_intents',
  );
  final LinkedHashSet<String> _offerOwners = LinkedHashSet<String>();
  late final Stream<String> _pasteIntents = _eventChannel
      .receiveBroadcastStream()
      .map((_) => _offerOwners.isEmpty ? null : _offerOwners.last)
      .where((ownerId) => ownerId != null)
      .cast<String>()
      .asBroadcastStream();

  @override
  bool get supported => Platform.isMacOS || Platform.isWindows;

  @override
  Stream<String> get pasteIntents => _pasteIntents;

  @override
  Future<FilePasteTarget> captureActiveTarget() async {
    return FilePasteTarget.fromMap(
      await _channel.invokeMethod<Object?>('captureActiveTarget'),
    );
  }

  @override
  Future<bool> validateTarget(FilePasteTarget target) async {
    return await _channel.invokeMethod<bool>('validateTarget', {
          'path': target.path,
          'directoryIdentity': target.directoryIdentity,
        }) ??
        false;
  }

  @override
  Future<void> setRemoteOfferAvailable({
    required String ownerId,
    required bool available,
  }) async {
    if (ownerId.isEmpty) {
      throw ArgumentError.value(ownerId, 'ownerId', 'must not be empty');
    }
    final wasEnabled = _offerOwners.isNotEmpty;
    if (available) {
      _offerOwners
        ..remove(ownerId)
        ..add(ownerId);
    } else {
      _offerOwners.remove(ownerId);
    }
    final shouldEnable = _offerOwners.isNotEmpty;
    if (wasEnabled == shouldEnable) return;
    try {
      await _channel.invokeMethod<void>('setRemoteOfferAvailable', {
        'available': shouldEnable,
      });
    } catch (_) {
      if (available) {
        _offerOwners.remove(ownerId);
      } else {
        _offerOwners.add(ownerId);
      }
      rethrow;
    }
  }
}

class UnsupportedFilePasteTargetPlatformAdapter
    implements FilePasteTargetPlatformAdapter {
  const UnsupportedFilePasteTargetPlatformAdapter();

  @override
  bool get supported => false;

  @override
  Stream<String> get pasteIntents => const Stream.empty();

  @override
  Future<FilePasteTarget> captureActiveTarget() {
    throw UnsupportedError('当前平台不支持活动目录粘贴');
  }

  @override
  Future<bool> validateTarget(FilePasteTarget target) async => false;

  @override
  Future<void> setRemoteOfferAvailable({
    required String ownerId,
    required bool available,
  }) async {}
}

FilePasteTargetPlatformAdapter createFilePasteTargetPlatformAdapter() {
  if (Platform.isMacOS || Platform.isWindows) {
    return _sharedDesktopFilePasteTargetAdapter ??=
        MethodChannelFilePasteTargetPlatformAdapter();
  }
  return const UnsupportedFilePasteTargetPlatformAdapter();
}

FilePasteTargetPlatformAdapter? _sharedDesktopFilePasteTargetAdapter;
