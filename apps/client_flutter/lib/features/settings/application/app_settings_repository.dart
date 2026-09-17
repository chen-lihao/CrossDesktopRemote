import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

abstract interface class AppSettingsRepository {
  Future<Map<String, dynamic>?> read();

  Future<void> write(Map<String, dynamic> value);

  void close();
}

class SqliteAppSettingsRepository implements AppSettingsRepository {
  SqliteAppSettingsRepository._(this._database) {
    _database.execute('PRAGMA journal_mode = WAL');
    _database.execute('PRAGMA synchronous = FULL');
    _database.execute('''
      CREATE TABLE IF NOT EXISTS app_settings (
        singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
        schema_version INTEGER NOT NULL,
        payload TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  static const schemaVersion = 1;
  static const _databaseName = 'app-settings-v1.sqlite3';

  final Database _database;

  static Future<SqliteAppSettingsRepository> open({
    String? databasePath,
  }) async {
    final path = databasePath ?? await _defaultDatabasePath();
    return SqliteAppSettingsRepository._(sqlite3.open(path));
  }

  static Future<String> _defaultDatabasePath() async {
    final support = await getApplicationSupportDirectory();
    // path_provider appends the current bundle identifier on macOS. Development
    // and release builds intentionally use different identifiers, but they are
    // still the same installed product and must not appear to lose all local
    // configuration when the signing variant changes.
    final root = Platform.isMacOS ? support.parent : support;
    final directory = Directory(
      '${root.path}${Platform.pathSeparator}CrossDesktopRemote'
      '${Platform.pathSeparator}settings',
    );
    if (!directory.existsSync()) {
      directory.createSync(recursive: true);
    }
    return '${directory.path}${Platform.pathSeparator}$_databaseName';
  }

  @override
  Future<Map<String, dynamic>?> read() async {
    final rows = _database.select(
      'SELECT schema_version, payload FROM app_settings WHERE singleton = 1',
    );
    if (rows.isEmpty) return null;
    final schema = rows.first['schema_version'] as int;
    if (schema > schemaVersion) {
      throw StateError('Unsupported settings schema version: $schema');
    }
    final decoded = jsonDecode(rows.first['payload'] as String);
    if (decoded is! Map) throw const FormatException('Invalid settings data');
    return decoded.cast<String, dynamic>();
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    final payload = jsonEncode(value);
    _database.execute('BEGIN IMMEDIATE');
    try {
      _database.execute(
        '''
        INSERT INTO app_settings(singleton, schema_version, payload, updated_at)
        VALUES(1, ?, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET
          schema_version=excluded.schema_version,
          payload=excluded.payload,
          updated_at=excluded.updated_at
        ''',
        [schemaVersion, payload, DateTime.now().millisecondsSinceEpoch],
      );
      _database.execute('COMMIT');
    } catch (_) {
      _database.execute('ROLLBACK');
      rethrow;
    }
  }

  @override
  void close() => _database.close();
}

class MemoryAppSettingsRepository implements AppSettingsRepository {
  MemoryAppSettingsRepository([Map<String, dynamic>? initial])
    : _value = initial == null ? null : Map.of(initial);

  Map<String, dynamic>? _value;

  @override
  Future<Map<String, dynamic>?> read() async =>
      _value == null ? null : Map.of(_value!);

  @override
  Future<void> write(Map<String, dynamic> value) async {
    _value = Map.of(value);
  }

  @override
  void close() {}
}
