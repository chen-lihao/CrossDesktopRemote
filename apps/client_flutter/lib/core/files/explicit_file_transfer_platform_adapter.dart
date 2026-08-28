import 'dart:io';

import 'package:flutter/services.dart';

abstract interface class ExplicitFileTransferPlatformAdapter {
  bool get supported;
  bool get supportsDirectorySelection;
  bool get usesManagedReceiveStorage;
  bool get supportsReceivedExport;

  Future<List<String>> pickOutgoingFiles();
  Future<void> cleanupOutgoingFiles(List<String> paths);
  Future<String> createReceiveDirectory(String transferId);
  Future<void> exportReceivedFiles(List<String> paths);
  Future<void> shareReceivedFiles(List<String> paths);
}

class DesktopExplicitFileTransferPlatformAdapter
    implements ExplicitFileTransferPlatformAdapter {
  const DesktopExplicitFileTransferPlatformAdapter();

  @override
  bool get supported => Platform.isMacOS || Platform.isWindows;

  @override
  bool get supportsDirectorySelection => true;

  @override
  bool get usesManagedReceiveStorage => false;

  @override
  bool get supportsReceivedExport => false;

  @override
  Future<List<String>> pickOutgoingFiles() {
    throw UnsupportedError('Desktop file selection is provided by the UI');
  }

  @override
  Future<void> cleanupOutgoingFiles(List<String> paths) async {}

  @override
  Future<String> createReceiveDirectory(String transferId) {
    throw UnsupportedError('Desktop receive directory is selected by the user');
  }

  @override
  Future<void> exportReceivedFiles(List<String> paths) {
    throw UnsupportedError(
      'Desktop files are already stored at their destination',
    );
  }

  @override
  Future<void> shareReceivedFiles(List<String> paths) {
    throw UnsupportedError(
      'Desktop files are already stored at their destination',
    );
  }
}

class IosExplicitFileTransferPlatformAdapter
    implements ExplicitFileTransferPlatformAdapter {
  IosExplicitFileTransferPlatformAdapter({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'com.crossdesktopremote.cross_desktop_remote/ios_file_transfer',
          );

  final MethodChannel _channel;

  @override
  bool get supported => true;

  @override
  bool get supportsDirectorySelection => false;

  @override
  bool get usesManagedReceiveStorage => true;

  @override
  bool get supportsReceivedExport => true;

  @override
  Future<List<String>> pickOutgoingFiles() async {
    final result = await _channel.invokeListMethod<String>('pickOutgoingFiles');
    return result ?? const [];
  }

  @override
  Future<void> cleanupOutgoingFiles(List<String> paths) => _channel
      .invokeMethod('cleanupOutgoingFiles', <String, Object>{'paths': paths});

  @override
  Future<String> createReceiveDirectory(String transferId) async {
    final result = await _channel.invokeMethod<String>(
      'createReceiveDirectory',
      <String, Object>{'transferId': transferId},
    );
    if (result == null || result.isEmpty) {
      throw StateError('iPad 接收暂存目录创建失败');
    }
    return result;
  }

  @override
  Future<void> exportReceivedFiles(List<String> paths) => _channel.invokeMethod(
    'exportReceivedFiles',
    <String, Object>{'paths': paths},
  );

  @override
  Future<void> shareReceivedFiles(List<String> paths) => _channel.invokeMethod(
    'shareReceivedFiles',
    <String, Object>{'paths': paths},
  );
}

class UnsupportedExplicitFileTransferPlatformAdapter
    implements ExplicitFileTransferPlatformAdapter {
  const UnsupportedExplicitFileTransferPlatformAdapter();

  @override
  bool get supported => false;

  @override
  bool get supportsDirectorySelection => false;

  @override
  bool get usesManagedReceiveStorage => false;

  @override
  bool get supportsReceivedExport => false;

  Never _unsupported() =>
      throw UnsupportedError('Explicit file transfer is unavailable');

  @override
  Future<List<String>> pickOutgoingFiles() async => _unsupported();

  @override
  Future<void> cleanupOutgoingFiles(List<String> paths) async {}

  @override
  Future<String> createReceiveDirectory(String transferId) async =>
      _unsupported();

  @override
  Future<void> exportReceivedFiles(List<String> paths) async => _unsupported();

  @override
  Future<void> shareReceivedFiles(List<String> paths) async => _unsupported();
}

ExplicitFileTransferPlatformAdapter
createExplicitFileTransferPlatformAdapter() {
  if (Platform.isIOS) return IosExplicitFileTransferPlatformAdapter();
  if (Platform.isMacOS || Platform.isWindows) {
    return const DesktopExplicitFileTransferPlatformAdapter();
  }
  return const UnsupportedExplicitFileTransferPlatformAdapter();
}
