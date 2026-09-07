import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/widgets.dart';

class RemoteViewerRequest {
  const RemoteViewerRequest({
    required this.context,
    required this.session,
    required this.settings,
  });

  final BuildContext context;
  final RemoteSessionController session;
  final AppSettingsController settings;
}

/// Presentation boundary for a connected remote session.
///
/// Implementations may attach the viewer to the primary Flutter view or a
/// native secondary view, but must never own or dispose the session itself.
abstract interface class RemoteViewerHost {
  bool get isOpen;

  bool canOpen(BuildContext context);

  Future<void> open(RemoteViewerRequest request);

  void activate();

  void close();
}
