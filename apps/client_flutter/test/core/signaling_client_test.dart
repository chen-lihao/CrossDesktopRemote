import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cross_desktop_remote/core/signaling/signaling_client.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_message_limits.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('complete envelope budget counts UTF-8 bytes, not characters', () {
    expect(SignalingMessageLimits.validate('a' * 65536), 65536);
    expect(SignalingMessageLimits.validate('界' * 21845), 65535);
    expect(
      () => SignalingMessageLimits.validate('a' * 65537),
      throwsA(isA<SignalingMessageTooLarge>()),
    );
    expect(
      () => SignalingMessageLimits.validate('界' * 21846),
      throwsA(isA<SignalingMessageTooLarge>()),
    );
  });

  group('real WebSocket transport', () {
    late HttpServer server;
    late SignalingClient client;
    late WebSocket peer;
    late StreamIterator<dynamic> messages;
    late StreamController<Map<String, dynamic>> received;
    late Completer<int?> closed;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final accepted = Completer<WebSocket>();
      server.listen((request) async {
        accepted.complete(await WebSocketTransformer.upgrade(request));
      });
      client = SignalingClient();
      received = StreamController<Map<String, dynamic>>();
      closed = Completer<int?>();
      await client.connect(
        uri: Uri.parse('ws://127.0.0.1:${server.port}/ws/signaling'),
        onMessage: received.add,
        onDone: (code, _) {
          if (!closed.isCompleted) closed.complete(code);
        },
      );
      peer = await accepted.future;
      final peerMessages = StreamController<dynamic>();
      peer.listen(peerMessages.add, onDone: peerMessages.close);
      messages = StreamIterator(peerMessages.stream);
    });

    tearDown(() async {
      // Start both closes before awaiting either side of the handshake.
      final clientClose = client.close();
      final peerClose = peer.close();
      await Future.wait([clientClose, peerClose]);
      await messages.cancel();
      unawaited(received.close());
      await server.close(force: true);
    });

    test(
      'relays the 8356-byte regression and exact-limit signed envelope',
      () async {
        final incoming = StreamIterator(received.stream);
        addTearDown(incoming.cancel);
        for (final size in [8356, SignalingMessageLimits.maxTextBytes]) {
          final message = _messageWithBytes(size);
          final encoded = jsonEncode(message);
          client.send(message);
          expect(await messages.moveNext(), isTrue);
          expect(messages.current, encoded);
          peer.add(encoded);
          expect(await incoming.moveNext(), isTrue);
          expect(incoming.current, message);
        }
      },
    );

    test(
      'rejects oversized outbound data without sending or truncating it',
      () async {
        expect(
          () => client.send(_messageWithBytes(65537)),
          throwsA(isA<SignalingMessageTooLarge>()),
        );
        expect(
          () => client.send({'type': 'trusted-offer', 'sdp': '界' * 23000}),
          throwsA(isA<SignalingMessageTooLarge>()),
        );
        client.send({'type': 'candidate'});
        expect(await messages.moveNext(), isTrue);
        expect(messages.current, '{"type":"candidate"}');
      },
    );

    test(
      'rejects oversized inbound UTF-8 before decoding or dispatching',
      () async {
        final delivered = <Map<String, dynamic>>[];
        final subscription = received.stream.listen(delivered.add);
        addTearDown(subscription.cancel);
        final peerClosed = messages.moveNext();
        peer.add(jsonEncode({'type': 'trusted-answer', 'sdp': '界' * 23000}));
        expect(await peerClosed.timeout(const Duration(seconds: 5)), isFalse);
        expect(await closed.future.timeout(const Duration(seconds: 5)), 1009);
        expect(peer.closeCode, 1009);
        expect(delivered, isEmpty);
      },
    );

    test(
      'preserves the old server 1009 close code for actionable UI',
      () async {
        final peerClosed = messages.moveNext();
        unawaited(peer.close(1009, 'container limit'));
        expect(await closed.future.timeout(const Duration(seconds: 5)), 1009);
        await peerClosed;
      },
    );
  });
}

Map<String, dynamic> _messageWithBytes(int size) {
  const empty = {'type': 'trusted-offer', 'sdp': ''};
  return {
    'type': 'trusted-offer',
    'sdp': 'a' * (size - jsonEncode(empty).length),
  };
}
