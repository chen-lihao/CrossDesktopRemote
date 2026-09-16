import 'package:webrtc_interface/webrtc_interface.dart';

import 'media_stream_impl.dart';
import 'utils.dart';

/// Desktop system-output capture backed by a session-scoped native loopback
/// source. It is intentionally separate from getDisplayMedia so replacing a
/// display video track cannot interrupt audio.
class SystemAudioCapture {
  const SystemAudioCapture._();

  static Future<Map<String, dynamic>> backendInfo() async {
    final response = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
      'getSystemAudioBackendInfo',
    );
    return response?.map((key, value) => MapEntry(key.toString(), value)) ??
        const <String, dynamic>{};
  }

  static Future<MediaStream> start() async {
    final response = await WebRTC.invokeMethod<Map<dynamic, dynamic>, dynamic>(
      'getSystemAudio',
    );
    if (response == null) {
      throw StateError('getSystemAudio returned no media stream');
    }
    return MediaStreamNative(response['streamId'] as String, 'local')
      ..setMediaTracks(
        response['audioTracks'] as List<dynamic>? ?? const [],
        response['videoTracks'] as List<dynamic>? ?? const [],
      );
  }

  static Future<void> stop() =>
      WebRTC.invokeMethod<void, dynamic>('stopSystemAudio');
}
