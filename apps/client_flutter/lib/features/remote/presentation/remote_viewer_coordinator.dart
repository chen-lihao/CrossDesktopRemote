import 'package:cross_desktop_remote/app/desktop_windowing_root.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/in_app_remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/remote/presentation/native_remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/widgets.dart';

/// Selects a presentation host without changing the session, media track or
/// input lifecycle. Windows intentionally stays in the primary Flutter view:
/// the current WebRTC texture registrar is not view-aware.
class RemoteViewerCoordinator {
  RemoteViewerCoordinator({
    RemoteViewerHost? inAppHost,
    RemoteViewerHost? nativeHost,
    bool Function()? nativeWindowingAvailable,
  }) : _inAppHost = inAppHost ?? InAppRemoteViewerHost(),
       _nativeHost = nativeHost ?? NativeRemoteViewerHost(),
       _nativeWindowingAvailable =
           nativeWindowingAvailable ?? (() => desktopWindowingAvailable);

  final RemoteViewerHost _inAppHost;
  final RemoteViewerHost _nativeHost;
  final bool Function() _nativeWindowingAvailable;

  RemoteViewerHost? _activeHost;
  bool _opening = false;

  bool get isOpen => _activeHost?.isOpen ?? false;

  Future<void> open({
    required BuildContext context,
    required RemoteSessionController session,
    required AppSettingsController settings,
  }) async {
    final activeHost = _activeHost;
    if (_opening || activeHost?.isOpen == true) {
      activeHost?.activate();
      return;
    }
    if (!context.mounted) return;

    _opening = true;
    final request = RemoteViewerRequest(
      context: context,
      session: session,
      settings: settings,
    );
    final preferredHost =
        _nativeWindowingAvailable() && _nativeHost.canOpen(context)
        ? _nativeHost
        : _inAppHost;

    try {
      _activeHost = preferredHost;
      await preferredHost.open(request);
    } catch (error, stackTrace) {
      debugPrint('Opening remote viewer failed: $error\n$stackTrace');
      preferredHost.close();
      if (preferredHost != _inAppHost && context.mounted) {
        AppMessenger.show('独立窗口打开失败，已改在当前窗口显示', level: AppMessageLevel.warning);
        try {
          _activeHost = _inAppHost;
          await _inAppHost.open(request);
        } catch (fallbackError, fallbackStackTrace) {
          debugPrint(
            'Opening in-app remote viewer failed: '
            '$fallbackError\n$fallbackStackTrace',
          );
          AppMessenger.show(
            '无法打开远程桌面，连接仍保持有效，请重试',
            level: AppMessageLevel.error,
          );
        }
      } else {
        AppMessenger.show('无法打开远程桌面，连接仍保持有效，请重试', level: AppMessageLevel.error);
      }
    } finally {
      _opening = false;
      if (_activeHost?.isOpen != true) _activeHost = null;
    }
  }

  void close() {
    _inAppHost.close();
    _nativeHost.close();
    _activeHost = null;
    _opening = false;
  }
}
