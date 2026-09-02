// Flutter's same-isolate desktop windowing API is still marked internal.
// All references are contained here and guarded by the runtime feature flag.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/app/desktop_windowing_root.dart';
import 'package:cross_desktop_remote/app/theme.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_panel.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';

/// Owns presentation only. The session, media tracks and input state remain in
/// [RemoteSessionController], so opening or closing a viewer never reconnects.
class RemoteViewerCoordinator {
  RegularWindowController? _windowController;
  WindowEntry? _windowEntry;
  WindowRegistry? _windowRegistry;
  bool _routeOpen = false;

  bool get desktopWindowOpen => _windowController != null;

  Future<void> open({
    required BuildContext context,
    required RemoteSessionController session,
    required AppSettingsController settings,
  }) async {
    if (desktopWindowingAvailable &&
        (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      final registry = WindowRegistry.maybeOf(context);
      if (registry != null) {
        _openDesktopWindow(
          registry: registry,
          session: session,
          settings: settings,
        );
        return;
      }
    }
    if (_routeOpen || !context.mounted) return;
    _routeOpen = true;
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          settings: const RouteSettings(name: '/remote-workspace'),
          builder: (_) =>
              RemoteViewerWorkspace(session: session, settings: settings),
        ),
      );
    } finally {
      _routeOpen = false;
    }
  }

  void _openDesktopWindow({
    required WindowRegistry registry,
    required RemoteSessionController session,
    required AppSettingsController settings,
  }) {
    final existing = _windowController;
    if (existing != null) {
      existing.activate();
      return;
    }

    late final WindowEntry entry;
    late final RegularWindowController controller;
    var unregistered = false;
    void unregister() {
      if (unregistered) return;
      unregistered = true;
      if (_windowEntry == entry) {
        registry.unregister(entry);
        _windowEntry = null;
        _windowRegistry = null;
      }
    }

    controller = RegularWindowController(
      size: const Size(1280, 800),
      constraints: const BoxConstraints(minWidth: 720, minHeight: 480),
      title: _windowTitle(session),
      delegate: _RemoteViewerWindowDelegate(
        onCloseRequested: () {
          unregister();
          controller.destroy();
        },
        onDestroyed: () {
          unregister();
          if (_windowController == controller) {
            _windowController = null;
          }
          controller.dispose();
        },
      ),
    );
    entry = WindowEntry(
      controller: controller,
      builder: (_) => MaterialApp(
        title: _windowTitle(session),
        debugShowCheckedModeBanner: false,
        theme: CrossDesktopTheme.light(),
        darkTheme: CrossDesktopTheme.dark(),
        themeMode: ThemeMode.system,
        home: RemoteViewerWorkspace(
          session: session,
          settings: settings,
          windowController: controller,
          onClose: close,
        ),
      ),
    );
    _windowController = controller;
    _windowEntry = entry;
    _windowRegistry = registry;
    registry.register(entry);
    controller.activate();
  }

  String _windowTitle(RemoteSessionController session) {
    final device = session.remoteDeviceId?.trim();
    return device == null || device.isEmpty
        ? 'CrossDesktopRemote · 远程桌面'
        : 'CrossDesktopRemote · $device';
  }

  void close() {
    final controller = _windowController;
    final entry = _windowEntry;
    final registry = _windowRegistry;
    _windowController = null;
    _windowEntry = null;
    _windowRegistry = null;
    if (entry != null && registry != null) registry.unregister(entry);
    if (controller != null) {
      controller.destroy();
    }
  }
}

class _RemoteViewerWindowDelegate with RegularWindowControllerDelegate {
  _RemoteViewerWindowDelegate({
    required this.onCloseRequested,
    required this.onDestroyed,
  });

  final VoidCallback onCloseRequested;
  final VoidCallback onDestroyed;

  @override
  void onWindowCloseRequested(RegularWindowController controller) {
    onCloseRequested();
  }

  @override
  void onWindowDestroyed() {
    onDestroyed();
  }
}

class RemoteViewerWorkspace extends StatefulWidget {
  const RemoteViewerWorkspace({
    super.key,
    required this.session,
    required this.settings,
    this.windowController,
    this.onClose,
  });

  final RemoteSessionController session;
  final AppSettingsController settings;
  final RegularWindowController? windowController;
  final VoidCallback? onClose;

  @override
  State<RemoteViewerWorkspace> createState() => _RemoteViewerWorkspaceState();
}

class _RemoteViewerWorkspaceState extends State<RemoteViewerWorkspace> {
  bool _fullScreen = false;

  Future<bool> _setFullScreen(bool enabled) async {
    final controller = widget.windowController;
    if (controller == null) return false;
    controller.setFullscreen(enabled);
    if (mounted) setState(() => _fullScreen = enabled);
    return true;
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
              toolbarLeading: widget.windowController == null
                  ? IconButton(
                      tooltip: '返回',
                      onPressed: () => Navigator.maybePop(context),
                      icon: const Icon(Icons.arrow_back),
                    )
                  : null,
              desktopFullScreen: _fullScreen,
              onDesktopFullScreenChanged: widget.windowController == null
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
