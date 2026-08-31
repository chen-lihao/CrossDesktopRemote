import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';

enum SignalingServerProfileKind { localDevelopment, custom }

class SignalingServerProfile {
  const SignalingServerProfile({
    required this.id,
    required this.name,
    required this.url,
    required this.kind,
  });

  static const localDevelopment = SignalingServerProfile(
    id: 'local-development',
    name: '本机开发服务',
    url: 'ws://127.0.0.1:8080/ws/signaling',
    kind: SignalingServerProfileKind.localDevelopment,
  );

  factory SignalingServerProfile.forUrl(String value) {
    final normalized = normalizeSignalingServerUrl(value);
    if (normalized == localDevelopment.url) return localDevelopment;
    return SignalingServerProfile(
      id: 'custom',
      name: '自定义服务器',
      url: normalized,
      kind: SignalingServerProfileKind.custom,
    );
  }

  final String id;
  final String name;
  final String url;
  final SignalingServerProfileKind kind;

  bool get secure => Uri.parse(url).scheme == 'wss';
}
