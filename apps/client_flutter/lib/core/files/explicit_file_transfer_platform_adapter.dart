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
  Future<String> createClipboardReceiveDirectory(String transferId);
  Future<void> cleanupClipboardReceiveDirectory(String path);
  Future<void> cleanupOrphanedClipboardReceiveDirectories({
    Duration maxAge = const Duration(hours: 24),
  });
  Future<void> exportReceivedFiles(List<String> paths);
  Future<void> shareReceivedFiles(List<String> paths);
}

class DesktopExplicitFileTransferPlatformAdapter
    implements ExplicitFileTransferPlatformAdapter {
  DesktopExplicitFileTransferPlatformAdapter({Directory? systemTemp})
    : _systemTemp = systemTemp ?? Directory.systemTemp;

  static const String _managedDirectoryName = 'CrossDesktopRemote';
  static const String _clipboardDirectoryName = 'clipboard';
  static const String _legacyPrefix = 'crossdesktop-file-clipboard-';

  final Directory _systemTemp;

  Directory get _clipboardRoot => Directory(
    [
      _systemTemp.path,
      _managedDirectoryName,
      _clipboardDirectoryName,
    ].join(Platform.pathSeparator),
  );

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
  Future<String> createClipboardReceiveDirectory(String transferId) async {
    final safeId = transferId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final root = _clipboardRoot;
    await root.create(recursive: true);
    return (await root.createTemp('$safeId-')).path;
  }

  @override
  Future<void> cleanupClipboardReceiveDirectory(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) return;
    final root = _clipboardRoot;
    await root.create(recursive: true);
    final resolvedRoot = await root.resolveSymbolicLinks();
    final resolvedDirectory = await directory.resolveSymbolicLinks();
    if (!_isDirectOrNestedChild(resolvedRoot, resolvedDirectory)) {
      throw FileSystemException('拒绝清理非应用文件剪贴板目录', path);
    }
    await directory.delete(recursive: true);
  }

  @override
  Future<void> cleanupOrphanedClipboardReceiveDirectories({
    Duration maxAge = const Duration(hours: 24),
  }) async {
    final cutoff = DateTime.now().subtract(maxAge);
    final root = _clipboardRoot;
    if (await root.exists()) {
      await for (final entity in root.list(followLinks: false)) {
        await _cleanupExpiredDirectory(entity, cutoff, managed: true);
      }
    }
    if (await _systemTemp.exists()) {
      await for (final entity in _systemTemp.list(followLinks: false)) {
        final name = _basename(entity.path);
        if (name.startsWith(_legacyPrefix)) {
          await _cleanupExpiredDirectory(entity, cutoff, managed: false);
        }
      }
    }
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

  Future<void> _cleanupExpiredDirectory(
    FileSystemEntity entity,
    DateTime cutoff, {
    required bool managed,
  }) async {
    try {
      if (await FileSystemEntity.type(entity.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final stat = await entity.stat();
      if (!stat.modified.isBefore(cutoff)) return;
      if (managed) {
        await cleanupClipboardReceiveDirectory(entity.path);
      } else {
        final parent = Directory(entity.parent.path);
        final resolvedParent = await parent.resolveSymbolicLinks();
        final resolvedSystemTemp = await _systemTemp.resolveSymbolicLinks();
        if (_samePath(resolvedParent, resolvedSystemTemp)) {
          await entity.delete(recursive: true);
        }
      }
    } on FileSystemException {
      // Another controller or process may have already scavenged the entry.
    }
  }

  static bool _isDirectOrNestedChild(String root, String candidate) {
    final normalizedRoot = _normalizeCase(root);
    final normalizedCandidate = _normalizeCase(candidate);
    return normalizedCandidate.startsWith(
      '$normalizedRoot${Platform.pathSeparator}',
    );
  }

  static bool _samePath(String left, String right) =>
      _normalizeCase(left) == _normalizeCase(right);

  static String _normalizeCase(String value) =>
      Platform.isWindows ? value.toLowerCase() : value;

  static String _basename(String path) {
    final normalized = path.replaceAll('\\', '/');
    return normalized.substring(normalized.lastIndexOf('/') + 1);
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
  Future<String> createClipboardReceiveDirectory(String transferId) {
    throw UnsupportedError('iPad 暂不支持系统文件剪贴板');
  }

  @override
  Future<void> cleanupClipboardReceiveDirectory(String path) async {}

  @override
  Future<void> cleanupOrphanedClipboardReceiveDirectories({
    Duration maxAge = const Duration(hours: 24),
  }) async {}

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
  Future<String> createClipboardReceiveDirectory(String transferId) async =>
      _unsupported();

  @override
  Future<void> cleanupClipboardReceiveDirectory(String path) async {}

  @override
  Future<void> cleanupOrphanedClipboardReceiveDirectories({
    Duration maxAge = const Duration(hours: 24),
  }) async {}

  @override
  Future<void> exportReceivedFiles(List<String> paths) async => _unsupported();

  @override
  Future<void> shareReceivedFiles(List<String> paths) async => _unsupported();
}

ExplicitFileTransferPlatformAdapter
createExplicitFileTransferPlatformAdapter() {
  if (Platform.isIOS) return IosExplicitFileTransferPlatformAdapter();
  if (Platform.isMacOS || Platform.isWindows) {
    return DesktopExplicitFileTransferPlatformAdapter();
  }
  return const UnsupportedExplicitFileTransferPlatformAdapter();
}
