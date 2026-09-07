import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
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
  }) : renderer = (rendererFactory ?? RTCVideoRenderer.new)() {
    _observedRefreshGeneration = session.presentationRefreshGeneration;
    session.addListener(_handleSessionChanged);
    renderer.onFirstFrameRendered = _handleFirstFrame;
    renderer.onResize = _handleResize;
    renderer.onColorDiagnostics = session.updateRendererColorDiagnostics;
  }

  final RemoteSessionController session;
  final RTCVideoRenderer renderer;

  RemotePresentationState _state = RemotePresentationState.detached;
  Object? _error;
  bool _surfaceAttached = false;
  bool _visibleRequested = false;
  bool _firstFrameReceived = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  int _boundTrackGeneration = -1;
  int _observedRefreshGeneration = -1;
  Future<void>? _attachFuture;
  Future<void>? _serialOperation;

  RemotePresentationState get state => _state;
  Object? get error => _error;
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
      await WidgetsBinding.instance.endOfFrame;
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
        await renderer.setSrcObject(stream: null);
      }
      _boundTrackGeneration = -1;
      _firstFrameReceived = false;
    });
    if (!_disposed && !_surfaceAttached && lifecycle == _lifecycleGeneration) {
      _setState(RemotePresentationState.detached);
    }
  }

  void _handleSessionChanged() {
    if (_disposed || !_surfaceAttached) return;
    final stream = session.remoteStream;
    if (stream == null) {
      unawaited(_scheduleUnbind());
      return;
    }
    final refreshChanged =
        _observedRefreshGeneration != session.presentationRefreshGeneration;
    if (_boundTrackGeneration != session.remoteTrackGeneration ||
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
    final stream = session.remoteStream;
    final trackGeneration = session.remoteTrackGeneration;
    final refreshGeneration = session.presentationRefreshGeneration;
    if (stream == null) {
      await _unbindRenderer();
      return;
    }
    if (!force &&
        renderer.srcObject == stream &&
        _boundTrackGeneration == trackGeneration) {
      return;
    }

    final lifecycle = _lifecycleGeneration;
    _firstFrameReceived = false;
    _error = null;
    _setState(RemotePresentationState.binding);
    await WidgetsBinding.instance.endOfFrame;
    if (!_isCurrent(lifecycle) || session.remoteStream != stream) return;

    if (force && renderer.srcObject != null) {
      await renderer.setSrcObject(stream: null);
      await Future<void>.delayed(Duration.zero);
      if (!_isCurrent(lifecycle) || session.remoteStream != stream) return;
    }
    await renderer.setSrcObject(stream: stream);
    if (!_isCurrent(lifecycle) || session.remoteStream != stream) {
      await renderer.setSrcObject(stream: null);
      return;
    }
    _boundTrackGeneration = trackGeneration;
    _observedRefreshGeneration = refreshGeneration;
    _setState(RemotePresentationState.waitingFirstFrame);
    _evaluateReady();
  }

  Future<void> _scheduleUnbind() {
    return _enqueue(_unbindRenderer);
  }

  Future<void> _unbindRenderer() async {
    if (renderer.srcObject != null) {
      await renderer.setSrcObject(stream: null);
    }
    _boundTrackGeneration = -1;
    _firstFrameReceived = false;
    if (_surfaceAttached && !_disposed) {
      _setState(RemotePresentationState.surfaceReady);
    }
  }

  void _handleFirstFrame() {
    if (_disposed || !_surfaceAttached) return;
    _firstFrameReceived = true;
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
        _boundTrackGeneration != session.remoteTrackGeneration) {
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
    session.removeListener(_handleSessionChanged);
    try {
      await _enqueue(() async {
        if (renderer.srcObject != null) {
          await renderer.setSrcObject(stream: null);
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
