import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_coordinator.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
      inAppHost: inAppHost,
      nativeHost: nativeHost,
      nativeWindowingAvailable: () => false,
    );
    addTearDown(() {
      coordinator.close();
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
      inAppHost: inAppHost,
      nativeHost: nativeHost,
      nativeWindowingAvailable: () => true,
    );
    addTearDown(() {
      coordinator.close();
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
