import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/remote_shortcut_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Windows Ctrl shortcuts target macOS Command', () {
    expect(
      RemoteShortcutPolicy.localPrimaryPressed(
        platform: RemoteControllerPlatform.windows,
        metaPressed: false,
        controlPressed: true,
      ),
      isTrue,
    );
    expect(
      RemoteShortcutPolicy.remotePrimaryModifier(
        remoteHostPlatform: HostPlatformType.macOS.name,
        controllerPlatform: RemoteControllerPlatform.windows,
      ),
      'command',
    );
  });

  test('Apple Command shortcuts target Windows Control', () {
    for (final platform in [
      RemoteControllerPlatform.macOS,
      RemoteControllerPlatform.iOS,
    ]) {
      expect(
        RemoteShortcutPolicy.localPrimaryPressed(
          platform: platform,
          metaPressed: true,
          controlPressed: false,
        ),
        isTrue,
      );
      expect(
        RemoteShortcutPolicy.remotePrimaryModifier(
          remoteHostPlatform: HostPlatformType.windows.name,
          controllerPlatform: platform,
        ),
        'control',
      );
    }
  });

  test('only the conservative common shortcut set is semantic', () {
    expect(RemoteShortcutPolicy.commonWireKey(LogicalKeyboardKey.keyC), 'KeyC');
    expect(RemoteShortcutPolicy.commonWireKey(LogicalKeyboardKey.keyV), 'KeyV');
    expect(RemoteShortcutPolicy.commonWireKey(LogicalKeyboardKey.keyS), isNull);
    expect(RemoteShortcutPolicy.commonWireKey(LogicalKeyboardKey.tab), isNull);
  });

  test('pointer modifiers map the controller primary key to the host', () {
    expect(
      RemoteShortcutPolicy.remoteModifiers(
        controllerPlatform: RemoteControllerPlatform.windows,
        remoteHostPlatform: HostPlatformType.macOS.name,
        metaPressed: false,
        controlPressed: true,
        altPressed: false,
        shiftPressed: true,
      ),
      containsAll(['command', 'shift']),
    );
    expect(
      RemoteShortcutPolicy.remoteModifiers(
        controllerPlatform: RemoteControllerPlatform.macOS,
        remoteHostPlatform: HostPlatformType.windows.name,
        metaPressed: true,
        controlPressed: false,
        altPressed: false,
        shiftPressed: false,
      ),
      ['control'],
    );
  });
}
