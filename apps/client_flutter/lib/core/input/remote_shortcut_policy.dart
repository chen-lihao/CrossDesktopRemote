import 'dart:io';

import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:flutter/services.dart';

enum RemoteControllerPlatform { macOS, windows, iOS, linux, android, other }

RemoteControllerPlatform currentRemoteControllerPlatform() {
  if (Platform.isMacOS) return RemoteControllerPlatform.macOS;
  if (Platform.isWindows) return RemoteControllerPlatform.windows;
  if (Platform.isIOS) return RemoteControllerPlatform.iOS;
  if (Platform.isLinux) return RemoteControllerPlatform.linux;
  if (Platform.isAndroid) return RemoteControllerPlatform.android;
  return RemoteControllerPlatform.other;
}

/// Maps the controller's familiar primary shortcut to the host platform.
///
/// Raw modifiers remain available for platform-specific shortcuts. Only the
/// small, well-known application shortcut set is treated semantically.
abstract final class RemoteShortcutPolicy {
  static const Set<String> commonWireKeys = {
    'KeyA',
    'KeyC',
    'KeyF',
    'KeyV',
    'KeyX',
    'KeyZ',
  };

  static String? commonWireKey(LogicalKeyboardKey key) =>
      _commonShortcutKeys[key];

  static bool localPrimaryPressed({
    required RemoteControllerPlatform platform,
    required bool metaPressed,
    required bool controlPressed,
  }) => switch (platform) {
    RemoteControllerPlatform.macOS ||
    RemoteControllerPlatform.iOS => metaPressed,
    RemoteControllerPlatform.windows ||
    RemoteControllerPlatform.linux ||
    RemoteControllerPlatform.android ||
    RemoteControllerPlatform.other => controlPressed,
  };

  static String remotePrimaryModifier({
    required String? remoteHostPlatform,
    required RemoteControllerPlatform controllerPlatform,
  }) {
    if (remoteHostPlatform == HostPlatformType.windows.name) return 'control';
    if (remoteHostPlatform == HostPlatformType.macOS.name) return 'command';
    return switch (controllerPlatform) {
      RemoteControllerPlatform.macOS ||
      RemoteControllerPlatform.iOS => 'command',
      _ => 'control',
    };
  }

  static String primaryLabel(String modifier) =>
      modifier == 'command' ? '⌘' : 'Ctrl';

  /// Converts the controller's physical modifier state into semantic host
  /// modifiers. The familiar primary key follows the destination platform,
  /// while non-primary Control/Command remain available independently.
  static List<String> remoteModifiers({
    required RemoteControllerPlatform controllerPlatform,
    required String? remoteHostPlatform,
    required bool metaPressed,
    required bool controlPressed,
    required bool altPressed,
    required bool shiftPressed,
  }) {
    final values = <String>{};
    final primaryPressed = localPrimaryPressed(
      platform: controllerPlatform,
      metaPressed: metaPressed,
      controlPressed: controlPressed,
    );
    if (primaryPressed) {
      values.add(
        remotePrimaryModifier(
          remoteHostPlatform: remoteHostPlatform,
          controllerPlatform: controllerPlatform,
        ),
      );
    }
    final localPrimaryIsMeta =
        controllerPlatform == RemoteControllerPlatform.macOS ||
        controllerPlatform == RemoteControllerPlatform.iOS;
    if (controlPressed && !localPrimaryIsMeta) {
      // Control is already represented by the semantic primary modifier.
    } else if (controlPressed) {
      values.add('control');
    }
    if (metaPressed && localPrimaryIsMeta) {
      // Meta is already represented by the semantic primary modifier.
    } else if (metaPressed) {
      values.add('command');
    }
    if (altPressed) values.add('option');
    if (shiftPressed) values.add('shift');
    return values.toList(growable: false);
  }

  static String commandLabel(String? remoteHostPlatform) =>
      remoteHostPlatform == HostPlatformType.windows.name ? 'Win' : '⌘';
}

final Map<LogicalKeyboardKey, String> _commonShortcutKeys = {
  LogicalKeyboardKey.keyA: 'KeyA',
  LogicalKeyboardKey.keyC: 'KeyC',
  LogicalKeyboardKey.keyF: 'KeyF',
  LogicalKeyboardKey.keyV: 'KeyV',
  LogicalKeyboardKey.keyX: 'KeyX',
  LogicalKeyboardKey.keyZ: 'KeyZ',
};
