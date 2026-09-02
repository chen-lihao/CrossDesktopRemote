import 'dart:async';
import 'dart:convert';

import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_kernel.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:cross_desktop_remote/features/sessions/application/session_audit_repository.dart'
    as audit;
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.startedAt,
    required this.endedAt,
    required this.role,
    required this.deviceName,
    required this.displayName,
    required this.quality,
    required this.outcome,
    this.localDeviceId,
    this.localAddress,
    this.remoteAddress,
    this.signalingServer,
  });

  factory SessionRecord.fromJson(Map<String, dynamic> value) => SessionRecord(
    id: value['id'] as String? ?? '',
    startedAt: DateTime.parse(value['startedAt'] as String),
    endedAt: DateTime.parse(value['endedAt'] as String),
    role: value['role'] as String? ?? 'controller',
    deviceName: value['deviceName'] as String? ?? '未知设备',
    displayName: value['displayName'] as String? ?? '未知显示器',
    quality: value['quality'] as String? ?? '自动',
    outcome: value['outcome'] as String? ?? '已结束',
    localDeviceId: value['localDeviceId'] as String?,
    localAddress: value['localAddress'] as String?,
    remoteAddress: value['remoteAddress'] as String?,
    signalingServer: value['signalingServer'] as String?,
  );

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final String role;
  final String deviceName;
  final String displayName;
  final String quality;
  final String outcome;
  final String? localDeviceId;
  final String? localAddress;
  final String? remoteAddress;
  final String? signalingServer;

  Duration get duration => endedAt.difference(startedAt);

  Map<String, dynamic> toJson() => {
    'id': id,
    'startedAt': startedAt.toIso8601String(),
    'endedAt': endedAt.toIso8601String(),
    'role': role,
    'deviceName': deviceName,
    'displayName': displayName,
    'quality': quality,
    'outcome': outcome,
    'localDeviceId': localDeviceId,
    'localAddress': localAddress,
    'remoteAddress': remoteAddress,
    'signalingServer': signalingServer,
  };
}

class SessionHistoryController extends ChangeNotifier {
  SessionHistoryController({required this.settings, this.auditRepository}) {
    settings.addListener(_handleSettingsChanged);
  }

  static const _recordsKey = 'sessions.history.v1';

  final AppSettingsController settings;
  audit.SessionAuditRepository? auditRepository;
  SharedPreferencesAsync? _preferences;
  final List<SessionRecord> _records = [];
  final Map<RemoteSessionController, VoidCallback> _sessionListeners = {};
  final Map<
    RemoteSessionController,
    StreamSubscription<RemoteSessionDomainEvent>
  >
  _domainSubscriptions = {};
  final Map<RemoteSessionController, DateTime> _startedAt = {};
  String? _nextCursor;
  bool _loadingMore = false;
  final Map<String, List<audit.FileTransferAuditRecord>> _transfersBySession =
      {};

  SharedPreferencesAsync? get _store {
    if (_preferences != null) return _preferences;
    try {
      return _preferences = SharedPreferencesAsync();
    } on StateError {
      return null;
    }
  }

  List<SessionRecord> get records => List.unmodifiable(_records);
  bool get hasMore => _nextCursor != null;
  bool get loadingMore => _loadingMore;
  List<audit.FileTransferAuditRecord> transfersFor(String sessionId) =>
      List.unmodifiable(_transfersBySession[sessionId] ?? const []);
  DateTime? get currentStartedAt => _startedAt.values.firstOrNull;

  DateTime? currentStartedAtFor(RemoteSessionController session) =>
      _startedAt[session];

  Future<void> load() async {
    auditRepository ??= await audit.SessionAuditRepository.open();
    final values = await _store?.getStringList(_recordsKey) ?? const [];
    for (final value in values) {
      try {
        final legacy = SessionRecord.fromJson(
          jsonDecode(value) as Map<String, dynamic>,
        );
        await auditRepository!.upsertSession(_toAuditRecord(legacy));
      } catch (_) {
        // A malformed legacy row is ignored without affecting newer records.
      }
    }
    if (values.isNotEmpty) await _store?.remove(_recordsKey);
    final page = await auditRepository!.loadSessions();
    _records
      ..clear()
      ..addAll(page.records.map(_fromAuditRecord));
    _nextCursor = page.nextCursor;
    _trim();
    notifyListeners();
  }

  Future<void> loadNextPage() async {
    final cursor = _nextCursor;
    final repository = auditRepository;
    if (cursor == null || repository == null || _loadingMore) return;
    _loadingMore = true;
    notifyListeners();
    try {
      final page = await repository.loadSessions(cursor: cursor);
      _records.addAll(page.records.map(_fromAuditRecord));
      _nextCursor = page.nextCursor;
    } finally {
      _loadingMore = false;
      notifyListeners();
    }
  }

  Future<void> loadTransfers(String sessionId) async {
    final repository = auditRepository;
    if (repository == null) return;
    _transfersBySession[sessionId] = await repository.loadTransfers(sessionId);
    notifyListeners();
  }

  void attach(RemoteSessionController session) {
    attachAll([session]);
  }

  void attachAll(Iterable<RemoteSessionController> sessions) {
    for (final entry in _sessionListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    for (final subscription in _domainSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _sessionListeners.clear();
    _domainSubscriptions.clear();
    _startedAt.clear();
    for (final session in sessions) {
      void listener() => _handleSessionChanged(session);
      _sessionListeners[session] = listener;
      session.addListener(listener);
      _domainSubscriptions[session] = session.domainEvents.listen(
        (event) => _handleDomainEvent(session, event),
      );
      _handleSessionChanged(session);
    }
  }

  Future<void> clear() async {
    _records.clear();
    _nextCursor = null;
    _transfersBySession.clear();
    notifyListeners();
    await auditRepository?.clear();
    await _store?.remove(_recordsKey);
  }

  void _handleSessionChanged(RemoteSessionController session) {
    if (session.state == RemoteSessionState.streaming) {
      if (!_startedAt.containsKey(session)) {
        _startedAt[session] = DateTime.now();
        if (settings.sessionHistoryEnabled) {
          unawaited(
            auditRepository?.upsertSession(
              _toAuditRecord(
                _recordFor(
                  session,
                  startedAt: _startedAt[session]!,
                  endedAt: _startedAt[session]!,
                  outcome: '进行中',
                ),
              ),
            ),
          );
        }
        notifyListeners();
      }
      return;
    }
    if (!_startedAt.containsKey(session) ||
        !{
          RemoteSessionState.disconnected,
          RemoteSessionState.failed,
        }.contains(session.state)) {
      return;
    }
    final startedAt = _startedAt.remove(session)!;
    final endedAt = DateTime.now();
    if (settings.sessionHistoryEnabled) {
      final record = _recordFor(
        session,
        startedAt: startedAt,
        endedAt: endedAt,
        outcome: session.state == RemoteSessionState.failed
            ? session.error ?? '连接失败'
            : '正常断开',
      );
      _records.insert(0, record);
      _trim();
      unawaited(_persistRecord(record));
    }
    notifyListeners();
  }

  SessionRecord _recordFor(
    RemoteSessionController session, {
    required DateTime startedAt,
    required DateTime endedAt,
    required String outcome,
  }) => SessionRecord(
    id: session.sessionId ?? '${startedAt.microsecondsSinceEpoch}',
    startedAt: startedAt,
    endedAt: endedAt,
    role: session.role.name,
    deviceName: session.remoteDeviceId ?? '未知设备',
    displayName: session.selectedDisplay?.name ?? '未知显示器',
    quality: session.qualityStatusLabel,
    outcome: outcome,
    localDeviceId: session.localDeviceId,
    localAddress: session.localNetworkAddress,
    remoteAddress: session.remoteNetworkAddress,
    signalingServer: session.signalingServerUrl,
  );

  void _handleDomainEvent(
    RemoteSessionController session,
    RemoteSessionDomainEvent event,
  ) {
    if (event is! RemoteTransferChangedEvent ||
        !settings.sessionHistoryEnabled) {
      return;
    }
    final record = audit.FileTransferAuditRecord(
      id: event.transferId,
      sessionId: event.sessionId,
      updatedAt: event.occurredAt,
      direction: event.direction,
      state: event.state,
      transferredBytes: event.transferredBytes,
      totalBytes: event.totalBytes,
      relativePaths: event.items
          .map((item) => item.relativePath)
          .toList(growable: false),
      sourcePaths: event.items
          .map((item) => item.sourcePath)
          .whereType<String>()
          .toList(growable: false),
      destinationRoot: event.destinationRoot,
    );
    unawaited(auditRepository?.upsertTransfer(record));
    final loaded = _transfersBySession[event.sessionId];
    if (loaded != null) {
      loaded.removeWhere((item) => item.id == record.id);
      loaded.insert(0, record);
      notifyListeners();
    }
  }

  Future<void> _persistRecord(SessionRecord record) async {
    final repository = auditRepository;
    if (repository == null) return;
    await repository.upsertSession(_toAuditRecord(record));
    await repository.prune(settings.sessionHistoryLimit);
  }

  void _handleSettingsChanged() {
    final previousLength = _records.length;
    _trim();
    if (_records.length != previousLength) {
      notifyListeners();
      unawaited(auditRepository?.prune(settings.sessionHistoryLimit));
    }
  }

  void _trim() {
    if (_records.length > settings.sessionHistoryLimit) {
      _records.removeRange(settings.sessionHistoryLimit, _records.length);
    }
  }

  audit.SessionRecord _toAuditRecord(SessionRecord value) =>
      audit.SessionRecord.fromJson(value.toJson());

  SessionRecord _fromAuditRecord(audit.SessionRecord value) =>
      SessionRecord.fromJson(value.toJson());

  @override
  void dispose() {
    for (final entry in _sessionListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _sessionListeners.clear();
    for (final subscription in _domainSubscriptions.values) {
      unawaited(subscription.cancel());
    }
    _domainSubscriptions.clear();
    auditRepository?.close();
    settings.removeListener(_handleSettingsChanged);
    super.dispose();
  }
}
