import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_panel.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_presentation_controller.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';

class RemoteViewerWorkspace extends StatefulWidget {
  const RemoteViewerWorkspace({
    super.key,
    required this.session,
    required this.presentation,
    required this.settings,
    this.active = true,
    this.onDesktopFullScreenChanged,
    this.onClose,
  });

  final RemoteSessionController session;
  final RemotePresentationController presentation;
  final AppSettingsController settings;
  final bool active;
  final Future<bool> Function(bool enabled)? onDesktopFullScreenChanged;
  final VoidCallback? onClose;

  @override
  State<RemoteViewerWorkspace> createState() => _RemoteViewerWorkspaceState();
}

class _RemoteViewerWorkspaceState extends State<RemoteViewerWorkspace> {
  bool _fullScreen = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.presentation.attachSurface());
  }

  @override
  void dispose() {
    unawaited(widget.presentation.detachSurface());
    super.dispose();
  }

  Future<bool> _setFullScreen(bool enabled) async {
    final changeFullScreen = widget.onDesktopFullScreenChanged;
    if (changeFullScreen == null) return false;
    final changed = await changeFullScreen(enabled);
    if (changed && mounted) setState(() => _fullScreen = enabled);
    return changed;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([widget.session, widget.presentation]),
      builder: (context, _) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            top: !_fullScreen,
            bottom: false,
            child: Stack(
              fit: StackFit.expand,
              children: [
                RemoteDesktopPanel(
                  session: widget.session,
                  renderer: widget.presentation.renderer,
                  active: widget.active,
                  initialInputSettings: widget.settings.inputSettings,
                  windowedWorkspace: true,
                  toolbarLeading: IconButton(
                    tooltip: '返回',
                    onPressed:
                        widget.onClose ?? () => Navigator.maybePop(context),
                    icon: const Icon(Icons.arrow_back),
                  ),
                  desktopFullScreen: _fullScreen,
                  onDesktopFullScreenChanged:
                      widget.onDesktopFullScreenChanged == null
                      ? null
                      : _setFullScreen,
                  onKeyboardModeChanged: (mode) =>
                      unawaited(widget.settings.setKeyboardMode(mode)),
                  onTextInputModeChanged: (mode) =>
                      unawaited(widget.settings.setTextInputMode(mode)),
                ),
                if (widget.active && !widget.presentation.isReady)
                  _PresentationLoadingOverlay(
                    failed:
                        widget.presentation.state ==
                        RemotePresentationState.failed,
                    message:
                        widget.presentation.state ==
                            RemotePresentationState.failed
                        ? '视频显示初始化失败：${widget.presentation.error}'
                        : widget.session.hasRemoteVideo
                        ? '正在准备远程画面…'
                        : widget.session.statusMessage,
                    onRetry: () =>
                        unawaited(widget.presentation.retryBinding()),
                    onClose:
                        widget.onClose ?? () => Navigator.maybePop(context),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _PresentationLoadingOverlay extends StatelessWidget {
  const _PresentationLoadingOverlay({
    required this.failed,
    required this.message,
    required this.onRetry,
    required this.onClose,
  });

  final bool failed;
  final String message;
  final VoidCallback onRetry;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.black,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (failed)
                    const Icon(Icons.error_outline, size: 36)
                  else
                    const CircularProgressIndicator(),
                  const SizedBox(height: 20),
                  Text(message, textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      if (failed)
                        FilledButton.icon(
                          onPressed: onRetry,
                          icon: const Icon(Icons.refresh),
                          label: const Text('重试画面绑定'),
                        ),
                      FilledButton.tonalIcon(
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                        label: const Text('关闭远程桌面'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
