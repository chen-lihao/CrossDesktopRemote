import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

/// Stable identity and domain-event boundary for one remote-session attempt.
///
/// Media, input and file data remain in their existing native/WebRTC paths.
/// The kernel only owns identities and immutable lifecycle metadata so UI,
/// windows and audit storage do not have to infer transitions from widgets.
class RemoteSessionKernel {
  RemoteSessionKernel({required this.role});

  final String role;
  final StreamController<RemoteSessionDomainEvent> _events =
      StreamController<RemoteSessionDomainEvent>.broadcast(sync: true);

  String? _sessionId;
  String? _remoteDeviceId;
  DateTime? _openedAt;
  bool _closed = false;

  Stream<RemoteSessionDomainEvent> get events => _events.stream;
  String? get sessionId => _sessionId;
  String? get remoteDeviceId => _remoteDeviceId;
  DateTime? get openedAt => _openedAt;

  String begin({required String localDeviceId, DateTime? occurredAt}) {
    if (_sessionId != null && !_closed) {
      end(outcome: 'superseded', occurredAt: occurredAt);
    }
    final now = occurredAt ?? DateTime.now();
    _sessionId = _newOpaqueId();
    _remoteDeviceId = null;
    _openedAt = now;
    _closed = false;
    _emit(
      RemoteSessionOpenedEvent(
        sessionId: _sessionId!,
        occurredAt: now,
        role: role,
        localDeviceId: localDeviceId,
      ),
    );
    return _sessionId!;
  }

  void updatePeer(String? remoteDeviceId, {DateTime? occurredAt}) {
    final id = _sessionId;
    final normalized = remoteDeviceId?.trim();
    if (id == null || _closed || normalized == _remoteDeviceId) return;
    _remoteDeviceId = normalized?.isEmpty == true ? null : normalized;
    _emit(
      RemoteSessionPeerChangedEvent(
        sessionId: id,
        occurredAt: occurredAt ?? DateTime.now(),
        remoteDeviceId: _remoteDeviceId,
      ),
    );
  }

  void recordState({
    required String state,
    required String message,
    DateTime? occurredAt,
  }) {
    final id = _sessionId;
    if (id == null || _closed) return;
    _emit(
      RemoteSessionStateChangedEvent(
        sessionId: id,
        occurredAt: occurredAt ?? DateTime.now(),
        state: state,
        message: message,
      ),
    );
  }

  void recordTransfer({
    required String transferId,
    required String direction,
    required String state,
    required int transferredBytes,
    required int totalBytes,
    required List<RemoteTransferItemMetadata> items,
    String? destinationRoot,
    DateTime? occurredAt,
  }) {
    final id = _sessionId;
    if (id == null || _closed) return;
    _emit(
      RemoteTransferChangedEvent(
        sessionId: id,
        occurredAt: occurredAt ?? DateTime.now(),
        transferId: transferId,
        direction: direction,
        state: state,
        transferredBytes: transferredBytes,
        totalBytes: totalBytes,
        destinationRoot: destinationRoot,
        items: List.unmodifiable(items),
      ),
    );
  }

  void end({required String outcome, DateTime? occurredAt}) {
    final id = _sessionId;
    if (id == null || _closed) return;
    _closed = true;
    _emit(
      RemoteSessionClosedEvent(
        sessionId: id,
        occurredAt: occurredAt ?? DateTime.now(),
        outcome: outcome,
      ),
    );
  }

  void _emit(RemoteSessionDomainEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  Future<void> dispose() => _events.close();
}

@immutable
sealed class RemoteSessionDomainEvent {
  const RemoteSessionDomainEvent({
    required this.sessionId,
    required this.occurredAt,
  });

  final String sessionId;
  final DateTime occurredAt;
}

class RemoteSessionOpenedEvent extends RemoteSessionDomainEvent {
  const RemoteSessionOpenedEvent({
    required super.sessionId,
    required super.occurredAt,
    required this.role,
    required this.localDeviceId,
  });

  final String role;
  final String localDeviceId;
}

class RemoteSessionPeerChangedEvent extends RemoteSessionDomainEvent {
  const RemoteSessionPeerChangedEvent({
    required super.sessionId,
    required super.occurredAt,
    required this.remoteDeviceId,
  });

  final String? remoteDeviceId;
}

class RemoteSessionStateChangedEvent extends RemoteSessionDomainEvent {
  const RemoteSessionStateChangedEvent({
    required super.sessionId,
    required super.occurredAt,
    required this.state,
    required this.message,
  });

  final String state;
  final String message;
}

class RemoteSessionClosedEvent extends RemoteSessionDomainEvent {
  const RemoteSessionClosedEvent({
    required super.sessionId,
    required super.occurredAt,
    required this.outcome,
  });

  final String outcome;
}

class RemoteTransferChangedEvent extends RemoteSessionDomainEvent {
  const RemoteTransferChangedEvent({
    required super.sessionId,
    required super.occurredAt,
    required this.transferId,
    required this.direction,
    required this.state,
    required this.transferredBytes,
    required this.totalBytes,
    required this.items,
    this.destinationRoot,
  });

  final String transferId;
  final String direction;
  final String state;
  final int transferredBytes;
  final int totalBytes;
  final String? destinationRoot;
  final List<RemoteTransferItemMetadata> items;
}

@immutable
class RemoteTransferItemMetadata {
  const RemoteTransferItemMetadata({
    required this.relativePath,
    required this.sizeBytes,
    required this.kind,
    this.sourcePath,
  });

  final String relativePath;
  final int sizeBytes;
  final String kind;
  final String? sourcePath;
}

String _newOpaqueId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  return bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();
}
