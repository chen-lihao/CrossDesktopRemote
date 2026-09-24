import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Applies the mandatory privacy boundary before diagnostic data is persisted.
///
/// Callers never decide whether a value is sensitive. Unknown nested values are
/// normalized here, so a newly instrumented subsystem cannot accidentally put
/// connection codes, clipboard content or credentials into a log file.
class DiagnosticRedactor {
  DiagnosticRedactor(this._salt);

  final List<int> _salt;

  static final _secretKey = RegExp(
    r'(password|passcode|token|secret|private|credential|clipboard|keyText|'
    r'connectionCode|roomCode|room|sdp|candidate|authorization|challenge|'
    r'signature|fileContent|screenContent)',
    caseSensitive: false,
  );
  static final _pseudonymKey = RegExp(
    r'(deviceId|machineCode|peerId|address|ip|host|filePath|sourcePath|'
    r'destinationPath|destinationRoot)',
    caseSensitive: false,
  );
  static final _ipv4 = RegExp(
    r'(?<![0-9])(?:[0-9]{1,3}\.){3}[0-9]{1,3}(?![0-9])',
  );
  static final _machineCode = RegExp(
    r'CDR2(?:-[0-9A-HJKMNP-TV-Z]{1,4}){4,8}',
    caseSensitive: false,
  );
  static final _connectionCode = RegExp(r'(?<![0-9])[0-9]{6}(?![0-9])');
  static final _unixHome = RegExp(r'/Users/[^/\s]+/');
  static final _windowsHome = RegExp(
    r'[A-Za-z]:\\Users\\[^\\\s]+\\',
    caseSensitive: false,
  );

  Map<String, Object?> sanitizeAttributes(Map<String, Object?> value) => {
    for (final entry in value.entries)
      entry.key: sanitize(entry.key, entry.value),
  };

  Object? sanitize(String key, Object? value) {
    if (value == null || value is num || value is bool) return value;
    if (_secretKey.hasMatch(key)) return '[redacted]';
    if (_pseudonymKey.hasMatch(key)) return _pseudonym(value.toString());
    if (value is Map) {
      return {
        for (final entry in value.entries)
          entry.key.toString(): sanitize(entry.key.toString(), entry.value),
      };
    }
    if (value is Iterable) {
      return value
          .take(128)
          .map((item) => sanitize(key, item))
          .toList(growable: false);
    }
    return sanitizeText(value.toString());
  }

  String sanitizeText(String value) {
    var result = value;
    result = result.replaceAllMapped(
      _machineCode,
      (match) => _pseudonym(match.group(0)!),
    );
    result = result.replaceAllMapped(
      _ipv4,
      (match) => _pseudonym(match.group(0)!),
    );
    result = result.replaceAll(_connectionCode, '[connection-code]');
    result = result.replaceAll(_unixHome, '~/');
    result = result.replaceAll(_windowsHome, r'%USERPROFILE%\');
    return result.length <= 8192 ? result : '${result.substring(0, 8192)}…';
  }

  String _pseudonym(String value) {
    final digest = sha256.convert([..._salt, ...utf8.encode(value)]).toString();
    return '<hash:${digest.substring(0, 12)}>';
  }
}
