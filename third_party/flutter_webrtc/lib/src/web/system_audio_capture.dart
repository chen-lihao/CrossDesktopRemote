import 'package:webrtc_interface/webrtc_interface.dart';

class SystemAudioCapture {
  const SystemAudioCapture._();

  static Future<Map<String, dynamic>> backendInfo() async =>
      const <String, dynamic>{
        'backend': 'unsupported',
        'version': 0,
        'microphoneFree': false,
      };

  static Future<MediaStream> start() =>
      throw UnsupportedError('System audio capture is not available on web');

  static Future<void> stop() async {}
}
