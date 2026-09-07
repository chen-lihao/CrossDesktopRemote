import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_workspace.dart';
import 'package:flutter/material.dart';

/// Hosts the remote desktop in the primary Flutter view.
///
/// This is the production path on Windows so the WebRTC renderer and its
/// texture always remain attached to the registrar that created them.
class InAppRemoteViewerHost implements RemoteViewerHost {
  Route<void>? _route;
  NavigatorState? _navigator;

  @override
  bool get isOpen => _route != null;

  @override
  bool canOpen(BuildContext context) => context.mounted;

  @override
  Future<void> open(RemoteViewerRequest request) async {
    if (isOpen || !request.context.mounted) return;

    final navigator = Navigator.of(request.context);
    final route = MaterialPageRoute<void>(
      settings: const RouteSettings(name: '/remote-workspace'),
      builder: (_) => RemoteViewerWorkspace(
        session: request.session,
        settings: request.settings,
      ),
    );
    _navigator = navigator;
    _route = route;
    try {
      await navigator.push<void>(route);
    } finally {
      if (identical(_route, route)) {
        _route = null;
        _navigator = null;
      }
    }
  }

  @override
  void activate() {
    // The in-app route is already on the primary navigator. Do not pop any
    // child dialogs or fullscreen routes that may currently be above it.
  }

  @override
  void close() {
    final route = _route;
    final navigator = _navigator;
    _route = null;
    _navigator = null;
    if (route == null || navigator == null || !navigator.mounted) return;
    if (!route.isActive) return;
    try {
      navigator.removeRoute<void>(route);
    } catch (error, stackTrace) {
      debugPrint('Closing in-app remote viewer failed: $error\n$stackTrace');
    }
  }
}
