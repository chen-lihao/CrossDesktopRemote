import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef SignalingMessageHandler = FutureOr<void> Function(
  Map<String, dynamic> message,
);
typedef SignalingClosedHandler = void Function(int? code, String? reason);

class SignalingClient {
  WebSocket? _socket;
  StreamSubscription<dynamic>? _subscription;

  bool get isConnected => _socket?.readyState == WebSocket.open;

  Future<void> connect({
    required Uri uri,
    required SignalingMessageHandler onMessage,
    required SignalingClosedHandler onDone,
  }) async {
    await close();
    final socket = await WebSocket.connect(uri.toString());
    socket.pingInterval = const Duration(seconds: 15);
    _socket = socket;
    _subscription = socket.listen(
      (dynamic payload) async {
        if (payload is! String) {
          return;
        }
        final decoded = jsonDecode(payload);
        if (decoded is Map<String, dynamic>) {
          await onMessage(decoded);
        }
      },
      onDone: () => onDone(socket.closeCode, socket.closeReason),
      onError: (_) => onDone(socket.closeCode, socket.closeReason),
      cancelOnError: true,
    );
  }

  void send(Map<String, dynamic> message) {
    final socket = _socket;
    if (socket == null || socket.readyState != WebSocket.open) {
      throw StateError('信令连接尚未建立');
    }
    socket.add(jsonEncode(message));
  }

  Future<void> close() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();

    final socket = _socket;
    _socket = null;
    await socket?.close(WebSocketStatus.normalClosure);
  }
}
