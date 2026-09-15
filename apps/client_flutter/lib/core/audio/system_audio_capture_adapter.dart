import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

enum RemoteSystemAudioState {
  unsupported,
  disabled,
  requesting,
  capturing,
  sending,
  receiving,
  suspended,
  recovering,
  failed,
}

abstract interface class SystemAudioCaptureAdapter {
  bool get supported;

  Future<MediaStream> start();

  Future<void> stop();
}

class FlutterWebRtcSystemAudioCaptureAdapter
    implements SystemAudioCaptureAdapter {
  const FlutterWebRtcSystemAudioCaptureAdapter();

  @override
  bool get supported => Platform.isWindows || Platform.isMacOS;

  @override
  Future<MediaStream> start() {
    if (!supported) {
      throw UnsupportedError('当前平台尚未实现系统声音采集');
    }
    return SystemAudioCapture.start();
  }

  @override
  Future<void> stop() =>
      supported ? SystemAudioCapture.stop() : Future<void>.value();
}

SystemAudioCaptureAdapter createSystemAudioCaptureAdapter() =>
    const FlutterWebRtcSystemAudioCaptureAdapter();
