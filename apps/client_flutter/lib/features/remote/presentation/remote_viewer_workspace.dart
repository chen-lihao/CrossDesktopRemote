import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_panel.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';

class RemoteViewerWorkspace extends StatefulWidget {
  const RemoteViewerWorkspace({
    super.key,
    required this.session,
    required this.settings,
    this.onDesktopFullScreenChanged,
    this.onClose,
  });

  final RemoteSessionController session;
  final AppSettingsController settings;
  final Future<bool> Function(bool enabled)? onDesktopFullScreenChanged;
  final VoidCallback? onClose;

  @override
  State<RemoteViewerWorkspace> createState() => _RemoteViewerWorkspaceState();
}

class _RemoteViewerWorkspaceState extends State<RemoteViewerWorkspace> {
  bool _fullScreen = false;

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
      animation: widget.session,
      builder: (context, _) {
        if (!widget.session.hasRemoteVideo) {
          return Scaffold(
            appBar: AppBar(title: const Text('远程桌面')),
            body: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.desktop_access_disabled, size: 44),
                        const SizedBox(height: 16),
                        Text(
                          widget.session.statusMessage,
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        FilledButton.tonalIcon(
                          onPressed:
                              widget.onClose ??
                              () => Navigator.maybePop(context),
                          icon: const Icon(Icons.close),
                          label: const Text('关闭窗口'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        }
        return Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            top: !_fullScreen,
            bottom: false,
            child: RemoteDesktopPanel(
              session: widget.session,
              initialInputSettings: widget.settings.inputSettings,
              windowedWorkspace: true,
              toolbarLeading: widget.onClose == null
                  ? IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back),
                    )
                  : null,
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
          ),
        );
      },
    );
  }
}
