import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';

class RemoteVideoGeometryGate {
  RemoteVideoGeometryGate({
    required this.target,
    this.requiredStableSamples = 2,
  });

  final RemoteVideoFrameSize target;
  final int requiredStableSamples;

  int _stableSamples = 0;
  int? _lastFrames;
  RemoteVideoFrameSize? _lastSize;

  bool observe({
    required RemoteVideoFrameSize? size,
    required int? frames,
    required bool mediaAdvanced,
    required bool keyFrameAdvanced,
  }) {
    final geometryReady = size?.hasSameAspectRatio(target) == true;
    final newFrameSample = frames != null && frames != _lastFrames;
    if (!mediaAdvanced ||
        !keyFrameAdvanced ||
        !geometryReady ||
        !newFrameSample) {
      if (!geometryReady) _stableSamples = 0;
      return false;
    }
    final sameSize =
        _lastSize != null &&
        _lastSize!.width == size!.width &&
        _lastSize!.height == size.height;
    _stableSamples = sameSize ? _stableSamples + 1 : 1;
    _lastFrames = frames;
    _lastSize = size;
    return _stableSamples >= requiredStableSamples;
  }
}
