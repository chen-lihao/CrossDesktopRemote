import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

class TrustedDeviceRepository {
  TrustedDeviceRepository._(this._database, this._cipher);

  static const _secureKeyName = 'crossdesktop.trusted-devices-key.v1';
  static const _databaseName = 'trusted-devices-v1.sqlite3';

  final Database _database;
  final _TrustedDeviceCipher _cipher;

  static Future<TrustedDeviceRepository> open({
    String? databasePath,
    List<int>? encryptionKey,
  }) async {
    final path = databasePath ?? await _defaultDatabasePath();
    final key = encryptionKey ?? await _loadOrCreateKey();
    final database = path == ':memory:'
        ? sqlite3.openInMemory()
        : sqlite3.open(path);
    final repository = TrustedDeviceRepository._(
      database,
      _TrustedDeviceCipher(key),
    );
    repository._initialize();
    return repository;
  }

  static Future<String> _defaultDatabasePath() async {
    final root = await getApplicationSupportDirectory();
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}security',
    );
    if (!directory.existsSync()) directory.createSync(recursive: true);
    return '${directory.path}${Platform.pathSeparator}$_databaseName';
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
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS trusted_devices (
        peer_fingerprint TEXT NOT NULL,
        local_is_issuer INTEGER NOT NULL,
        machine_code TEXT NOT NULL,
        soft_expires_at INTEGER NOT NULL,
        hard_expires_at INTEGER NOT NULL,
        last_connected_at INTEGER NOT NULL,
        revoked_at INTEGER,
        encrypted_payload TEXT NOT NULL,
        PRIMARY KEY(peer_fingerprint, local_is_issuer)
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS revoked_grants (
        grant_id TEXT PRIMARY KEY,
        revoked_at INTEGER NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS trust_audit (
        id TEXT PRIMARY KEY,
        occurred_at INTEGER NOT NULL,
        action TEXT NOT NULL,
        encrypted_payload TEXT NOT NULL
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS trust_settings (
        setting_key TEXT PRIMARY KEY,
        encrypted_payload TEXT NOT NULL
      )
    ''');
    _database.execute(
      'CREATE INDEX IF NOT EXISTS trusted_devices_expiry_idx '
      'ON trusted_devices(revoked_at, soft_expires_at, last_connected_at DESC)',
    );
    _database.execute(
      'CREATE INDEX IF NOT EXISTS trust_audit_time_idx '
      'ON trust_audit(occurred_at DESC)',
    );
  }

  Future<void> upsert(TrustedDeviceRecord record) async {
    final peerFingerprint = base64UrlEncode(
      record.peerIdentity.rootFingerprint,
    );
    final localIsIssuer = record.localIsIssuer ? 1 : 0;
    final encrypted = await _cipher.encrypt(
      record.toJson(),
      aad: _rowAad(peerFingerprint, localIsIssuer),
    );
    _database.execute(
      '''
      INSERT INTO trusted_devices(
        peer_fingerprint, local_is_issuer, machine_code, soft_expires_at,
        hard_expires_at, last_connected_at, revoked_at, encrypted_payload
      ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(peer_fingerprint, local_is_issuer) DO UPDATE SET
        machine_code=excluded.machine_code,
        soft_expires_at=excluded.soft_expires_at,
        hard_expires_at=excluded.hard_expires_at,
        last_connected_at=excluded.last_connected_at,
        revoked_at=excluded.revoked_at,
        encrypted_payload=excluded.encrypted_payload
      ''',
      [
        peerFingerprint,
        localIsIssuer,
        record.peerIdentity.machineCode,
        record.grant.softExpiresAt.millisecondsSinceEpoch,
        record.grant.hardExpiresAt.millisecondsSinceEpoch,
        record.lastConnectedAt.millisecondsSinceEpoch,
        record.revokedAt?.millisecondsSinceEpoch,
        encrypted,
      ],
    );
  }

  Future<List<TrustedDeviceRecord>> list({bool includeRevoked = false}) async {
    final rows = _database.select('''
      SELECT peer_fingerprint, local_is_issuer, encrypted_payload
      FROM trusted_devices
      ${includeRevoked ? '' : 'WHERE revoked_at IS NULL'}
      ORDER BY last_connected_at DESC
      ''');
    final records = <TrustedDeviceRecord>[];
    for (final row in rows) {
      try {
        records.add(
          TrustedDeviceRecord.fromJson(
            await _cipher.decrypt(
              row['encrypted_payload'] as String,
              aad: _rowAad(
                row['peer_fingerprint'] as String,
                row['local_is_issuer'] as int,
              ),
            ),
          ),
        );
      } catch (_) {
        // A corrupt or foreign encrypted row is never treated as trusted.
      }
    }
    return List.unmodifiable(records);
  }

  Future<TrustedDeviceRecord?> findByMachineCode(
    String machineCode, {
    required bool localIsIssuer,
  }) async {
    final localIsIssuerValue = localIsIssuer ? 1 : 0;
    final rows = _database.select(
      '''
      SELECT peer_fingerprint, local_is_issuer, encrypted_payload
      FROM trusted_devices
      WHERE machine_code = ? AND local_is_issuer = ? AND revoked_at IS NULL
      LIMIT 1
      ''',
      [machineCode.trim().toUpperCase(), localIsIssuerValue],
    );
    if (rows.isEmpty) return null;
    try {
      return TrustedDeviceRecord.fromJson(
        await _cipher.decrypt(
          rows.first['encrypted_payload'] as String,
          aad: _rowAad(
            rows.first['peer_fingerprint'] as String,
            rows.first['local_is_issuer'] as int,
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> isGrantRevoked(List<int> grantId) async {
    final rows = _database.select(
      'SELECT 1 FROM revoked_grants WHERE grant_id = ? LIMIT 1',
      [base64UrlEncode(grantId)],
    );
    return rows.isNotEmpty;
  }

  Future<void> revoke(TrustedDeviceRecord record, DateTime now) async {
    final revoked = record.copyWith(revokedAt: now.toUtc());
    _database.execute('BEGIN IMMEDIATE');
    try {
      await upsert(revoked);
      _database.execute(
        'INSERT OR REPLACE INTO revoked_grants(grant_id, revoked_at) '
        'VALUES(?, ?)',
        [base64UrlEncode(record.grant.grantId), now.millisecondsSinceEpoch],
      );
      final previous = record.previousGrant;
      if (previous != null) {
        _database.execute(
          'INSERT OR REPLACE INTO revoked_grants(grant_id, revoked_at) '
          'VALUES(?, ?)',
          [base64UrlEncode(previous.grantId), now.millisecondsSinceEpoch],
        );
      }
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  Future<void> deleteExpired(DateTime now) async {
    _database.execute(
      'DELETE FROM trusted_devices WHERE hard_expires_at <= ?',
      [now.millisecondsSinceEpoch],
    );
  }

  Future<void> appendAudit(TrustedAuditRecord record) async {
    final encrypted = await _cipher.encrypt(
      record.toJson(),
      aad: _auditAad(record.id),
    );
    _database.execute(
      'INSERT INTO trust_audit(id, occurred_at, action, encrypted_payload) '
      'VALUES(?, ?, ?, ?)',
      [
        record.id,
        record.occurredAt.millisecondsSinceEpoch,
        record.action.name,
        encrypted,
      ],
    );
  }

  Future<List<TrustedAuditRecord>> listAudit({
    int limit = 50,
    int offset = 0,
  }) async {
    final safeLimit = limit.clamp(1, 100);
    final safeOffset = offset.clamp(0, 1000000);
    final rows = _database.select(
      'SELECT id, encrypted_payload FROM trust_audit '
      'ORDER BY occurred_at DESC LIMIT ? OFFSET ?',
      [safeLimit, safeOffset],
    );
    final records = <TrustedAuditRecord>[];
    for (final row in rows) {
      try {
        final id = row['id'] as String;
        records.add(
          TrustedAuditRecord.fromJson(
            await _cipher.decrypt(
              row['encrypted_payload'] as String,
              aad: _auditAad(id),
            ),
          ),
        );
      } catch (_) {
        // Corrupt audit rows are not surfaced as authoritative history.
      }
    }
    return List.unmodifiable(records);
  }

  Future<bool> readConnectionsPaused() async {
    const key = 'connections-paused';
    final rows = _database.select(
      'SELECT encrypted_payload FROM trust_settings WHERE setting_key = ?',
      [key],
    );
    if (rows.isEmpty) return false;
    try {
      final value = await _cipher.decrypt(
        rows.first['encrypted_payload'] as String,
        aad: _settingAad(key),
      );
      return value['paused'] == true;
    } catch (_) {
      // Fail closed when a security preference cannot be authenticated.
      return true;
    }
  }

  Future<void> writeConnectionsPaused(bool paused) async {
    const key = 'connections-paused';
    final encrypted = await _cipher.encrypt({
      'paused': paused,
    }, aad: _settingAad(key));
    _database.execute(
      'INSERT INTO trust_settings(setting_key, encrypted_payload) VALUES(?, ?) '
      'ON CONFLICT(setting_key) DO UPDATE SET '
      'encrypted_payload=excluded.encrypted_payload',
      [key, encrypted],
    );
  }

  void close() => _database.close();

  static List<int> _rowAad(String peerFingerprint, int localIsIssuer) =>
      utf8.encode(
        'CrossDesktopRemote/TrustedDeviceRow/v1\n'
        '$peerFingerprint\n$localIsIssuer',
      );

  static List<int> _auditAad(String id) =>
      utf8.encode('CrossDesktopRemote/TrustAuditRow/v1\n$id');

  static List<int> _settingAad(String key) =>
      utf8.encode('CrossDesktopRemote/TrustSettingRow/v1\n$key');
}

class _TrustedDeviceCipher {
  _TrustedDeviceCipher(List<int> key)
    : _secretKey = SecretKeyData(key, overwriteWhenDestroyed: false);

  final SecretKey _secretKey;
  final AesGcm _algorithm = AesGcm.with256bits();

  Future<String> encrypt(
    Map<String, dynamic> value, {
    required List<int> aad,
  }) async {
    final box = await _algorithm.encrypt(
      utf8.encode(jsonEncode(value)),
      secretKey: _secretKey,
      aad: aad,
    );
    return jsonEncode({
      'v': 2,
      'nonce': base64UrlEncode(box.nonce),
      'cipherText': base64UrlEncode(box.cipherText),
      'mac': base64UrlEncode(box.mac.bytes),
    });
  }

  Future<Map<String, dynamic>> decrypt(
    String encoded, {
    required List<int> aad,
  }) async {
    final value = jsonDecode(encoded) as Map<String, dynamic>;
    if (value['v'] != 2) throw const FormatException('Unsupported cipher');
    final clearText = await _algorithm.decrypt(
      SecretBox(
        base64Url.decode(value['cipherText'] as String),
        nonce: base64Url.decode(value['nonce'] as String),
        mac: Mac(base64Url.decode(value['mac'] as String)),
      ),
      secretKey: _secretKey,
      aad: aad,
    );
    return jsonDecode(utf8.decode(clearText)) as Map<String, dynamic>;
  }
}
