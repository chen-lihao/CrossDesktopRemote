import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_server_profile.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('normalizes custom secure signaling server', () {
    final profile = SignalingServerProfile.forUrl(
      ' wss://signal.example.com/ws/signaling ',
    );

    expect(profile.kind, SignalingServerProfileKind.custom);
    expect(profile.secure, isTrue);
    expect(profile.url, 'wss://signal.example.com/ws/signaling');
  });

  test('probe performs a websocket handshake without a user invitation', () {
    final uri = buildSignalingProbeUri(
      'wss://signal.example.com/ws/signaling?tenant=cdr',
    );

    expect(uri.queryParameters['tenant'], 'cdr');
    expect(uri.queryParameters['role'], 'host');
    expect(uri.queryParameters.containsKey('room'), isFalse);
    expect(uri.queryParameters['probe'], 'true');
  });

  test('rejects non websocket endpoints', () {
    expect(
      () => normalizeSignalingServerUrl('https://example.com/signaling'),
      throwsFormatException,
    );
  });
}
