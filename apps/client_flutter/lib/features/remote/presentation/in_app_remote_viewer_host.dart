import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_presentation_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_workspace.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';

/// Hosts the remote desktop in the primary Flutter view.
///
/// Opening and closing only changes visibility. The workspace and its Texture
/// remain mounted until the application shell is disposed, so window actions
/// cannot recreate the renderer or rebind the media track.
class InAppRemoteViewerHost extends ChangeNotifier implements RemoteViewerHost {
  RemoteViewerRequest? _request;
  bool _visible = false;

  RemoteViewerRequest? get request => _request;
  bool get visible => _visible;

  @override
  bool get isOpen => _visible;

  @override
  bool canOpen(BuildContext context) => context.mounted;

  @override
  Future<void> open(RemoteViewerRequest request) async {
    if (!request.context.mounted) return;
    _request ??= request;
    if (!identical(_request!.session, request.session)) {
      throw StateError(
        'The primary viewer is already owned by another session',
      );
    }
    _visible = true;
    request.presentation.setVisible(true);
    notifyListeners();
  }

  @override
  void activate() {
    final request = _request;
    if (request == null) return;
    _visible = true;
    request.presentation.setVisible(true);
    notifyListeners();
  }

  @override
  void close() {
    if (!_visible) return;
    _visible = false;
    _request?.presentation.setVisible(false);
    notifyListeners();
  }

  void clear() {
    _request?.presentation.setVisible(false);
    _request = null;
    _visible = false;
    notifyListeners();
  }
}

/// Keeps the primary-view remote workspace alive independently of navigation.
class InAppRemoteViewerPortal extends StatelessWidget {
  const InAppRemoteViewerPortal({
    super.key,
    required this.host,
    required this.session,
    required this.presentation,
    required this.settings,
    required this.prewarm,
    required this.child,
  });

  final InAppRemoteViewerHost host;
  final RemoteSessionController session;
  final RemotePresentationController presentation;
  final AppSettingsController settings;
  final bool prewarm;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: host,
      builder: (context, _) {
        final request = host.request;
        final shouldMount = prewarm || request != null;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (shouldMount)
              IgnorePointer(
                ignoring: !host.visible,
                child: RemoteViewerWorkspace(
                  key: const ValueKey('persistent-primary-remote-viewer'),
                  session: request?.session ?? session,
                  presentation: request?.presentation ?? presentation,
                  settings: request?.settings ?? settings,
                  active: host.visible,
                  onClose: host.close,
                ),
              ),
            IgnorePointer(
              ignoring: host.visible,
              child: Visibility.maintain(visible: !host.visible, child: child),
            ),
          ],
        );
      },
    );
  }
}
