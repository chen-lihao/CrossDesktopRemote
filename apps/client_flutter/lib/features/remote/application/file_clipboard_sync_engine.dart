import 'dart:async';
import 'dart:math';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/core/files/file_paste_target_platform_adapter.dart';

const int fileClipboardWireVersion = 1;
final RegExp _transferIdPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

class FileClipboardOfferIdentity {
  const FileClipboardOfferIdentity({
    required this.sessionId,
    required this.offerId,
    required this.generation,
    required this.revision,
  });

  final String sessionId;
  final String offerId;
  final int generation;
  final int revision;
}

class FilePasteTransactionIdentity {
  const FilePasteTransactionIdentity({
    required this.sessionId,
    required this.offerId,
    required this.generation,
    required this.pasteIntentId,
  });

  factory FilePasteTransactionIdentity.fromMessage(
    Map<String, dynamic> message,
  ) {
    final sessionId = message['sessionId'];
    final offerId = message['offerId'];
    final generation = message['generation'];
    final pasteIntentId = message['pasteIntentId'];
    if (sessionId is! String ||
        !_validOpaqueId(sessionId) ||
        offerId is! String ||
        !_validOpaqueId(offerId) ||
        generation is! num ||
        generation <= 0 ||
        generation != generation.toInt() ||
        pasteIntentId is! String ||
        !_validOpaqueId(pasteIntentId)) {
      throw const FormatException('文件粘贴事务身份无效');
    }
    return FilePasteTransactionIdentity(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation.toInt(),
      pasteIntentId: pasteIntentId,
    );
  }

  final String sessionId;
  final String offerId;
  final int generation;
  final String pasteIntentId;

  Map<String, dynamic> toMessageFields() => {
    'sessionId': sessionId,
    'offerId': offerId,
    'generation': generation,
    'pasteIntentId': pasteIntentId,
  };

  @override
  bool operator ==(Object other) =>
      other is FilePasteTransactionIdentity &&
      other.sessionId == sessionId &&
      other.offerId == offerId &&
      other.generation == generation &&
      other.pasteIntentId == pasteIntentId;

  @override
  int get hashCode =>
      Object.hash(sessionId, offerId, generation, pasteIntentId);
}

Map<String, dynamic> filePasteCommittedMessage({
  required FilePasteTransactionIdentity transaction,
  required String destinationLeaseId,
  required String transferId,
}) => {
  'type': 'file-paste-committed',
  'version': fileClipboardWireVersion,
  ...transaction.toMessageFields(),
  'destinationLeaseId': destinationLeaseId,
  'transferId': transferId,
};

Map<String, dynamic> filePastePrepareMessage({
  required FilePasteTransactionIdentity transaction,
  required int revision,
}) => {
  'type': 'file-paste-prepare',
  'version': fileClipboardWireVersion,
  ...transaction.toMessageFields(),
  'revision': revision,
};

Map<String, dynamic> filePasteReadyMessage({
  required FilePasteTransactionIdentity transaction,
  required String destinationLeaseId,
}) => {
  'type': 'file-paste-ready',
  'version': fileClipboardWireVersion,
  ...transaction.toMessageFields(),
  'destinationLeaseId': destinationLeaseId,
};

Map<String, dynamic> filePasteRejectedMessage({
  required FilePasteTransactionIdentity transaction,
  required String reason,
}) => {
  'type': 'file-paste-rejected',
  'version': fileClipboardWireVersion,
  ...transaction.toMessageFields(),
  'reason': reason,
};

Map<String, dynamic> filePasteCancelMessage({
  required FilePasteTransactionIdentity transaction,
  required String destinationLeaseId,
}) => {
  'type': 'file-paste-cancel',
  'version': fileClipboardWireVersion,
  ...transaction.toMessageFields(),
  'destinationLeaseId': destinationLeaseId,
};

Map<String, dynamic> remoteFileOfferMessage({
  required String sessionId,
  required String offerId,
  required int generation,
  required int revision,
  required List<String> names,
}) => {
  'type': 'file-offer',
  'version': fileClipboardWireVersion,
  'sessionId': sessionId,
  'offerId': offerId,
  'generation': generation,
  'revision': revision,
  'names': names.take(64).toList(growable: false),
  'itemCount': names.length,
};

Map<String, dynamic> remoteFileOfferRevokeMessage({
  required String sessionId,
  required String offerId,
  required int generation,
}) => {
  'type': 'file-offer-revoke',
  'version': fileClipboardWireVersion,
  'sessionId': sessionId,
  'offerId': offerId,
  'generation': generation,
};

Map<String, dynamic> remoteFilePasteRequestMessage({
  required FilePasteTransactionIdentity transaction,
  required String destinationLeaseId,
}) => {
  'type': 'file-paste-request',
  'version': fileClipboardWireVersion,
  ...transaction.toMessageFields(),
  'destinationLeaseId': destinationLeaseId,
};

typedef FileClipboardPublisher = Future<String> Function(
  List<String> paths,
  String destinationLeaseId,
);
typedef FileClipboardCanceller = Future<void> Function(String transferId);
typedef RemotePasteTransferBinding = ({
  String transferId,
  String destinationLeaseId,
  FilePasteTransactionIdentity transaction,
});

/// Application-layer owner for the file copy/paste transaction state.
///
/// [RemoteSessionController] transports messages and exposes UI state, while
/// this coordinator owns every identity-bearing lifecycle object. Keeping the
/// offer, paste intent, destination lease and commit gate together prevents a
/// text clipboard or input lifecycle from partially resetting a file paste.
class FileCopyPasteCoordinator {
  FileCopyPasteCoordinator({
    required FileClipboardPublisher publisher,
    required FileClipboardCanceller canceller,
  }) : offers = FileClipboardOfferBroker(
         publisher: publisher,
         canceller: canceller,
       );

  final FileClipboardOfferBroker offers;
  final FilePasteIntentGate intents = FilePasteIntentGate();
  final FilePasteDestinationLeaseRegistry destinations =
      FilePasteDestinationLeaseRegistry();
  final FilePasteCommitGate commits = FilePasteCommitGate();
  final Map<String, RemotePasteTransferBinding> remoteTransfersByIntent = {};
  final Set<String> trackedRemotePasteIntents = {};

  String localSessionId = createFilePasteOpaqueId();
  String? remoteSessionId;
  RemoteFileClipboardOffer? remoteOffer;
  FileClipboardOfferIdentity? announcedLocalOffer;

  void beginSession({String? sessionId}) {
    if (sessionId != null && !_validOpaqueId(sessionId)) {
      throw ArgumentError.value(sessionId, 'sessionId', '会话标识无效');
    }
    localSessionId = sessionId ?? createFilePasteOpaqueId();
    remoteSessionId = null;
    remoteOffer = null;
    announcedLocalOffer = null;
    intents.reset();
    destinations.clear();
    commits.reset();
    remoteTransfersByIntent.clear();
    trackedRemotePasteIntents.clear();
  }

  void resetSession() {
    remoteSessionId = null;
    remoteOffer = null;
    announcedLocalOffer = null;
    intents.reset();
    destinations.clear();
    commits.reset();
    remoteTransfersByIntent.clear();
    trackedRemotePasteIntents.clear();
  }
}

/// Owns one immutable file clipboard offer at a time.
///
/// Copying files only arms an offer. No hashing or network transfer begins
/// until [materialize] is called by an explicit remote paste action. A new
/// clipboard revision revokes the previous unstarted offer. A PasteIntent that
/// already owns a destination lease remains independent and is not cancelled
/// by later clipboard changes.
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
  final Map<String, _FileClipboardOffer> _inFlight = {};
  final Random _random = Random.secure();
  int _nextEpoch = 0;

  int? get currentRevision {
    _expireIfNeeded();
    return _current?.revision;
  }

  int? get currentGeneration {
    _expireIfNeeded();
    return _current?.epoch;
  }

  String? get currentTransferId {
    _expireIfNeeded();
    return _current?.transferId;
  }

  String? get currentOfferId {
    _expireIfNeeded();
    return _current?.id;
  }

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
      id: _newOpaqueId(_random),
      epoch: ++_nextEpoch,
      revision: snapshot.revision,
      paths: List<String>.unmodifiable(snapshot.filePaths),
      expiresAt: DateTime.now().add(offerLifetime),
    );
    _current = offer;
  }

  Future<String?> materialize(
    ClipboardSnapshot snapshot, {
    required String destinationLeaseId,
  }) {
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
    final boundLeaseId = current.destinationLeaseId;
    if (boundLeaseId != null && boundLeaseId != destinationLeaseId) {
      return Future<String?>.value();
    }
    current.destinationLeaseId = destinationLeaseId;
    return current.result ??= _start(current, destinationLeaseId);
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
  }

  Future<void> invalidate() async {
    _nextEpoch += 1;
    _current = null;
  }

  Future<void> invalidateTransfer(String transferId) async {
    final generation = _inFlight.remove(transferId);
    if (generation == null) return;
    if (identical(_current, generation)) {
      _current = null;
      _nextEpoch += 1;
    }
    await _cancelWhenReady(generation);
  }

  void releaseTransfer(String transferId) {
    final generation = _inFlight.remove(transferId);
    if (generation == null) return;
    if (identical(_current, generation)) {
      _current = null;
      _nextEpoch += 1;
    }
  }

  Future<String?> _start(
    _FileClipboardOffer generation,
    String destinationLeaseId,
  ) async {
    try {
      final transferId = await publisher(generation.paths, destinationLeaseId);
      generation.transferId = transferId;
      _inFlight[transferId] = generation;
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

class FilePasteIntentTicket {
  const FilePasteIntentTicket({required this.transaction, required this.ready});

  final FilePasteTransactionIdentity transaction;
  final Future<String?> ready;
}

class RemoteFileClipboardOffer {
  const RemoteFileClipboardOffer({
    required this.sessionId,
    required this.id,
    required this.generation,
    required this.revision,
    required this.names,
    required this.itemCount,
  });

  factory RemoteFileClipboardOffer.fromMessage(Map<String, dynamic> message) {
    final id = message['offerId'];
    final sessionId = message['sessionId'];
    final generation = message['generation'];
    final revision = message['revision'];
    final itemCount = message['itemCount'];
    final rawNames = message['names'];
    if (sessionId is! String ||
        !_validOpaqueId(sessionId) ||
        id is! String ||
        !_validOpaqueId(id) ||
        generation is! num ||
        generation <= 0 ||
        generation != generation.toInt() ||
        revision is! num ||
        revision < 0 ||
        revision != revision.toInt() ||
        itemCount is! num ||
        itemCount <= 0 ||
        itemCount > 1000000 ||
        itemCount != itemCount.toInt() ||
        rawNames is! List ||
        rawNames.isEmpty ||
        rawNames.length > 64 ||
        rawNames.any(
          (name) => name is! String || name.isEmpty || name.length > 1024,
        )) {
      throw const FormatException('远端文件 Offer 无效');
    }
    return RemoteFileClipboardOffer(
      sessionId: sessionId,
      id: id,
      generation: generation.toInt(),
      revision: revision.toInt(),
      names: rawNames.whereType<String>().take(64).toList(growable: false),
      itemCount: itemCount.toInt(),
    );
  }

  final String sessionId;
  final String id;
  final int generation;
  final int revision;
  final List<String> names;
  final int itemCount;
}

/// Matches destination-ready replies to one user initiated Paste action.
/// Paths never cross the wire; only the opaque destination lease is returned.
class FilePasteIntentGate {
  FilePasteIntentGate({Random? random}) : _random = random ?? Random.secure();

  final Random _random;
  final Map<String, _PendingPasteIntent> _waiting = {};

  FilePasteIntentTicket begin({
    required String sessionId,
    required String offerId,
    required int generation,
  }) {
    if (!_validOpaqueId(sessionId) ||
        !_validOpaqueId(offerId) ||
        generation <= 0) {
      throw const FormatException('无法为无效 Offer 创建粘贴事务');
    }
    final transaction = FilePasteTransactionIdentity(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation,
      pasteIntentId: _newOpaqueId(_random),
    );
    final completer = Completer<String?>();
    _waiting[transaction.pasteIntentId] = _PendingPasteIntent(
      transaction: transaction,
      completer: completer,
    );
    return FilePasteIntentTicket(
      transaction: transaction,
      ready: completer.future,
    );
  }

  bool accept(Map<String, dynamic> message) {
    final type = message['type'];
    if (type != 'file-paste-ready' && type != 'file-paste-rejected') {
      return false;
    }
    late final FilePasteTransactionIdentity transaction;
    try {
      transaction = FilePasteTransactionIdentity.fromMessage(message);
    } on FormatException {
      return false;
    }
    final pending = _waiting.remove(transaction.pasteIntentId);
    if (pending == null || pending.completer.isCompleted) return true;
    if (pending.transaction != transaction) {
      pending.completer.complete(null);
      return false;
    }
    if (type == 'file-paste-ready') {
      final leaseId = message['destinationLeaseId'];
      pending.completer.complete(
        leaseId is String && _validOpaqueId(leaseId) ? leaseId : null,
      );
    } else {
      pending.completer.complete(null);
    }
    return true;
  }

  void cancel(String pasteIntentId) {
    final pending = _waiting.remove(pasteIntentId);
    if (pending != null && !pending.completer.isCompleted) {
      pending.completer.complete(null);
    }
  }

  void reset() {
    for (final pending in _waiting.values) {
      if (!pending.completer.isCompleted) pending.completer.complete(null);
    }
    _waiting.clear();
  }
}

class _PendingPasteIntent {
  const _PendingPasteIntent({
    required this.transaction,
    required this.completer,
  });

  final FilePasteTransactionIdentity transaction;
  final Completer<String?> completer;
}

class FilePasteDestinationLease {
  const FilePasteDestinationLease({
    required this.id,
    required this.transaction,
    required this.target,
    required this.expiresAt,
  });

  final String id;
  final FilePasteTransactionIdentity transaction;
  final FilePasteTarget target;
  final DateTime expiresAt;
}

/// Freezes an active Finder/Explorer folder for one paste transaction.
class FilePasteDestinationLeaseRegistry {
  FilePasteDestinationLeaseRegistry({
    Random? random,
    this.lifetime = const Duration(hours: 24),
  }) : _random = random ?? Random.secure();

  final Random _random;
  final Duration lifetime;
  final Map<String, FilePasteDestinationLease> _leases = {};
  final Map<String, FilePasteDestinationLease> _byPasteIntent = {};
  final Set<String> _consumedPasteIntents = {};

  int get count {
    _expire();
    return _leases.length;
  }

  FilePasteDestinationLease create({
    required FilePasteTransactionIdentity transaction,
    required FilePasteTarget target,
  }) {
    _expire();
    final pasteIntentId = transaction.pasteIntentId;
    if (_consumedPasteIntents.contains(pasteIntentId)) {
      throw StateError('粘贴事务已经消费');
    }
    final existing = _byPasteIntent[pasteIntentId];
    if (existing != null) {
      if (existing.transaction != transaction) {
        throw StateError('粘贴事务身份冲突');
      }
      return existing;
    }
    final lease = FilePasteDestinationLease(
      id: _newOpaqueId(_random),
      transaction: transaction,
      target: target,
      expiresAt: DateTime.now().add(lifetime),
    );
    _leases[lease.id] = lease;
    _byPasteIntent[pasteIntentId] = lease;
    return lease;
  }

  FilePasteDestinationLease? take(String leaseId) {
    _expire();
    final lease = _leases.remove(leaseId);
    if (lease == null) return null;
    _byPasteIntent.remove(lease.transaction.pasteIntentId);
    if (_consumedPasteIntents.length >= 1024) {
      _consumedPasteIntents.clear();
    }
    _consumedPasteIntents.add(lease.transaction.pasteIntentId);
    return lease;
  }

  bool revoke(String leaseId, {FilePasteTransactionIdentity? transaction}) {
    final lease = _leases[leaseId];
    if (lease == null ||
        (transaction != null && lease.transaction != transaction)) {
      return false;
    }
    _leases.remove(leaseId);
    _byPasteIntent.remove(lease.transaction.pasteIntentId);
    return true;
  }

  void clear() {
    _leases.clear();
    _byPasteIntent.clear();
    _consumedPasteIntents.clear();
  }

  void _expire() {
    final now = DateTime.now();
    final expired = _leases.values
        .where((lease) => !now.isBefore(lease.expiresAt))
        .toList(growable: false);
    for (final lease in expired) {
      _leases.remove(lease.id);
      _byPasteIntent.remove(lease.transaction.pasteIntentId);
    }
  }
}

String createFilePasteOpaqueId([Random? random]) {
  final generator = random ?? Random.secure();
  return List<int>.generate(
    16,
    (_) => generator.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}

String _newOpaqueId(Random random) => createFilePasteOpaqueId(random);

bool _validOpaqueId(String value) => RegExp(r'^[0-9a-f]{32}$').hasMatch(value);

class _FileClipboardOffer {
  _FileClipboardOffer({
    required this.id,
    required this.epoch,
    required this.revision,
    required this.paths,
    required this.expiresAt,
  });

  final String id;
  final int epoch;
  final int revision;
  final List<String> paths;
  final DateTime expiresAt;
  Future<String?>? result;
  String? transferId;
  String? destinationLeaseId;
}

/// Waits until the destination confirms that the explicit transfer has landed
/// in the folder captured for this exact PasteIntent.
class FilePasteCommitGate {
  final Map<String, _FilePasteCommitExpectation> _waiting = {};
  final Map<String, _FilePasteCommitIdentity> _committed = {};
  final Set<String> _failed = {};

  Future<bool> waitFor(
    String transferId, {
    required FilePasteTransactionIdentity transaction,
    required String destinationLeaseId,
    Duration timeout = const Duration(hours: 24),
  }) async {
    if (!_validTransferId(transferId) || !_validOpaqueId(destinationLeaseId)) {
      return false;
    }
    final identity = _FilePasteCommitIdentity(
      transaction: transaction,
      destinationLeaseId: destinationLeaseId,
    );
    final early = _committed.remove(transferId);
    if (early != null) return early == identity;
    if (_failed.remove(transferId)) return false;
    final expectation = _waiting.putIfAbsent(
      transferId,
      () => _FilePasteCommitExpectation(
        identity: identity,
        completer: Completer<bool>(),
      ),
    );
    if (expectation.identity != identity) return false;
    try {
      return await expectation.completer.future.timeout(
        timeout,
        onTimeout: () => false,
      );
    } finally {
      if (identical(_waiting[transferId], expectation)) {
        _waiting.remove(transferId);
      }
    }
  }

  bool accept(Map<String, dynamic> message) {
    if (message['type'] != 'file-paste-committed' ||
        message['version'] != fileClipboardWireVersion) {
      return false;
    }
    final transferId = message['transferId'];
    final destinationLeaseId = message['destinationLeaseId'];
    late final FilePasteTransactionIdentity transaction;
    try {
      transaction = FilePasteTransactionIdentity.fromMessage(message);
    } on FormatException {
      return false;
    }
    if (transferId is! String ||
        !_validTransferId(transferId) ||
        destinationLeaseId is! String ||
        !_validOpaqueId(destinationLeaseId)) {
      return false;
    }
    final identity = _FilePasteCommitIdentity(
      transaction: transaction,
      destinationLeaseId: destinationLeaseId,
    );
    final expectation = _waiting[transferId];
    if (expectation == null) {
      if (_committed.length >= 64) _committed.clear();
      _committed[transferId] = identity;
    } else if (!expectation.completer.isCompleted) {
      expectation.completer.complete(expectation.identity == identity);
    }
    return true;
  }

  void fail(String transferId) {
    final expectation = _waiting.remove(transferId);
    if (expectation != null && !expectation.completer.isCompleted) {
      expectation.completer.complete(false);
    } else {
      if (_failed.length >= 64) _failed.clear();
      _failed.add(transferId);
    }
  }

  void reset() {
    for (final expectation in _waiting.values) {
      if (!expectation.completer.isCompleted) {
        expectation.completer.complete(false);
      }
    }
    _waiting.clear();
    _committed.clear();
    _failed.clear();
  }

  static bool _validTransferId(String value) =>
      _transferIdPattern.hasMatch(value);
}

class _FilePasteCommitExpectation {
  const _FilePasteCommitExpectation({
    required this.identity,
    required this.completer,
  });

  final _FilePasteCommitIdentity identity;
  final Completer<bool> completer;
}

class _FilePasteCommitIdentity {
  const _FilePasteCommitIdentity({
    required this.transaction,
    required this.destinationLeaseId,
  });

  final FilePasteTransactionIdentity transaction;
  final String destinationLeaseId;

  @override
  bool operator ==(Object other) =>
      other is _FilePasteCommitIdentity &&
      other.transaction == transaction &&
      other.destinationLeaseId == destinationLeaseId;

  @override
  int get hashCode => Object.hash(transaction, destinationLeaseId);
}
