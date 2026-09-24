import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:cross_desktop_remote/core/diagnostics/diagnostic_event.dart';
import 'package:cross_desktop_remote/core/diagnostics/diagnostic_redactor.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Process-wide, local-first diagnostic sink.
///
/// The hot path only appends a bounded in-memory breadcrumb and schedules an
/// ordered file write. Audit records remain in their existing encrypted store;
/// this class is intentionally for short-lived operational diagnostics only.
class DiagnosticHub extends ChangeNotifier {
  DiagnosticHub._();

  @visibleForTesting
  DiagnosticHub.forTesting();

  static final instance = DiagnosticHub._();

  static const maxBreadcrumbs = 256;
  static const maxSegmentBytes = 5 * 1024 * 1024;
  static const maxSegments = 10;
  static const maxCrashAttachments = 3;
  static const maxCrashAttachmentBytes = 10 * 1024 * 1024;
  static const normalRetention = Duration(days: 7);
  static const detailedDuration = Duration(minutes: 15);

  final Stopwatch _monotonic = Stopwatch();
  final List<DiagnosticEvent> _breadcrumbs = [];
  final List<DiagnosticEvent> _pendingPersistence = [];
  Future<void> _writeQueue = Future<void>.value();
  Directory? _root;
  File? _activeLog;
  DiagnosticRedactor? _redactor;
  Timer? _detailedTimer;
  bool _initialized = false;
  Object? _lastStorageError;
  int _persistedEventCount = 0;
  int _storageBytes = 0;
  String _bootId = 'bootstrap';
  DiagnosticMode _mode = DiagnosticMode.normal;

  bool get initialized => _initialized;
  String? get diagnosticDirectory => _root?.path;
  String get bootId => _bootId;
  DiagnosticMode get mode => _mode;
  Object? get lastStorageError => _lastStorageError;
  int get persistedEventCount => _persistedEventCount;
  int get storageBytes => _storageBytes;
  List<DiagnosticEvent> get breadcrumbs => List.unmodifiable(_breadcrumbs);

  Future<void> initialize({Directory? rootDirectory}) async {
    if (_initialized) return;
    _bootId = _opaqueId();
    _monotonic.start();
    try {
      final support = rootDirectory ?? await getApplicationSupportDirectory();
      _root = Directory(
        '${support.path}${Platform.pathSeparator}diagnostics-v1',
      );
      await _root!.create(recursive: true);
      _activeLog = File(
        '${_root!.path}${Platform.pathSeparator}events-0.jsonl',
      );
      _redactor = DiagnosticRedactor(utf8.encode(_bootId));
      await _pruneExpiredFiles();
      await _refreshStorageUsage();
      _initialized = true;
      final pending = List<DiagnosticEvent>.of(_pendingPersistence);
      _pendingPersistence.clear();
      for (final event in pending) {
        _enqueuePersistence(event);
      }
      record(
        component: 'app.lifecycle',
        name: 'process_started',
        attributes: {
          'platform': Platform.operatingSystem,
          'operatingSystemVersion': Platform.operatingSystemVersion,
          'buildId': const String.fromEnvironment(
            'CDR_BUILD_ID',
            defaultValue: 'development',
          ),
          'dartVersion': Platform.version,
        },
      );
    } catch (error, stackTrace) {
      _lastStorageError = error;
      _initialized = true;
      debugPrint(
        'CrossDesktopRemote diagnostics unavailable: $error\n$stackTrace',
      );
    }
    notifyListeners();
  }

  void record({
    required String component,
    required String name,
    DiagnosticSeverity severity = DiagnosticSeverity.info,
    String? errorCode,
    DiagnosticContext context = const DiagnosticContext(),
    Map<String, Object?> attributes = const {},
  }) {
    final redactor = _redactor ?? DiagnosticRedactor(utf8.encode('bootstrap'));
    final event = DiagnosticEvent(
      timestampUtc: DateTime.now().toUtc(),
      monotonicMs: _monotonic.elapsedMilliseconds,
      bootId: _bootIdOrBootstrap,
      severity: severity,
      component: _safeName(component, 'unknown'),
      name: _safeName(name, 'event'),
      errorCode: errorCode == null ? null : _safeName(errorCode, 'UNKNOWN'),
      context: context,
      attributes: redactor.sanitizeAttributes(attributes),
    );
    _breadcrumbs.add(event);
    if (_breadcrumbs.length > maxBreadcrumbs) _breadcrumbs.removeAt(0);
    if (severity == DiagnosticSeverity.debug &&
        _mode != DiagnosticMode.detailed) {
      return;
    }
    if (!_initialized) {
      _pendingPersistence.add(event);
      if (_pendingPersistence.length > maxBreadcrumbs) {
        _pendingPersistence.removeAt(0);
      }
      return;
    }
    if (_activeLog == null) return;
    _enqueuePersistence(event);
  }

  void _enqueuePersistence(DiagnosticEvent event) {
    _writeQueue = _writeQueue
        .catchError((_) {})
        .then((_) => _append(event))
        .catchError((Object error, StackTrace stackTrace) {
          _lastStorageError = error;
          debugPrint('CrossDesktopRemote diagnostic write failed: $error');
        });
  }

  void recordError({
    required String component,
    required String name,
    required Object error,
    required StackTrace stackTrace,
    String? errorCode,
    DiagnosticContext context = const DiagnosticContext(),
    bool fatal = false,
  }) {
    record(
      component: component,
      name: name,
      severity: fatal ? DiagnosticSeverity.critical : DiagnosticSeverity.error,
      errorCode: errorCode,
      context: context,
      attributes: {
        'errorType': error.runtimeType.toString(),
        'error': '$error',
        'stack': '$stackTrace',
      },
    );
  }

  Future<void> setDetailedMode(bool enabled) async {
    _detailedTimer?.cancel();
    _mode = enabled ? DiagnosticMode.detailed : DiagnosticMode.normal;
    if (enabled) {
      _detailedTimer = Timer(detailedDuration, () {
        _mode = DiagnosticMode.normal;
        record(component: 'diagnostics', name: 'detailed_mode_expired');
        notifyListeners();
      });
    }
    record(
      component: 'diagnostics',
      name: enabled ? 'detailed_mode_enabled' : 'detailed_mode_disabled',
    );
    notifyListeners();
  }

  Future<DiagnosticExportResult> exportBundle({Directory? destination}) async {
    await flush();
    final root = _root;
    if (root == null) throw StateError('诊断存储不可用');
    final exportDirectory =
        destination ??
        Directory('${root.path}${Platform.pathSeparator}exports');
    await exportDirectory.create(recursive: true);
    final now = DateTime.now().toUtc();
    final name =
        'crossdesktop-${now.toIso8601String().replaceAll(':', '-')}.cdrdiag';
    final output = File(
      '${exportDirectory.path}${Platform.pathSeparator}$name',
    );
    final events = <Object?>[];
    for (final file in await _logFiles()) {
      await for (final line
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        try {
          events.add(jsonDecode(line));
        } catch (_) {
          // A process crash may leave one partial tail record. Earlier records
          // remain authoritative and exportable.
        }
      }
    }
    final attachments = <Map<String, Object?>>[];
    for (final file in await _crashFiles()) {
      final length = await file.length();
      if (length <= 0 || length > maxCrashAttachmentBytes) continue;
      attachments.add({
        'name': file.uri.pathSegments.last,
        'size': length,
        'sha256': sha256.convert(await file.readAsBytes()).toString(),
        'contentBase64': base64Encode(await file.readAsBytes()),
      });
    }
    final payload = {
      'format': 'crossdesktop-diagnostics',
      'version': 1,
      'exportedAtUtc': now.toIso8601String(),
      'privacy': {
        'redacted': true,
        'automaticUpload': false,
        'containsCrashMemory': attachments.isNotEmpty,
      },
      'manifest': {
        'platform': Platform.operatingSystem,
        'operatingSystemVersion': Platform.operatingSystemVersion,
        'buildId': const String.fromEnvironment(
          'CDR_BUILD_ID',
          defaultValue: 'development',
        ),
        'eventCount': events.length,
        'attachmentCount': attachments.length,
      },
      'events': events,
      'attachments': attachments,
    };
    await output.writeAsString(jsonEncode(payload), flush: true);
    record(
      component: 'diagnostics',
      name: 'bundle_exported',
      attributes: {
        'eventCount': events.length,
        'attachmentCount': attachments.length,
      },
    );
    return DiagnosticExportResult(
      path: output.path,
      eventCount: events.length,
      attachmentCount: attachments.length,
    );
  }

  Future<void> clear() async {
    await flush();
    final root = _root;
    if (root == null) return;
    for (final file in await _logFiles()) {
      if (await file.exists()) await file.delete();
    }
    _breadcrumbs.clear();
    _activeLog = File('${root.path}${Platform.pathSeparator}events-0.jsonl');
    _persistedEventCount = 0;
    _storageBytes = 0;
    _lastStorageError = null;
    record(component: 'diagnostics', name: 'local_data_cleared');
    notifyListeners();
  }

  Future<void> markCleanShutdown() async {
    record(component: 'app.lifecycle', name: 'process_stopping');
    await flush();
  }

  Future<void> flush() => _writeQueue.catchError((_) {});

  Future<void> _append(DiagnosticEvent event) async {
    await _rotateIfNeeded();
    final encoded = '${jsonEncode(event.toJson())}\n';
    await _activeLog!.writeAsString(
      encoded,
      mode: FileMode.append,
      flush: event.severity == DiagnosticSeverity.critical,
    );
    _persistedEventCount += 1;
    _storageBytes += utf8.encode(encoded).length;
    if (_persistedEventCount % 25 == 0) notifyListeners();
  }

  Future<void> _rotateIfNeeded() async {
    final active = _activeLog!;
    if (await active.exists() && await active.length() < maxSegmentBytes) {
      return;
    }
    for (var index = maxSegments - 1; index >= 1; index--) {
      final current = File(
        '${_root!.path}${Platform.pathSeparator}events-$index.jsonl',
      );
      final previous = File(
        '${_root!.path}${Platform.pathSeparator}events-${index - 1}.jsonl',
      );
      if (await current.exists()) await current.delete();
      if (await previous.exists()) await previous.rename(current.path);
    }
    _activeLog = File('${_root!.path}${Platform.pathSeparator}events-0.jsonl');
  }

  Future<List<File>> _logFiles() async {
    final root = _root;
    if (root == null || !await root.exists()) return const [];
    final files = await root
        .list()
        .where(
          (entry) =>
              entry is File &&
              RegExp(r'events-[0-9]+\.jsonl$').hasMatch(entry.path),
        )
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    return files;
  }

  Future<List<File>> _crashFiles() async {
    final directories = <Directory>[
      Directory('${_root!.path}${Platform.pathSeparator}crashes'),
      if (Platform.environment['LOCALAPPDATA'] case final local?)
        Directory(
          '$local${Platform.pathSeparator}CrossDesktopRemote${Platform.pathSeparator}Crashes',
        ),
    ];
    final files = <File>[];
    for (final directory in directories) {
      if (!await directory.exists()) continue;
      files.addAll(
        await directory
            .list()
            .where((entry) => entry is File)
            .cast<File>()
            .toList(),
      );
    }
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files.take(maxCrashAttachments).toList(growable: false);
  }

  Future<void> _pruneExpiredFiles() async {
    final cutoff = DateTime.now().subtract(normalRetention);
    for (final file in await _logFiles()) {
      if ((await file.lastModified()).isBefore(cutoff)) await file.delete();
    }
  }

  Future<void> _refreshStorageUsage() async {
    _storageBytes = 0;
    _persistedEventCount = 0;
    for (final file in await _logFiles()) {
      _storageBytes += await file.length();
      await for (final _
          in file
              .openRead()
              .transform(utf8.decoder)
              .transform(const LineSplitter())) {
        _persistedEventCount += 1;
      }
    }
  }

  String get _bootIdOrBootstrap => _bootId;

  static String _safeName(String value, String fallback) {
    final normalized = value.trim().replaceAll(RegExp(r'[^A-Za-z0-9_.-]'), '_');
    return normalized.isEmpty
        ? fallback
        : normalized.substring(0, min(96, normalized.length));
  }

  static String _opaqueId() {
    final random = Random.secure();
    return List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    _detailedTimer?.cancel();
    super.dispose();
  }
}
