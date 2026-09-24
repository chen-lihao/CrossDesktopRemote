import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cross_desktop_remote/core/diagnostics/diagnostic_event.dart';
import 'package:cross_desktop_remote/core/diagnostics/diagnostic_hub.dart';

typedef SignalingMessageHandler = FutureOr<void> Function(
  Map<String, dynamic> message,
);
typedef SignalingClosedHandler = void Function(int? code, String? reason);

class SignalingClient {
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;
  Future<void> _messageQueue = Future<void>.value();
  int _connectionGeneration = 0;
  DiagnosticContext _diagnosticContext = const DiagnosticContext();

  bool get isConnected => _socket?.readyState == WebSocket.open;

  Future<void> connect({
    required Uri uri,
    required SignalingMessageHandler onMessage,
    required SignalingClosedHandler onDone,
  }) async {
    await close();
    final generation = ++_connectionGeneration;
    final context = DiagnosticContext(
      traceId: uri.queryParameters['traceId'],
      attemptId: uri.queryParameters['attemptId'],
      role: uri.queryParameters['role'],
    );
    _diagnosticContext = context;
    DiagnosticHub.instance.record(
      component: 'signaling.websocket',
      name: 'connect_started',
      context: context,
      attributes: {
        'scheme': uri.scheme,
        'host': uri.host,
        'port': uri.hasPort ? uri.port : null,
        'path': uri.path,
        'generation': generation,
      },
    );
    late final WebSocket socket;
    try {
      socket = await WebSocket.connect(uri.toString());
    } catch (error, stackTrace) {
      DiagnosticHub.instance.recordError(
        component: 'signaling.websocket',
        name: 'connect_failed',
        error: error,
        stackTrace: stackTrace,
        errorCode: 'CDR-SIGNAL-001',
        context: context,
      );
      rethrow;
    }
    socket.pingInterval = const Duration(seconds: 15);
    _socket = socket;
    DiagnosticHub.instance.record(
      component: 'signaling.websocket',
      name: 'connected',
      context: context,
      attributes: {'generation': generation},
    );
    var terminalDelivered = false;
    void deliverTerminal([Object? error, StackTrace? stackTrace]) {
      if (terminalDelivered || generation != _connectionGeneration) return;
      terminalDelivered = true;
      if (error != null) {
        DiagnosticHub.instance.recordError(
          component: 'signaling.websocket',
          name: 'transport_error',
          error: error,
          stackTrace: stackTrace ?? StackTrace.current,
          errorCode: 'CDR-SIGNAL-002',
          context: context,
        );
      }
      DiagnosticHub.instance.record(
        component: 'signaling.websocket',
        name: 'closed',
        severity: socket.closeCode == WebSocketStatus.normalClosure
            ? DiagnosticSeverity.info
            : DiagnosticSeverity.warning,
        context: context,
        attributes: {
          'closeCode': socket.closeCode,
          'closeReason': socket.closeReason,
          'generation': generation,
        },
      );
      onDone(socket.closeCode, socket.closeReason);
    }

    _subscription = socket.listen(
      (dynamic payload) {
        _messageQueue = _messageQueue
            .then((_) async {
              if (generation != _connectionGeneration || payload is! String) {
                return;
              }
              final decoded = jsonDecode(payload);
              if (decoded is Map<String, dynamic>) {
                DiagnosticHub.instance.record(
                  component: 'signaling.message',
                  name: 'received',
                  severity: DiagnosticSeverity.debug,
                  context: context,
                  attributes: {
                    'type': decoded['type'] as String? ?? 'unknown',
                    'payloadBytes': utf8.encode(payload).length,
                  },
                );
                await onMessage(decoded);
              }
            })
            .catchError((Object error, StackTrace stackTrace) async {
              DiagnosticHub.instance.recordError(
                component: 'signaling.message',
                name: 'decode_or_dispatch_failed',
                error: error,
                stackTrace: stackTrace,
                errorCode: 'CDR-SIGNAL-003',
                context: context,
              );
              if (generation == _connectionGeneration &&
                  socket.readyState == WebSocket.open) {
                await socket.close(WebSocketStatus.invalidFramePayloadData);
              }
            });
      },
      onDone: deliverTerminal,
      onError: deliverTerminal,
      cancelOnError: true,
    );
  }

  void send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('信令连接尚未建立');
    }
    final payload = jsonEncode(message);
    DiagnosticHub.instance.record(
      component: 'signaling.message',
      name: 'sent',
      severity: DiagnosticSeverity.debug,
      context: _diagnosticContext,
      attributes: {
        'type': message['type'] as String? ?? 'unknown',
        'payloadBytes': utf8.encode(payload).length,
      },
    );
    socket.add(payload);
  }

  Future<void> close() async {
    _connectionGeneration += 1;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    final socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure);
  }
}
