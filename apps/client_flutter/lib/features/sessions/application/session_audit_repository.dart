import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

const sessionAuditPageSize = 10;

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

@immutable
class FileTransferAuditRecord {
  const FileTransferAuditRecord({
    required this.id,
    required this.sessionId,
    required this.updatedAt,
    required this.direction,
    required this.state,
    required this.transferredBytes,
    required this.totalBytes,
    required this.relativePaths,
    required this.sourcePaths,
    this.destinationRoot,
  });

  factory FileTransferAuditRecord.fromJson(Map<String, dynamic> value) =>
      FileTransferAuditRecord(
        id: value['id'] as String,
        sessionId: value['sessionId'] as String,
        updatedAt: DateTime.parse(value['updatedAt'] as String),
        direction: value['direction'] as String? ?? 'unknown',
        state: value['state'] as String? ?? 'unknown',
        transferredBytes: (value['transferredBytes'] as num?)?.toInt() ?? 0,
        totalBytes: (value['totalBytes'] as num?)?.toInt() ?? 0,
        relativePaths: (value['relativePaths'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        sourcePaths: (value['sourcePaths'] as List<dynamic>? ?? const [])
            .whereType<String>()
            .toList(growable: false),
        destinationRoot: value['destinationRoot'] as String?,
      );

  final String id;
  final String sessionId;
  final DateTime updatedAt;
  final String direction;
  final String state;
  final int transferredBytes;
  final int totalBytes;
  final List<String> relativePaths;
  final List<String> sourcePaths;
  final String? destinationRoot;

  Map<String, dynamic> toJson() => {
    'id': id,
    'sessionId': sessionId,
    'updatedAt': updatedAt.toIso8601String(),
    'direction': direction,
    'state': state,
    'transferredBytes': transferredBytes,
    'totalBytes': totalBytes,
    'relativePaths': relativePaths,
    'sourcePaths': sourcePaths,
    'destinationRoot': destinationRoot,
  };
}

class SessionAuditPage {
  const SessionAuditPage({required this.records, this.nextCursor});

  final List<SessionRecord> records;
  final String? nextCursor;
}

class SessionAuditRepository {
  SessionAuditRepository._(this._database, this._cipher);

  static const _secureKeyName = 'crossdesktop.session-audit-key.v1';
  static const _databaseName = 'session-audit-v2.sqlite3';

  final Database _database;
  final _SessionAuditCipher _cipher;

  static Future<SessionAuditRepository> open({
    String? databasePath,
    List<int>? encryptionKey,
  }) async {
    final path = databasePath ?? await _defaultDatabasePath();
    final key = encryptionKey ?? await _loadOrCreateKey();
    final database = sqlite3.open(path);
    final repository = SessionAuditRepository._(
      database,
      _SessionAuditCipher(key),
    );
    repository._initialize();
    return repository;
  }

  static Future<String> _defaultDatabasePath() async {
    final directory = await getApplicationSupportDirectory();
    final auditDirectory = Directory(
      '${directory.path}${Platform.pathSeparator}audit',
    );
    if (!auditDirectory.existsSync()) {
      auditDirectory.createSync(recursive: true);
    }
    return '${auditDirectory.path}${Platform.pathSeparator}$_databaseName';
  }

  static Future<List<int>> _loadOrCreateKey() async {
    const storage = FlutterSecureStorage();
    final stored = await storage.read(key: _secureKeyName);
    if (stored != null) return base64Url.decode(stored);
    final random = Random.secure();
    final key = List<int>.generate(32, (_) => random.nextInt(256));
    await storage.write(key: _secureKeyName, value: base64UrlEncode(key));
    return key;
  }

  void _initialize() {
    _database.execute('PRAGMA foreign_keys = ON');
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS sessions (
        id TEXT PRIMARY KEY,
        started_at INTEGER NOT NULL,
        ended_at INTEGER NOT NULL,
        role TEXT NOT NULL,
        encrypted_payload TEXT NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS transfers (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        updated_at INTEGER NOT NULL,
        state TEXT NOT NULL,
        encrypted_payload TEXT NOT NULL,
        FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
      )
    ''');
    _database.execute(
      'CREATE INDEX IF NOT EXISTS sessions_ended_at_idx '
      'ON sessions(ended_at DESC, id DESC)',
    );
    _database.execute(
      'CREATE INDEX IF NOT EXISTS transfers_session_idx '
      'ON transfers(session_id, updated_at DESC)',
    );
  }

  Future<void> upsertSession(SessionRecord record) async {
    final encrypted = await _cipher.encrypt(record.toJson());
    _database.execute(
      '''
      INSERT INTO sessions(id, started_at, ended_at, role, encrypted_payload)
      VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        started_at=excluded.started_at,
        ended_at=excluded.ended_at,
        role=excluded.role,
        encrypted_payload=excluded.encrypted_payload
      ''',
      [
        record.id,
        record.startedAt.millisecondsSinceEpoch,
        record.endedAt.millisecondsSinceEpoch,
        record.role,
        encrypted,
      ],
    );
  }

  Future<void> upsertTransfer(FileTransferAuditRecord record) async {
    final encrypted = await _cipher.encrypt(record.toJson());
    _database.execute(
      '''
      INSERT INTO transfers(id, session_id, updated_at, state, encrypted_payload)
      VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        session_id=excluded.session_id,
        updated_at=excluded.updated_at,
        state=excluded.state,
        encrypted_payload=excluded.encrypted_payload
      ''',
      [
        record.id,
        record.sessionId,
        record.updatedAt.millisecondsSinceEpoch,
        record.state,
        encrypted,
      ],
    );
  }

  Future<SessionAuditPage> loadSessions({
    String? cursor,
    int pageSize = sessionAuditPageSize,
  }) async {
    final safePageSize = pageSize.clamp(1, 100);
    final cursorValue = _decodeCursor(cursor);
    final rows = cursorValue == null
        ? _database.select(
            'SELECT id, ended_at, encrypted_payload FROM sessions '
            'ORDER BY ended_at DESC, id DESC LIMIT ?',
            [safePageSize + 1],
          )
        : _database.select(
            'SELECT id, ended_at, encrypted_payload FROM sessions '
            'WHERE ended_at < ? OR (ended_at = ? AND id < ?) '
            'ORDER BY ended_at DESC, id DESC LIMIT ?',
            [cursorValue.$1, cursorValue.$1, cursorValue.$2, safePageSize + 1],
          );
    final hasMore = rows.length > safePageSize;
    final visibleRows = hasMore ? rows.take(safePageSize) : rows;
    final records = <SessionRecord>[];
    for (final row in visibleRows) {
      final decoded = await _cipher.decrypt(row['encrypted_payload'] as String);
      records.add(SessionRecord.fromJson(decoded));
    }
    final last = records.lastOrNull;
    return SessionAuditPage(
      records: List.unmodifiable(records),
      nextCursor: hasMore && last != null
          ? _encodeCursor(last.endedAt.millisecondsSinceEpoch, last.id)
          : null,
    );
  }

  Future<List<FileTransferAuditRecord>> loadTransfers(String sessionId) async {
    final rows = _database.select(
      'SELECT encrypted_payload FROM transfers WHERE session_id = ? '
      'ORDER BY updated_at DESC',
      [sessionId],
    );
    final records = <FileTransferAuditRecord>[];
    for (final row in rows) {
      final decoded = await _cipher.decrypt(row['encrypted_payload'] as String);
      records.add(FileTransferAuditRecord.fromJson(decoded));
    }
    return List.unmodifiable(records);
  }

  Future<void> prune(int maximumSessions) async {
    _database.execute(
      'DELETE FROM sessions WHERE id NOT IN '
      '(SELECT id FROM sessions ORDER BY ended_at DESC, id DESC LIMIT ?)',
      [maximumSessions.clamp(10, 10000)],
    );
  }

  Future<void> clear() async {
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute('DELETE FROM transfers');
      _database.execute('DELETE FROM sessions');
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  void close() => _database.close();

  static String _encodeCursor(int endedAt, String id) =>
      base64UrlEncode(utf8.encode(jsonEncode({'endedAt': endedAt, 'id': id})));

  static (int, String)? _decodeCursor(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(utf8.decode(base64Url.decode(value)));
      if (decoded is! Map) return null;
      final endedAt = decoded['endedAt'];
      final id = decoded['id'];
      if (endedAt is! num || id is! String) return null;
      return (endedAt.toInt(), id);
    } catch (_) {
      return null;
    }
  }
}

class _SessionAuditCipher {
  _SessionAuditCipher(List<int> key)
    : _secretKey = SecretKey(List.unmodifiable(key)) {
    if (key.length != 32) throw ArgumentError.value(key.length, 'key.length');
  }

  final SecretKey _secretKey;
  final AesGcm _algorithm = AesGcm.with256bits();

  Future<String> encrypt(Map<String, dynamic> value) async {
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: _secretKey,
    );
    return jsonEncode({
      'v': 1,
      'nonce': base64UrlEncode(box.nonce),
      'cipherText': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    });
  }

  Future<Map<String, dynamic>> decrypt(String value) async {
    final envelope = jsonDecode(value) as Map<String, dynamic>;
    final clearText = await _algorithm.decrypt(
      SecretBox(
        base64Url.decode(envelope['cipherText'] as String),
        nonce: base64Url.decode(envelope['nonce'] as String),
        mac: Mac(base64Url.decode(envelope['mac'] as String)),
      ),
      secretKey: _secretKey,
    );
    return (jsonDecode(utf8.decode(clearText)) as Map).cast<String, dynamic>();
  }
}
