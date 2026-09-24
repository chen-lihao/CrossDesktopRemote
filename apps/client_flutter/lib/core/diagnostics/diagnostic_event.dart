import 'package:flutter/foundation.dart';

enum DiagnosticSeverity { debug, info, warning, error, critical }

enum DiagnosticMode { normal, detailed }

@immutable
class DiagnosticContext {
  const DiagnosticContext({
    this.traceId,
    this.attemptId,
    this.sessionId,
    this.spanId,
    this.role,
  });

  final String? traceId;
  final String? attemptId;
  final String? sessionId;
  final String? spanId;
  final String? role;

  Map<String, Object?> toJson() => {
    if (traceId != null) 'traceId': traceId,
    if (attemptId != null) 'attemptId': attemptId,
    if (sessionId != null) 'sessionId': sessionId,
    if (spanId != null) 'spanId': spanId,
    if (role != null) 'role': role,
  };
}

@immutable
class DiagnosticEvent {
  const DiagnosticEvent({
    required this.timestampUtc,
    required this.monotonicMs,
    required this.bootId,
    required this.severity,
    required this.component,
    required this.name,
    required this.context,
    required this.attributes,
    this.errorCode,
  });

  static const schemaVersion = 1;

  final DateTime timestampUtc;
  final int monotonicMs;
  final String bootId;
  final DiagnosticSeverity severity;
  final String component;
  final String name;
  final String? errorCode;
  final DiagnosticContext context;
  final Map<String, Object?> attributes;

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'timestampUtc': timestampUtc.toUtc().toIso8601String(),
    'monotonicMs': monotonicMs,
    'bootId': bootId,
    'severity': severity.name,
    'component': component,
    'event': name,
    if (errorCode != null) 'errorCode': errorCode,
    ...context.toJson(),
    if (attributes.isNotEmpty) 'attributes': attributes,
  };
}

@immutable
class DiagnosticExportResult {
  const DiagnosticExportResult({
    required this.path,
    required this.eventCount,
    required this.attachmentCount,
  });

  final String path;
  final int eventCount;
  final int attachmentCount;
}
