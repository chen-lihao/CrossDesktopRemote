import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum RemotePresentationState {
  detached,
  attaching,
  surfaceReady,
  binding,
  waitingFirstFrame,
  ready,
  visible,
  hidden,
  detaching,
  failed,
}

typedef RemoteVideoRendererFactory = RTCVideoRenderer Function();
typedef RemotePresentationFrameBarrier = Future<void> Function();

Future<void> _waitForPresentationFrame() {
  return WidgetsBinding.instance.endOfFrame;
}

/// Owns the platform video texture for one presentation surface.
///
/// The WebRTC session owns the remote media stream. This controller binds that
/// stream only after a Flutter Texture has been mounted for one frame, and it
/// does not declare the presentation ready until the renderer reports a valid
/// first frame. Window visibility therefore never owns the network session.
class RemotePresentationController extends ChangeNotifier {
  RemotePresentationController({
    required this.session,
    RemoteVideoRendererFactory? rendererFactory,
    RemotePresentationFrameBarrier? frameBarrier,
    this.firstFrameTimeout = const Duration(seconds: 3),
  }) : renderer = (rendererFactory ?? RTCVideoRenderer.new)(),
       _frameBarrier = frameBarrier ?? _waitForPresentationFrame {
    _observedRefreshGeneration = session.presentationRefreshGeneration;
    session.addListener(_handleSessionChanged);
    renderer.onFirstFrameRendered = _handleFirstFrame;
    renderer.onResize = _handleResize;
    renderer.onColorDiagnostics = session.updateRendererColorDiagnostics;
  }

  final RemoteVideoPresentationSource session;
  final RTCVideoRenderer renderer;
  final Duration firstFrameTimeout;
  final RemotePresentationFrameBarrier _frameBarrier;

  RemotePresentationState _state = RemotePresentationState.detached;
  Object? _error;
  bool _surfaceAttached = false;
  bool _visibleRequested = false;
  bool _firstFrameReceived = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  int _boundTrackGeneration = -1;
  String? _boundTrackId;
  int _observedRefreshGeneration = -1;
  Future<void>? _attachFuture;
  Future<void>? _serialOperation;
  Timer? _firstFrameTimer;

  RemotePresentationState get state => _state;
  Object? get error => _error;
  String? get boundTrackId => _boundTrackId;
  bool get isReady => {
    RemotePresentationState.ready,
    RemotePresentationState.visible,
    RemotePresentationState.hidden,
  }.contains(_state);
  bool get isVisible => _state == RemotePresentationState.visible;

  Future<void> attachSurface() {
    final existing = _attachFuture;
    if (existing != null) return existing;
    final completion = _attachSurface();
    _attachFuture = completion;
    return completion;
  }

  Future<void> _attachSurface() async {
    if (_disposed || _surfaceAttached) return;
    _surfaceAttached = true;
    final lifecycle = ++_lifecycleGeneration;
    _setState(RemotePresentationState.attaching);
    try {
      if (renderer.textureId == null) await renderer.initialize();
      if (!_isCurrent(lifecycle)) return;
      _setState(RemotePresentationState.surfaceReady);

      // The Texture widget is rebuilt with a valid texture id by the state
      // notification above. Bind media only after that element has completed a
      // Flutter frame, so the first native pixel-buffer pull has a live owner.
      await _frameBarrier();
      if (!_isCurrent(lifecycle)) return;
      await _scheduleBinding(force: false);
    } catch (error) {
      if (_isCurrent(lifecycle)) {
        _attachFuture = null;
        _error = error;
        _setState(RemotePresentationState.failed);
      }
    }
  }

  void setVisible(bool value) {
    if (_disposed || _visibleRequested == value) return;
    _visibleRequested = value;
    if (!isReady) {
      notifyListeners();
      return;
    }
    _setState(
      value ? RemotePresentationState.visible : RemotePresentationState.hidden,
    );
  }

  /// Revalidates the current stream-to-texture binding without tearing down a
  /// healthy renderer. This is safe to expose as a user retry action because
  /// it never owns or recreates the PeerConnection or remote track.
  Future<void> retryBinding() async {
    if (_disposed) return;
    if (!_surfaceAttached) {
      await attachSurface();
      return;
    }
    _error = null;
    await _scheduleBinding(force: true);
  }

  Future<void> detachSurface() async {
    if (_disposed || !_surfaceAttached) return;
    _surfaceAttached = false;
    _attachFuture = null;
    _visibleRequested = false;
    final lifecycle = ++_lifecycleGeneration;
    _setState(RemotePresentationState.detaching);
    await _enqueue(() async {
      if (_surfaceAttached || lifecycle != _lifecycleGeneration) return;
      if (renderer.srcObject != null) {
        await renderer.setSrcObject(stream: null, trackId: null);
      }
      _boundTrackGeneration = -1;
      _boundTrackId = null;
      _firstFrameReceived = false;
      _firstFrameTimer?.cancel();
    });
    if (!_disposed && !_surfaceAttached && lifecycle == _lifecycleGeneration) {
      _setState(RemotePresentationState.detached);
    }
  }

  void _handleSessionChanged() {
    if (_disposed || !_surfaceAttached) return;
    final binding = session.remoteVideoBinding;
    if (binding == null) {
      unawaited(_scheduleUnbind());
      return;
    }
    final refreshChanged =
        _observedRefreshGeneration != session.presentationRefreshGeneration;
    if (_boundTrackGeneration != binding.generation ||
        _boundTrackId != binding.trackId ||
        refreshChanged) {
      unawaited(
        _scheduleBinding(force: refreshChanged && _boundTrackGeneration >= 0),
      );
    }
  }

  Future<void> _scheduleBinding({required bool force}) {
    return _enqueue(() => _bindCurrentStream(force: force));
  }

  Future<void> _bindCurrentStream({required bool force}) async {
    if (_disposed || !_surfaceAttached || renderer.textureId == null) return;
    final binding = session.remoteVideoBinding;
    final refreshGeneration = session.presentationRefreshGeneration;
    if (binding == null || !binding.isValid) {
      await _unbindRenderer();
      return;
    }
    final stream = binding.stream;
    final trackGeneration = binding.generation;
    final trackId = binding.trackId;
    if (!force &&
        renderer.srcObject == stream &&
        _boundTrackGeneration == trackGeneration &&
        _boundTrackId == trackId) {
      return;
    }

    final lifecycle = _lifecycleGeneration;
    final alreadyPresenting =
        isReady &&
        renderer.srcObject == stream &&
        _boundTrackGeneration == trackGeneration &&
        _boundTrackId == trackId &&
        renderer.value.width > 0 &&
        renderer.value.height > 0;
    if (!alreadyPresenting) {
      _firstFrameReceived = false;
      _firstFrameTimer?.cancel();
      _setState(RemotePresentationState.binding);
    }
    _error = null;
    await _frameBarrier();
    if (!_isCurrent(lifecycle) || session.remoteVideoBinding != binding) {
      return;
    }
    // Bind the exact receiver track. A stream-only/default-track contract is
    // ambiguous across native WebRTC implementations and previously allowed
    // Windows to acknowledge a request without attaching any video sink.
    await renderer.setSrcObject(stream: stream, trackId: trackId);
    if (!_isCurrent(lifecycle) || session.remoteVideoBinding != binding) return;
    _boundTrackGeneration = trackGeneration;
    _boundTrackId = trackId;
    _observedRefreshGeneration = refreshGeneration;
    if (alreadyPresenting) {
      _setState(
        _visibleRequested
            ? RemotePresentationState.visible
            : RemotePresentationState.ready,
      );
      return;
    }
    _setState(RemotePresentationState.waitingFirstFrame);
    _armFirstFrameTimeout(
      lifecycle: lifecycle,
      trackGeneration: trackGeneration,
      trackId: trackId,
    );
    _evaluateReady();
  }

  void _armFirstFrameTimeout({
    required int lifecycle,
    required int trackGeneration,
    required String trackId,
  }) {
    _firstFrameTimer?.cancel();
    _firstFrameTimer = Timer(firstFrameTimeout, () {
      if (!_isCurrent(lifecycle) ||
          _firstFrameReceived ||
          _boundTrackGeneration != trackGeneration ||
          _boundTrackId != trackId) {
        return;
      }
      _error = StateError('视频轨道已绑定，但在规定时间内未收到可显示首帧');
      _setState(RemotePresentationState.failed);
    });
  }

  Future<void> _scheduleUnbind() {
    return _enqueue(_unbindRenderer);
  }

  Future<void> _unbindRenderer() async {
    if (renderer.srcObject != null) {
      await renderer.setSrcObject(stream: null, trackId: null);
    }
    _boundTrackGeneration = -1;
    _boundTrackId = null;
    _firstFrameReceived = false;
    _firstFrameTimer?.cancel();
    if (_surfaceAttached && !_disposed) {
      _setState(RemotePresentationState.surfaceReady);
    }
  }

  void _handleFirstFrame() {
    if (_disposed || !_surfaceAttached) return;
    _firstFrameReceived = true;
    _firstFrameTimer?.cancel();
    _evaluateReady();
  }

  void _handleResize() {
    if (_disposed || !_surfaceAttached) return;
    final value = renderer.value;
    final width = value.width.round();
    final height = value.height.round();
    if (width > 0 && height > 0 && _boundTrackGeneration >= 0) {
      session.reportPresentedVideoFrame(
        trackGeneration: _boundTrackGeneration,
        width: width,
        height: height,
      );
    }
    _evaluateReady();
  }

  void _evaluateReady() {
    if (!_firstFrameReceived ||
        _boundTrackGeneration != session.remoteVideoBinding?.generation ||
        _boundTrackId != session.remoteVideoBinding?.trackId) {
      return;
    }
    final value = renderer.value;
    if (value.width <= 0 || value.height <= 0) return;
    session.reportPresentedVideoFrame(
      trackGeneration: _boundTrackGeneration,
      width: value.width.round(),
      height: value.height.round(),
    );
    _setState(
      _visibleRequested
          ? RemotePresentationState.visible
          : RemotePresentationState.ready,
    );
    _firstFrameTimer?.cancel();
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final previous = _serialOperation;
    final next = () async {
      if (previous != null) await previous;
      try {
        await operation();
      } catch (error) {
        if (!_disposed) {
          _error = error;
          _setState(RemotePresentationState.failed);
        }
      }
    }();
    _serialOperation = next;
    return next;
  }

  bool _isCurrent(int lifecycle) =>
      !_disposed && _surfaceAttached && lifecycle == _lifecycleGeneration;

  void _setState(RemotePresentationState value) {
    if (_disposed || _state == value) return;
    _state = value;
    notifyListeners();
  }

  Future<void> shutdown() async {
    if (_disposed) return;
    _surfaceAttached = false;
    ++_lifecycleGeneration;
    _firstFrameTimer?.cancel();
    session.removeListener(_handleSessionChanged);
    try {
      await _enqueue(() async {
        if (renderer.srcObject != null) {
          await renderer.setSrcObject(stream: null, trackId: null);
        }
        renderer.onFirstFrameRendered = null;
        renderer.onResize = null;
        renderer.onColorDiagnostics = null;
        await renderer.dispose();
      });
    } finally {
      _disposed = true;
      super.dispose();
    }
  }
}
