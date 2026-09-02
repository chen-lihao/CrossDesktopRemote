import 'package:cross_desktop_remote/core/clipboard/clipboard_sync_mode.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_input_settings.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'settings remain usable when platform persistence is unavailable',
    () async {
      final controller = AppSettingsController();

      await controller.load();
      await controller.setDefaultQuality(RemoteQualityProfile.ultra);
      await controller.setDefaultVideoPolicy(
        const RemoteVideoPolicy(
          resolution: RemoteResolutionMode.p1440,
          frameRate: RemoteFrameRateMode.fps90,
        ),
      );
      await controller.setPointerSensitivity(9);
      await controller.setKeyboardMode(RemoteKeyboardMode.compact);
      await controller.setTextInputMode(RemoteTextInputMode.remoteIme);
      await controller.setClipboardSyncMode(ClipboardSyncMode.controllerToHost);
      await controller.setSignalingServerUrl(
        ' ws://192.168.1.10:8080/ws/signaling ',
      );
      await controller.setSessionHistoryLimit(1);
      await controller.setDisplayPresentationMode(
        RemoteDisplayPresentationMode.separateWindows,
      );

      expect(controller.loaded, isTrue);
      expect(controller.defaultQuality, RemoteQualityProfile.ultra60);
      expect(
        controller.defaultVideoPolicy.frameRate,
        RemoteFrameRateMode.fps90,
      );
      expect(controller.pointerSensitivity, 2.5);
      expect(controller.keyboardMode, RemoteKeyboardMode.compact);
      expect(controller.inputSettings.keyboardMode, RemoteKeyboardMode.compact);
      expect(
        controller.inputSettings.textInputMode,
        RemoteTextInputMode.remoteIme,
      );
      expect(controller.clipboardSyncMode, ClipboardSyncMode.controllerToHost);
      expect(
        controller.signalingServerUrl,
        'ws://192.168.1.10:8080/ws/signaling',
      );
      expect(controller.signalingServerProfile?.name, '自定义服务器');
      expect(controller.sessionHistoryLimit, 10);
      expect(
        controller.displayPresentationMode,
        RemoteDisplayPresentationMode.separateWindows,
      );
    },
  );
}
