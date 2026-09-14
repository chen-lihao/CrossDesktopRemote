import 'dart:convert';
import 'dart:io';

import 'package:cross_desktop_remote/core/security/platform_secret_store.dart';
import 'package:cross_desktop_remote/core/security/trusted_device_models.dart';
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

enum TrustedPairingTransactionState { pending, committed }

class TrustedPairingCommitResult {
  const TrustedPairingCommitResult({
    required this.record,
    required this.committedNow,
  });

  final TrustedDeviceRecord record;
  final bool committedNow;
}

class TrustedDeviceRepository {
  TrustedDeviceRepository._(this._database, this._cipher);

  static const _secureKeyName = 'crossdesktop.trusted-devices-key.v1';
  static const _databaseName = 'trusted-devices-v1.sqlite3';

  final Database _database;
  final _TrustedDeviceCipher _cipher;

  static Future<TrustedDeviceRepository> open({
    String? databasePath,
    List<int>? encryptionKey,
    PlatformSecretStore? secretStore,
  }) async {
    final path = databasePath ?? await _defaultDatabasePath();
    final key =
        encryptionKey ??
        await (secretStore ?? MethodChannelPlatformSecretStore()).loadOrCreate(
          _secureKeyName,
        );
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
    _database.execute('''
      CREATE TABLE IF NOT EXISTS trusted_pairing_transactions (
        pairing_session_id TEXT NOT NULL,
        grant_id TEXT NOT NULL,
        state TEXT NOT NULL,
        expires_at INTEGER NOT NULL,
        encrypted_payload TEXT NOT NULL,
        PRIMARY KEY(pairing_session_id, grant_id)
      )
    ''');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS host_access_policies (
        controller_fingerprint TEXT PRIMARY KEY,
        revision INTEGER NOT NULL,
        enabled INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
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
    _database.execute(
      'CREATE INDEX IF NOT EXISTS trusted_pairing_expiry_idx '
      'ON trusted_pairing_transactions(expires_at)',
    );
  }

  Future<void> stagePairing({
    required String pairingSessionId,
    required TrustedDeviceRecord record,
    required DateTime expiresAt,
  }) async {
    final sessionBytes = utf8.encode(pairingSessionId);
    record.grant.validateStructure();
    if (sessionBytes.isEmpty ||
        sessionBytes.length > trustedMaximumSessionIdBytes ||
        !expiresAt.toUtc().isAfter(record.createdAt.toUtc())) {
      throw const FormatException('Invalid pairing transaction');
    }
    final grantId = base64UrlEncode(record.grant.grantId);
    final existing = await _readPairing(
      pairingSessionId: pairingSessionId,
      grantId: grantId,
    );
    if (existing != null) {
      if (jsonEncode(existing.record.toJson()) != jsonEncode(record.toJson())) {
        throw StateError('Pairing transaction is immutable');
      }
      return;
    }
    final encrypted = await _cipher.encrypt(
      record.toJson(),
      aad: _pairingAad(pairingSessionId, grantId),
    );
    _database.execute(
      '''
      INSERT INTO trusted_pairing_transactions(
        pairing_session_id, grant_id, state, expires_at, encrypted_payload
      ) VALUES(?, ?, ?, ?, ?)
      ''',
      [
        pairingSessionId,
        grantId,
        TrustedPairingTransactionState.pending.name,
        expiresAt.toUtc().millisecondsSinceEpoch,
        encrypted,
      ],
    );
  }

  Future<TrustedPairingCommitResult> commitPairing({
    required String pairingSessionId,
    required List<int> grantId,
    required DateTime now,
    Set<TrustedPermission>? initialHostAccessPermissions,
  }) async {
    if (grantId.length != 16) {
      throw const FormatException('Invalid pairing grant id');
    }
    final encodedGrantId = base64UrlEncode(grantId);
    final transaction = await _readPairing(
      pairingSessionId: pairingSessionId,
      grantId: encodedGrantId,
    );
    if (transaction == null) {
      throw StateError('Pairing transaction does not exist');
    }
    if (!now.toUtc().isBefore(transaction.expiresAt)) {
      await discardPairing(
        pairingSessionId: pairingSessionId,
        grantId: grantId,
      );
      throw StateError('Pairing transaction expired');
    }
    HostAccessPolicy? initialPolicy;
    String? encryptedInitialPolicy;
    if (initialHostAccessPermissions != null) {
      if (!transaction.record.localIsIssuer) {
        throw StateError('Only a host pairing may create an access policy');
      }
      final permissions = normalizeHostAccessPermissions(
        initialHostAccessPermissions,
      );
      initialPolicy = HostAccessPolicy(
        controllerRootFingerprint:
            transaction.record.peerIdentity.rootFingerprint,
        revision: 1,
        enabled: true,
        permissions: permissions,
        updatedAt: now.toUtc(),
      );
      initialPolicy.validateStructure();
      final fingerprint = base64UrlEncode(
        initialPolicy.controllerRootFingerprint,
      );
      encryptedInitialPolicy = await _cipher.encrypt(
        initialPolicy.toJson(),
        aad: _hostPolicyAad(fingerprint),
      );
    }
    if (transaction.state == TrustedPairingTransactionState.committed) {
      if (initialPolicy != null && encryptedInitialPolicy != null) {
        _insertInitialHostAccessPolicy(initialPolicy, encryptedInitialPolicy);
      }
      return TrustedPairingCommitResult(
        record: transaction.record,
        committedNow: false,
      );
    }
    final encryptedRecord = await _encryptRecord(transaction.record);
    _database.execute('BEGIN IMMEDIATE');
    try {
      _upsertEncryptedRecord(encryptedRecord);
      if (initialPolicy != null && encryptedInitialPolicy != null) {
        _insertInitialHostAccessPolicy(initialPolicy, encryptedInitialPolicy);
      }
      _database.execute(
        '''
        UPDATE trusted_pairing_transactions
        SET state = ?
        WHERE pairing_session_id = ? AND grant_id = ? AND state = ?
        ''',
        [
          TrustedPairingTransactionState.committed.name,
          pairingSessionId,
          encodedGrantId,
          TrustedPairingTransactionState.pending.name,
        ],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
    return TrustedPairingCommitResult(
      record: transaction.record,
      committedNow: true,
    );
  }

  void _insertInitialHostAccessPolicy(
    HostAccessPolicy policy,
    String encryptedPayload,
  ) {
    _database.execute(
      '''
      INSERT INTO host_access_policies(
        controller_fingerprint, revision, enabled, updated_at, encrypted_payload
      ) VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(controller_fingerprint) DO NOTHING
      ''',
      [
        base64UrlEncode(policy.controllerRootFingerprint),
        policy.revision,
        policy.enabled ? 1 : 0,
        policy.updatedAt.millisecondsSinceEpoch,
        encryptedPayload,
      ],
    );
  }

  Future<void> discardPairing({
    required String pairingSessionId,
    List<int>? grantId,
  }) async {
    if (grantId == null) {
      _database.execute(
        'DELETE FROM trusted_pairing_transactions '
        'WHERE pairing_session_id = ? AND state = ?',
        [pairingSessionId, TrustedPairingTransactionState.pending.name],
      );
      return;
    }
    _database.execute(
      'DELETE FROM trusted_pairing_transactions '
      'WHERE pairing_session_id = ? AND grant_id = ? AND state = ?',
      [
        pairingSessionId,
        base64UrlEncode(grantId),
        TrustedPairingTransactionState.pending.name,
      ],
    );
  }

  Future<void> prunePairingTransactions(DateTime now) async {
    _database.execute(
      'DELETE FROM trusted_pairing_transactions WHERE expires_at <= ?',
      [now.toUtc().millisecondsSinceEpoch],
    );
  }

  Future<_StoredPairingTransaction?> _readPairing({
    required String pairingSessionId,
    required String grantId,
  }) async {
    final rows = _database.select(
      '''
      SELECT state, expires_at, encrypted_payload
      FROM trusted_pairing_transactions
      WHERE pairing_session_id = ? AND grant_id = ?
      LIMIT 1
      ''',
      [pairingSessionId, grantId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    return _StoredPairingTransaction(
      state: TrustedPairingTransactionState.values.byName(
        row['state'] as String,
      ),
      expiresAt: DateTime.fromMillisecondsSinceEpoch(
        row['expires_at'] as int,
        isUtc: true,
      ),
      record: TrustedDeviceRecord.fromJson(
        await _cipher.decrypt(
          row['encrypted_payload'] as String,
          aad: _pairingAad(pairingSessionId, grantId),
        ),
      ),
    );
  }

  Future<void> upsert(TrustedDeviceRecord record) async {
    _upsertEncryptedRecord(await _encryptRecord(record));
  }

  Future<HostAccessPolicy?> readHostAccessPolicy(
    List<int> controllerFingerprint,
  ) async {
    if (controllerFingerprint.length != 32) {
      throw const FormatException('Invalid controller fingerprint');
    }
    final fingerprint = base64UrlEncode(controllerFingerprint);
    final rows = _database.select(
      'SELECT encrypted_payload FROM host_access_policies '
      'WHERE controller_fingerprint = ? LIMIT 1',
      [fingerprint],
    );
    if (rows.isEmpty) return null;
    try {
      final policy = HostAccessPolicy.fromJson(
        await _cipher.decrypt(
          rows.first['encrypted_payload'] as String,
          aad: _hostPolicyAad(fingerprint),
        ),
      );
      policy.validateStructure();
      return policy;
    } catch (error) {
      // Missing and corrupt are deliberately different states. Recreating a
      // corrupt policy from legacy defaults could silently expand access.
      throw StateError('Host access policy is unreadable: $error');
    }
  }

  Future<void> writeHostAccessPolicy(HostAccessPolicy policy) async {
    policy.validateStructure();
    final fingerprint = base64UrlEncode(policy.controllerRootFingerprint);
    final encrypted = await _cipher.encrypt(
      policy.toJson(),
      aad: _hostPolicyAad(fingerprint),
    );
    _database.execute(
      '''
      INSERT INTO host_access_policies(
        controller_fingerprint, revision, enabled, updated_at, encrypted_payload
      ) VALUES(?, ?, ?, ?, ?)
      ON CONFLICT(controller_fingerprint) DO UPDATE SET
        revision=excluded.revision,
        enabled=excluded.enabled,
        updated_at=excluded.updated_at,
        encrypted_payload=excluded.encrypted_payload
      WHERE excluded.revision > host_access_policies.revision
      ''',
      [
        fingerprint,
        policy.revision,
        policy.enabled ? 1 : 0,
        policy.updatedAt.millisecondsSinceEpoch,
        encrypted,
      ],
    );
  }

  Future<bool> replaceHostAccessPolicy(
    HostAccessPolicy policy, {
    required int expectedRevision,
  }) async {
    policy.validateStructure();
    if (expectedRevision < 1 || policy.revision != expectedRevision + 1) {
      throw const FormatException('Invalid host access policy revision');
    }
    final fingerprint = base64UrlEncode(policy.controllerRootFingerprint);
    final encrypted = await _cipher.encrypt(
      policy.toJson(),
      aad: _hostPolicyAad(fingerprint),
    );
    _database.execute(
      '''
      UPDATE host_access_policies
      SET revision = ?, enabled = ?, updated_at = ?, encrypted_payload = ?
      WHERE controller_fingerprint = ? AND revision = ?
      ''',
      [
        policy.revision,
        policy.enabled ? 1 : 0,
        policy.updatedAt.millisecondsSinceEpoch,
        encrypted,
        fingerprint,
        expectedRevision,
      ],
    );
    return _database.updatedRows == 1;
  }

  Future<_EncryptedTrustedDeviceRecord> _encryptRecord(
    TrustedDeviceRecord record,
  ) async {
    final peerFingerprint = base64UrlEncode(
      record.peerIdentity.rootFingerprint,
    );
    final localIsIssuer = record.localIsIssuer ? 1 : 0;
    final encrypted = await _cipher.encrypt(
      record.toJson(),
      aad: _rowAad(peerFingerprint, localIsIssuer),
    );
    return _EncryptedTrustedDeviceRecord(
      record: record,
      peerFingerprint: peerFingerprint,
      localIsIssuer: localIsIssuer,
      encryptedPayload: encrypted,
    );
  }

  void _upsertEncryptedRecord(_EncryptedTrustedDeviceRecord value) {
    final record = value.record;
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
        value.peerFingerprint,
        value.localIsIssuer,
        record.peerIdentity.machineCode,
        record.grant.softExpiresAt.millisecondsSinceEpoch,
        record.grant.hardExpiresAt.millisecondsSinceEpoch,
        record.lastConnectedAt.millisecondsSinceEpoch,
        record.revokedAt?.millisecondsSinceEpoch,
        value.encryptedPayload,
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
      if (record.localIsIssuer) {
        _database.execute(
          'DELETE FROM host_access_policies WHERE controller_fingerprint = ?',
          [base64UrlEncode(record.peerIdentity.rootFingerprint)],
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
    _database.execute('''
      DELETE FROM host_access_policies
      WHERE controller_fingerprint NOT IN (
        SELECT peer_fingerprint FROM trusted_devices
        WHERE local_is_issuer = 1 AND revoked_at IS NULL
      )
      ''');
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

  static List<int> _pairingAad(String pairingSessionId, String grantId) =>
      utf8.encode(
        'CrossDesktopRemote/TrustedPairingRow/v1\n'
        '$pairingSessionId\n$grantId',
      );

  static List<int> _hostPolicyAad(String controllerFingerprint) => utf8.encode(
    'CrossDesktopRemote/HostAccessPolicy/v1\n$controllerFingerprint',
  );
}

class _StoredPairingTransaction {
  const _StoredPairingTransaction({
    required this.state,
    required this.expiresAt,
    required this.record,
  });

  final TrustedPairingTransactionState state;
  final DateTime expiresAt;
  final TrustedDeviceRecord record;
}

class _EncryptedTrustedDeviceRecord {
  const _EncryptedTrustedDeviceRecord({
    required this.record,
    required this.peerFingerprint,
    required this.localIsIssuer,
    required this.encryptedPayload,
  });

  final TrustedDeviceRecord record;
  final String peerFingerprint;
  final int localIsIssuer;
  final String encryptedPayload;
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
