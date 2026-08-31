import 'dart:async';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';

const int fileClipboardWireVersion = 1;
final RegExp _transferIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

Map<String, dynamic> fileClipboardAppliedMessage(String transferId) => {
  'type': 'file-applied',
  'version': fileClipboardWireVersion,
  'transferId': transferId,
};

typedef FileClipboardPublisher = Future<String> Function(List<String> paths);
typedef FileClipboardCanceller = Future<void> Function(String transferId);

/// Owns one immutable file clipboard offer at a time.
///
/// Copying files only arms an offer. No hashing or network transfer begins
/// until [materialize] is called by an explicit remote paste action. A new
/// clipboard revision revokes the previous offer and cancels a preparation
/// which has not yet been committed to the destination clipboard.
class FileClipboardOfferBroker {
  FileClipboardOfferBroker({
    required this.publisher,
    required this.canceller,
    this.offerLifetime = const Duration(minutes: 10),
  });

  final FileClipboardPublisher publisher;
  final FileClipboardCanceller canceller;
  final Duration offerLifetime;
  _FileClipboardOffer? _current;
  int _nextEpoch = 0;

  int? get currentRevision {
    _expireIfNeeded();
    return _current?.revision;
  }

  String? get currentTransferId => _current?.transferId;
  bool get hasOffer {
    _expireIfNeeded();
    return _current != null;
  }

  void arm(ClipboardSnapshot snapshot) {
    if (!snapshot.hasFiles) {
      unawaited(invalidate());
      return;
    }
    _expireIfNeeded();
    final current = _current;
    if (current != null &&
        current.revision == snapshot.revision &&
        _samePaths(current.paths, snapshot.filePaths)) {
      return;
    }
    final offer = _FileClipboardOffer(
      epoch: ++_nextEpoch,
      revision: snapshot.revision,
      paths: List<String>.unmodifiable(snapshot.filePaths),
      expiresAt: DateTime.now().add(offerLifetime),
    );
    _current = offer;
    if (current != null) unawaited(_cancelWhenReady(current));
  }

  Future<String?> materialize(ClipboardSnapshot snapshot) {
    if (!snapshot.hasFiles) {
      unawaited(invalidate());
      return Future<String?>.value();
    }
    _expireIfNeeded();
    final current = _current;
    if (current == null ||
        current.revision != snapshot.revision ||
        !_samePaths(current.paths, snapshot.filePaths)) {
      return Future<String?>.value();
    }
    return current.result ??= _start(current);
  }

  void _expireIfNeeded() {
    final current = _current;
    if (current == null ||
        current.result != null ||
        DateTime.now().isBefore(current.expiresAt)) {
      return;
    }
    _current = null;
    _nextEpoch += 1;
    unawaited(_cancelWhenReady(current));
  }

  Future<void> invalidate() async {
    _nextEpoch += 1;
    final current = _current;
    _current = null;
    if (current != null) await _cancelWhenReady(current);
  }

  Future<void> invalidateTransfer(String transferId) async {
    final current = _current;
    if (current == null || current.transferId != transferId) return;
    _current = null;
    _nextEpoch += 1;
    await _cancelWhenReady(current);
  }

  void releaseTransfer(String transferId) {
    final current = _current;
    if (current == null || current.transferId != transferId) return;
    _current = null;
    _nextEpoch += 1;
  }

  Future<String?> _start(_FileClipboardOffer generation) async {
    try {
      final transferId = await publisher(generation.paths);
      generation.transferId = transferId;
      if (!identical(_current, generation)) {
        await _safeCancel(transferId);
        return null;
      }
      return transferId;
    } catch (_) {
      if (identical(_current, generation)) _current = null;
      rethrow;
    }
  }

  Future<void> _cancelWhenReady(_FileClipboardOffer generation) async {
    final result = generation.result;
    if (result == null) return;
    try {
      final transferId = await result;
      if (transferId != null) await _safeCancel(transferId);
    } catch (_) {
      // A failed preparation has no live transfer to retire.
    }
  }

  Future<void> _safeCancel(String transferId) async {
    try {
      await canceller(transferId);
    } catch (_) {
      // The transfer may already be terminal or its channel may be closing.
    }
  }

  static bool _samePaths(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index += 1) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

class _FileClipboardOffer {
  _FileClipboardOffer({
    required this.epoch,
    required this.revision,
    required this.paths,
    required this.expiresAt,
  });

  final int epoch;
  final int revision;
  final List<String> paths;
  final DateTime expiresAt;
  Future<String?>? result;
  String? transferId;
}

enum ClipboardTempLeaseState { receiving, clipboardOwned, retired, cleaned }

typedef ClipboardTempDirectoryCleanup = Future<void> Function(String path);

/// Retains materialized files while the native clipboard still references
/// them, then deletes only retired CrossDesktopRemote-owned directories.
class ClipboardTempLeaseManager {
  ClipboardTempLeaseManager({
    required this.cleanup,
    this.retirementGrace = const Duration(minutes: 10),
  });

  final ClipboardTempDirectoryCleanup cleanup;
  final Duration retirementGrace;
  final Map<String, _ClipboardTempLease> _leases = {};
  final Map<String, Timer> _cleanupTimers = {};
  final Set<Future<void>> _pendingCleanups = {};
  bool _disposed = false;

  int get leaseCount => _leases.length;

  void registerReceiving(String transferId, String directory) {
    if (_disposed) return;
    final previous = _leases.remove(transferId);
    if (previous != null) _scheduleCleanup(previous, Duration.zero);
    _leases[transferId] = _ClipboardTempLease(
      transferId: transferId,
      directory: directory,
    );
  }

  void markClipboardOwned(
    String transferId, {
    required List<String> paths,
    required int revision,
  }) {
    if (_disposed) return;
    final lease = _leases[transferId];
    if (lease == null || lease.state != ClipboardTempLeaseState.receiving) {
      return;
    }
    for (final candidate in _leases.values.toList(growable: false)) {
      if (!identical(candidate, lease) &&
          candidate.state == ClipboardTempLeaseState.clipboardOwned) {
        _retire(candidate);
      }
    }
    lease
      ..paths = Set<String>.unmodifiable(paths)
      ..revision = revision
      ..state = ClipboardTempLeaseState.clipboardOwned;
  }

  void observeClipboard(ClipboardSnapshot snapshot) {
    if (_disposed) return;
    final currentPaths = snapshot.filePaths.toSet();
    for (final lease in _leases.values.toList(growable: false)) {
      if (lease.state != ClipboardTempLeaseState.clipboardOwned) continue;
      if (!_samePathSet(lease.paths, currentPaths)) _retire(lease);
    }
  }

  void retireTransfer(String transferId, {bool immediately = false}) {
    final lease = _leases[transferId];
    if (lease == null || lease.state == ClipboardTempLeaseState.cleaned) return;
    if (lease.state == ClipboardTempLeaseState.clipboardOwned && immediately) {
      return;
    }
    _retire(lease, immediately: immediately);
  }

  void retireSessionNonOwners() {
    for (final lease in _leases.values.toList(growable: false)) {
      if (lease.state != ClipboardTempLeaseState.clipboardOwned) {
        _retire(lease, immediately: true);
      }
    }
  }

  Future<void> drain() async {
    while (_pendingCleanups.isNotEmpty) {
      await Future.wait(_pendingCleanups.toList(growable: false));
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final timer in _cleanupTimers.values) {
      timer.cancel();
    }
    _cleanupTimers.clear();
    for (final lease in _leases.values.toList(growable: false)) {
      if (lease.state != ClipboardTempLeaseState.clipboardOwned) {
        _scheduleCleanup(lease, Duration.zero);
      }
    }
    await drain();
  }

  void _retire(_ClipboardTempLease lease, {bool immediately = false}) {
    if (lease.state == ClipboardTempLeaseState.cleaned ||
        lease.state == ClipboardTempLeaseState.retired) {
      return;
    }
    lease.state = ClipboardTempLeaseState.retired;
    _scheduleCleanup(lease, immediately ? Duration.zero : retirementGrace);
  }

  void _scheduleCleanup(_ClipboardTempLease lease, Duration delay) {
    _cleanupTimers.remove(lease.transferId)?.cancel();
    if (delay == Duration.zero) {
      _runCleanup(lease);
      return;
    }
    _cleanupTimers[lease.transferId] = Timer(delay, () {
      _cleanupTimers.remove(lease.transferId);
      _runCleanup(lease);
    });
  }

  void _runCleanup(_ClipboardTempLease lease) {
    if (lease.state == ClipboardTempLeaseState.clipboardOwned ||
        lease.state == ClipboardTempLeaseState.cleaned) {
      return;
    }
    late final Future<void> cleanupFuture;
    cleanupFuture = cleanup(lease.directory)
        .then((_) {
          lease.state = ClipboardTempLeaseState.cleaned;
          if (identical(_leases[lease.transferId], lease)) {
            _leases.remove(lease.transferId);
          }
        })
        .catchError((Object _) {
          // Startup scavenging retries directories left by a failed cleanup.
        })
        .whenComplete(() => _pendingCleanups.remove(cleanupFuture));
    _pendingCleanups.add(cleanupFuture);
  }

  static bool _samePathSet(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);
}

class _ClipboardTempLease {
  _ClipboardTempLease({required this.transferId, required this.directory});

  final String transferId;
  final String directory;
  ClipboardTempLeaseState state = ClipboardTempLeaseState.receiving;
  Set<String> paths = const {};
  int? revision;
}

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
