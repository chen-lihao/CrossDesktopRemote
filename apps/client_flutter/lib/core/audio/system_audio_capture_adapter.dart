import 'dart:io';

import 'package:flutter_webrtc/flutter_webrtc.dart';

enum SystemAudioCaptureBackend {
  windowsLoopback,
  appleExternalAdm,
  unsupported,
}

/// Static platform routing. macOS performs an additional native runtime
/// handshake before capture starts, so a stale or incompatible plugin cannot
/// fall back to microphone input.
SystemAudioCaptureBackend systemAudioCaptureBackendFor(String operatingSystem) {
  return switch (operatingSystem.trim().toLowerCase()) {
    'windows' => SystemAudioCaptureBackend.windowsLoopback,
    'macos' => SystemAudioCaptureBackend.appleExternalAdm,
    _ => SystemAudioCaptureBackend.unsupported,
  };
}

bool isCompatibleAppleSystemAudioBackendInfo(Map<String, dynamic> info) {
  final version = info['version'];
  return info['backend'] == 'screen-capture-kit-external-adm' &&
      version is num &&
      version >= 5 &&
      info['microphoneFree'] == true &&
      info['captureOwner'] == 'unified-screen-stream' &&
      info['startupContract'] == 'capture-ready-before-media-result' &&
      info['deliveryMode'] == 'capture-clock-render-block' &&
      info['frameDurationMs'] == 10;
}

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

  SystemAudioCaptureBackend get backend =>
      systemAudioCaptureBackendFor(Platform.operatingSystem);

  @override
  bool get supported => backend != SystemAudioCaptureBackend.unsupported;

  @override
  Future<MediaStream> start() async {
    if (!supported) {
      throw UnsupportedError('当前平台尚未实现系统声音采集');
    }
    if (Platform.isMacOS) {
      final info = await SystemAudioCapture.backendInfo();
      if (!isCompatibleAppleSystemAudioBackendInfo(info)) {
        throw UnsupportedError('macOS 外部系统音频后端未就绪');
      }
    }
    return SystemAudioCapture.start();
  }

  @override
  Future<void> stop() =>
      supported ? SystemAudioCapture.stop() : Future<void>.value();
}

SystemAudioCaptureAdapter createSystemAudioCaptureAdapter() =>
    const FlutterWebRtcSystemAudioCaptureAdapter();
