import 'package:webrtc_interface/webrtc_interface.dart';

class SystemAudioCapture {
  const SystemAudioCapture._();

  static Future<MediaStream> start() =>
      throw UnsupportedError('System audio capture is not available on web');

  static Future<void> stop() async {}
}
