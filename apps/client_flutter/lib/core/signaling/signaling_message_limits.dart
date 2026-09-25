import 'dart:convert';

/// Budget for the complete JSON envelope, not the SDP or each WebSocket frame.
/// Keep in sync with Java SignalingMessageLimits. Signed content is never
/// truncated, recompressed or replaced by an unsigned offer to fit this limit.
abstract final class SignalingMessageLimits {
  static const maxTextBytes = 64 * 1024;
  static const closeReason = 'SIGNALING_MESSAGE_TOO_LARGE';
  static const userMessage = '信令消息超出接收限制，请更新并重启信令服务器及两端软件';

  static int validate(String payload) {
    final bytes = utf8.encode(payload).length;
    if (bytes > maxTextBytes) throw SignalingMessageTooLarge(bytes);
    return bytes;
  }
}

class SignalingMessageTooLarge implements Exception {
  const SignalingMessageTooLarge(this.payloadBytes);
  final int payloadBytes;

  @override
  String toString() =>
      '${SignalingMessageLimits.userMessage} '
      '($payloadBytes/${SignalingMessageLimits.maxTextBytes} bytes)';
}
