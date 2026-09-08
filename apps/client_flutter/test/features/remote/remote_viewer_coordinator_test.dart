import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/in_app_remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_presentation_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_coordinator.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  testWidgets('primary viewer close preserves its presentation owner', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final session = RemoteSessionController(role: RemoteRole.controller);
    final settings = AppSettingsController();
    final presentation = RemotePresentationController(session: session);
    final host = InAppRemoteViewerHost();
    final request = RemoteViewerRequest(
      context: context,
      session: session,
      presentation: presentation,
      settings: settings,
    );
    addTearDown(() async {
      host.clear();
      await presentation.shutdown();
      session.dispose();
      settings.dispose();
    });

    await host.open(request);
    expect(host.visible, isTrue);
    expect(host.request, same(request));

    host.close();
    expect(host.visible, isFalse);
    expect(host.request, same(request));

    await host.open(request);
    expect(host.visible, isTrue);
    expect(host.request, same(request));
  });

  testWidgets('prewarmed primary viewer stays mounted while hidden', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(430, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    late BuildContext requestContext;
    final session = RemoteSessionController(role: RemoteRole.controller);
    final settings = AppSettingsController();
    final renderer = _FakeVideoRenderer();
    final presentation = RemotePresentationController(
      session: session,
      rendererFactory: () => renderer,
    );
    final host = InAppRemoteViewerHost();

    await tester.pumpWidget(
      MaterialApp(
        home: InAppRemoteViewerPortal(
          host: host,
          session: session,
          presentation: presentation,
          settings: settings,
          prewarm: true,
          child: Builder(
            builder: (context) {
              requestContext = context;
              return const Text('home');
            },
          ),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('persistent-primary-remote-viewer')),
      findsOneWidget,
    );
    expect(find.byTooltip('更多操作'), findsNothing);
    expect(renderer.initializeCount, 1);

    final request = RemoteViewerRequest(
      context: requestContext,
      session: session,
      presentation: presentation,
      settings: settings,
    );
    await host.open(request);
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('更多操作'), findsOneWidget);
    for (final width in <double>[320, 430, 600, 800, 1280]) {
      tester.view.physicalSize = Size(width, 844);
      await tester.pump();
      expect(
        tester.takeException(),
        isNull,
        reason: 'remote viewer must fit a $width px wide viewport',
      );
    }
    host.close();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.byTooltip('更多操作'), findsNothing);

    expect(
      find.byKey(const ValueKey('persistent-primary-remote-viewer')),
      findsOneWidget,
    );
    expect(renderer.initializeCount, 1);

    await tester.pumpWidget(const SizedBox());
    await presentation.shutdown();
    session.dispose();
    settings.dispose();
  });

  test('presentation binds the exact receiver track before ready', () async {
    final source = _FakeVideoPresentationSource();
    final renderer = _FakeVideoRenderer(emitFirstFrame: true);
    final presentation = RemotePresentationController(
      session: source,
      rendererFactory: () => renderer,
      frameBarrier: () async {},
    );
    addTearDown(() async {
      await presentation.shutdown();
      source.dispose();
    });

    await presentation.attachSurface();
    source.publish(
      RemoteVideoBinding(
        stream: _FakeMediaStream('remote-stream'),
        trackId: 'receiver-video-track',
        generation: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(renderer.boundTrackIds, ['receiver-video-track']);
    expect(presentation.boundTrackId, 'receiver-video-track');
    expect(presentation.isReady, isTrue);
    expect(source.presentedFrames, [(1920, 1080, 1)]);
  });

  test('native bind failure is visible instead of waiting forever', () async {
    final source = _FakeVideoPresentationSource();
    final renderer = _FakeVideoRenderer(bindError: StateError('track missing'));
    final presentation = RemotePresentationController(
      session: source,
      rendererFactory: () => renderer,
      frameBarrier: () async {},
    );
    addTearDown(() async {
      await presentation.shutdown();
      source.dispose();
    });

    await presentation.attachSurface();
    source.publish(
      RemoteVideoBinding(
        stream: _FakeMediaStream('remote-stream'),
        trackId: 'missing-track',
        generation: 1,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(presentation.state, RemotePresentationState.failed);
    expect(presentation.error, isA<StateError>());
  });

  test(
    'presentation repair validates without unbinding healthy video',
    () async {
      final source = _FakeVideoPresentationSource();
      final renderer = _FakeVideoRenderer(emitFirstFrame: true);
      final presentation = RemotePresentationController(
        session: source,
        rendererFactory: () => renderer,
        frameBarrier: () async {},
      );
      addTearDown(() async {
        await presentation.shutdown();
        source.dispose();
      });

      await presentation.attachSurface();
      source.publish(
        RemoteVideoBinding(
          stream: _FakeMediaStream('remote-stream'),
          trackId: 'receiver-video-track',
          generation: 1,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      source.requestPresentationRefresh();
      await Future<void>.delayed(Duration.zero);

      expect(renderer.boundTrackIds, [
        'receiver-video-track',
        'receiver-video-track',
      ]);
      expect(renderer.unbindCount, 0);
      expect(presentation.isReady, isTrue);
    },
  );

  test('missing first frame fails with a bounded diagnostic', () async {
    final source = _FakeVideoPresentationSource();
    final renderer = _FakeVideoRenderer();
    final presentation = RemotePresentationController(
      session: source,
      rendererFactory: () => renderer,
      frameBarrier: () async {},
      firstFrameTimeout: const Duration(milliseconds: 10),
    );
    addTearDown(() async {
      await presentation.shutdown();
      source.dispose();
    });

    await presentation.attachSurface();
    source.publish(
      RemoteVideoBinding(
        stream: _FakeMediaStream('remote-stream'),
        trackId: 'receiver-video-track',
        generation: 1,
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(presentation.state, RemotePresentationState.failed);
    expect(presentation.error.toString(), contains('未收到可显示首帧'));
  });

  testWidgets('primary-view host opens once and preserves the session owner', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final session = RemoteSessionController(role: RemoteRole.controller);
    final settings = AppSettingsController();
    final inAppHost = _RecordingRemoteViewerHost();
    final nativeHost = _RecordingRemoteViewerHost();
    final coordinator = RemoteViewerCoordinator(
      session: session,
      inAppHost: inAppHost,
      nativeHost: nativeHost,
      nativeWindowingAvailable: () => false,
    );
    addTearDown(() async {
      await coordinator.dispose();
      session.dispose();
      settings.dispose();
    });

    await coordinator.open(
      context: context,
      session: session,
      settings: settings,
    );
    await coordinator.open(
      context: context,
      session: session,
      settings: settings,
    );

    expect(inAppHost.openCount, 1);
    expect(inAppHost.activateCount, 1);
    expect(nativeHost.openCount, 0);
    expect(inAppHost.lastRequest?.session, same(session));

    coordinator.close();
    expect(inAppHost.closeCount, 1);
    expect(nativeHost.closeCount, 1);
    expect(coordinator.isOpen, isFalse);
  });

  testWidgets('native host failure falls back without disposing the session', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );

    final session = RemoteSessionController(role: RemoteRole.controller);
    final settings = AppSettingsController();
    final inAppHost = _RecordingRemoteViewerHost();
    final nativeHost = _RecordingRemoteViewerHost(
      openError: StateError('window creation failed'),
    );
    final coordinator = RemoteViewerCoordinator(
      session: session,
      inAppHost: inAppHost,
      nativeHost: nativeHost,
      nativeWindowingAvailable: () => true,
    );
    addTearDown(() async {
      await coordinator.dispose();
      session.dispose();
      settings.dispose();
    });

    await coordinator.open(
      context: context,
      session: session,
      settings: settings,
    );

    expect(nativeHost.openCount, 1);
    expect(nativeHost.closeCount, 1);
    expect(inAppHost.openCount, 1);
    expect(inAppHost.lastRequest?.session, same(session));
    expect(coordinator.isOpen, isTrue);
  });
}

class _FakeVideoRenderer extends RTCVideoRenderer {
  _FakeVideoRenderer({this.emitFirstFrame = false, this.bindError});

  final bool emitFirstFrame;
  final Object? bindError;
  int initializeCount = 0;
  int unbindCount = 0;
  final List<String> boundTrackIds = [];
  MediaStream? _source;

  @override
  int? get textureId => initializeCount == 0 ? null : 1;

  @override
  MediaStream? get srcObject => _source;

  @override
  Future<void> initialize() async {
    initializeCount += 1;
  }

  @override
  Future<void> setSrcObject({MediaStream? stream, String? trackId}) async {
    final error = bindError;
    if (stream != null && error != null) throw error;
    _source = stream;
    if (stream == null) {
      unbindCount += 1;
      value = RTCVideoValue.empty;
      return;
    }
    boundTrackIds.add(trackId ?? '');
    if (emitFirstFrame) {
      value = value.copyWith(width: 1920, height: 1080, renderVideo: true);
      onResize?.call();
      onFirstFrameRendered?.call();
    }
  }
}

class _FakeMediaStream extends Fake implements MediaStream {
  _FakeMediaStream(this._id);

  final String _id;

  @override
  String get id => _id;

  @override
  String get ownerTag => 'remote-peer';
}

class _FakeVideoPresentationSource extends ChangeNotifier
    implements RemoteVideoPresentationSource {
  RemoteVideoBinding? _binding;
  int _refreshGeneration = 0;
  final List<(int, int, int)> presentedFrames = [];

  @override
  RemoteVideoBinding? get remoteVideoBinding => _binding;

  @override
  int get presentationRefreshGeneration => _refreshGeneration;

  void publish(RemoteVideoBinding binding) {
    _binding = binding;
    notifyListeners();
  }

  void requestPresentationRefresh() {
    _refreshGeneration += 1;
    notifyListeners();
  }

  @override
  void reportPresentedVideoFrame({
    required int trackGeneration,
    required int width,
    required int height,
  }) {
    presentedFrames.add((width, height, trackGeneration));
  }

  @override
  void updateRendererColorDiagnostics(Map<String, dynamic> diagnostics) {}
}

class _RecordingRemoteViewerHost implements RemoteViewerHost {
  _RecordingRemoteViewerHost({this.openError});

  final Object? openError;
  int openCount = 0;
  int activateCount = 0;
  int closeCount = 0;
  RemoteViewerRequest? lastRequest;
  bool _isOpen = false;

  @override
  bool get isOpen => _isOpen;

  @override
  bool canOpen(BuildContext context) => true;

  @override
  Future<void> open(RemoteViewerRequest request) async {
    openCount += 1;
    lastRequest = request;
    final error = openError;
    if (error != null) throw error;
    _isOpen = true;
  }

  @override
  void activate() {
    activateCount += 1;
  }

  @override
  void close() {
    closeCount += 1;
    _isOpen = false;
  }
}
