import 'dart:async';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';

const int fileClipboardWireVersion = 1;
final RegExp _transferIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

Map<String, dynamic> fileClipboardAppliedMessage(String transferId) => {
  'type': 'file-applied',
  'version': fileClipboardWireVersion,
  'transferId': transferId,
};

/// Waits until the receiving OS owns a materialized file clipboard.
///
/// Transfer completion is deliberately insufficient: sending the remote paste
/// shortcut before CF_HDROP/NSPasteboard is committed produces an empty paste.
class FileClipboardApplyGate {
  final Map<String, Completer<bool>> _waiting = {};
  final Set<String> _applied = {};
  final Set<String> _failed = {};

  Future<bool> waitFor(
    String transferId, {
    Duration timeout = const Duration(minutes: 10),
  }) async {
    if (!_validTransferId(transferId)) return false;
    if (_applied.remove(transferId)) return true;
    if (_failed.remove(transferId)) return false;
    final completer = _waiting.putIfAbsent(transferId, Completer<bool>.new);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      if (identical(_waiting[transferId], completer)) {
        _waiting.remove(transferId);
      }
    }
  }

  bool accept(Map<String, dynamic> message) {
    if (message['type'] != 'file-applied' ||
        message['version'] != fileClipboardWireVersion) {
      return false;
    }
    final transferId = message['transferId'];
    if (transferId is! String || !_validTransferId(transferId)) return false;
    final completer = _waiting[transferId];
    if (completer == null) {
      if (_applied.length >= 64) _applied.clear();
      _applied.add(transferId);
    } else if (!completer.isCompleted) {
      completer.complete(true);
    }
    return true;
  }

  void fail(String transferId) {
    final completer = _waiting.remove(transferId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(false);
    } else {
      if (_failed.length >= 64) _failed.clear();
      _failed.add(transferId);
    }
  }

  void reset() {
    for (final completer in _waiting.values) {
      if (!completer.isCompleted) completer.complete(false);
    }
    _waiting.clear();
    _applied.clear();
    _failed.clear();
  }

  static bool _validTransferId(String value) =>
      _transferIdPattern.hasMatch(value);
}

/// Suppresses the native change notification caused by applying remote files.
class FileClipboardEchoGuard {
  Set<String>? _expectedPaths;
  DateTime? _expiresAt;

  void expect(Iterable<String> paths) {
    _expectedPaths = paths.toSet();
    _expiresAt = DateTime.now().add(const Duration(seconds: 5));
  }

  bool consumeIfExpected(ClipboardSnapshot snapshot) {
    final expected = _expectedPaths;
    final expiresAt = _expiresAt;
    _expectedPaths = null;
    _expiresAt = null;
    if (expected == null ||
        expiresAt == null ||
        DateTime.now().isAfter(expiresAt)) {
      return false;
    }
    return snapshot.filePaths.toSet().containsAll(expected) &&
        expected.containsAll(snapshot.filePaths);
  }

  void reset() {
    _expectedPaths = null;
    _expiresAt = null;
  }
}
