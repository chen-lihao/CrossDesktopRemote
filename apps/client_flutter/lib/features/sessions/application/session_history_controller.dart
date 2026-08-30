import 'dart:async';
import 'dart:convert';

import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
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
  );

  final String id;
  final DateTime startedAt;
  final DateTime endedAt;
  final String role;
  final String deviceName;
  final String displayName;
  final String quality;
  final String outcome;

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
  };
}

class SessionHistoryController extends ChangeNotifier {
  SessionHistoryController({required this.settings}) {
    settings.addListener(_handleSettingsChanged);
  }

  static const _recordsKey = 'sessions.history.v1';

  final AppSettingsController settings;
  SharedPreferencesAsync? _preferences;
  final List<SessionRecord> _records = [];
  final Map<RemoteSessionController, VoidCallback> _sessionListeners = {};
  final Map<RemoteSessionController, DateTime> _startedAt = {};

  SharedPreferencesAsync? get _store {
    if (_preferences != null) return _preferences;
    try {
      return _preferences = SharedPreferencesAsync();
    } on StateError {
      return null;
    }
  }

  List<SessionRecord> get records => List.unmodifiable(_records);
  DateTime? get currentStartedAt => _startedAt.values.firstOrNull;

  DateTime? currentStartedAtFor(RemoteSessionController session) =>
      _startedAt[session];

  Future<void> load() async {
    final values = await _store?.getStringList(_recordsKey) ?? const [];
    _records
      ..clear()
      ..addAll(
        values.map((value) {
          try {
            return SessionRecord.fromJson(
              jsonDecode(value) as Map<String, dynamic>,
            );
          } catch (_) {
            return null;
          }
        }).whereType<SessionRecord>(),
      );
    _trim();
    notifyListeners();
  }

  void attach(RemoteSessionController session) {
    attachAll([session]);
  }

  void attachAll(Iterable<RemoteSessionController> sessions) {
    for (final entry in _sessionListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _sessionListeners.clear();
    _startedAt.clear();
    for (final session in sessions) {
      void listener() => _handleSessionChanged(session);
      _sessionListeners[session] = listener;
      session.addListener(listener);
      _handleSessionChanged(session);
    }
  }

  Future<void> clear() async {
    _records.clear();
    notifyListeners();
    await _store?.remove(_recordsKey);
  }

  void _handleSessionChanged(RemoteSessionController session) {
    if (session.state == RemoteSessionState.streaming) {
      if (!_startedAt.containsKey(session)) {
        _startedAt[session] = DateTime.now();
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
      _records.insert(
        0,
        SessionRecord(
          id: '${startedAt.microsecondsSinceEpoch}',
          startedAt: startedAt,
          endedAt: endedAt,
          role: session.role.name,
          deviceName: session.remoteDeviceId ?? '未知设备',
          displayName: session.selectedDisplay?.name ?? '未知显示器',
          quality: session.qualityStatusLabel,
          outcome: session.state == RemoteSessionState.failed
              ? session.error ?? '连接失败'
              : '正常断开',
        ),
      );
      _trim();
      unawaited(_save());
    }
    notifyListeners();
  }

  void _handleSettingsChanged() {
    final previousLength = _records.length;
    _trim();
    if (_records.length != previousLength) {
      notifyListeners();
      unawaited(_save());
    }
  }

  void _trim() {
    if (_records.length > settings.sessionHistoryLimit) {
      _records.removeRange(settings.sessionHistoryLimit, _records.length);
    }
  }

  Future<void> _save() async {
    await _store?.setStringList(
      _recordsKey,
      _records.map((record) => jsonEncode(record.toJson())).toList(),
    );
  }

  @override
  void dispose() {
    for (final entry in _sessionListeners.entries) {
      entry.key.removeListener(entry.value);
    }
    _sessionListeners.clear();
    settings.removeListener(_handleSettingsChanged);
    super.dispose();
  }
}
