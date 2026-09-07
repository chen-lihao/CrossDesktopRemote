// Flutter's same-isolate desktop windowing API is still marked internal.
// Keep every reference inside this native host; production Windows never
// instantiates a secondary Flutter view.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:cross_desktop_remote/app/theme.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_host.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_viewer_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';

class NativeRemoteViewerHost implements RemoteViewerHost {
  RegularWindowController? _windowController;
  WindowEntry? _windowEntry;
  WindowRegistry? _windowRegistry;

  @override
  bool get isOpen => _windowController != null;

  @override
  bool canOpen(BuildContext context) => WindowRegistry.maybeOf(context) != null;

  @override
  Future<void> open(RemoteViewerRequest request) async {
    final existing = _windowController;
    if (existing != null) {
      existing.activate();
      return;
    }
    final registry = WindowRegistry.maybeOf(request.context);
    if (registry == null) {
      throw UnsupportedError('A native window registry is not available');
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
      title: _windowTitle(request),
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
        title: _windowTitle(request),
        debugShowCheckedModeBanner: false,
        theme: CrossDesktopTheme.light(),
        darkTheme: CrossDesktopTheme.dark(),
        themeMode: ThemeMode.system,
        home: RemoteViewerWorkspace(
          session: request.session,
          settings: request.settings,
          onDesktopFullScreenChanged: (enabled) async {
            controller.setFullscreen(enabled);
            return true;
          },
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

  String _windowTitle(RemoteViewerRequest request) {
    final device = request.session.remoteDeviceId?.trim();
    return device == null || device.isEmpty
        ? 'CrossDesktopRemote · 远程桌面'
        : 'CrossDesktopRemote · $device';
  }

  @override
  void activate() => _windowController?.activate();

  @override
  void close() {
    final controller = _windowController;
    final entry = _windowEntry;
    final registry = _windowRegistry;
    _windowController = null;
    _windowEntry = null;
    _windowRegistry = null;
    if (entry != null && registry != null) registry.unregister(entry);
    controller?.destroy();
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
