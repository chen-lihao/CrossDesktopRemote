import 'package:cross_desktop_remote/core/privacy/host_privacy_screen.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'com.crossdesktopremote.cross_desktop_remote/input',
  );

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('fully active requires every display and capture exclusion', () {
    final complete = HostPrivacyScreenStatus.fromMap(const {
      'phase': 'active',
      'coveredDisplayCount': 2,
      'expectedDisplayCount': 2,
      'captureExcluded': true,
    });
    final incomplete = HostPrivacyScreenStatus.fromMap(const {
      'phase': 'active',
      'coveredDisplayCount': 1,
      'expectedDisplayCount': 2,
      'captureExcluded': true,
    });
    final visibleToCapture = HostPrivacyScreenStatus.fromMap(const {
      'phase': 'active',
      'coveredDisplayCount': 2,
      'expectedDisplayCount': 2,
      'captureExcluded': false,
    });

    expect(complete.isFullyActive, isTrue);
    expect(incomplete.isFullyActive, isFalse);
    expect(visibleToCapture.isFullyActive, isFalse);
  });

  test('method channel bridge preserves activation transaction data', () async {
    MethodCall? received;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          received = call;
          return const <String, Object?>{
            'phase': 'active',
            'coveredDisplayCount': 1,
            'expectedDisplayCount': 1,
            'captureExcluded': true,
          };
        });

    const bridge = MethodChannelHostPrivacyScreenBridge();
    final status = await bridge.activate(
      sessionId: 'session-42',
      controllerLabel: 'Controller',
    );

    expect(received?.method, 'activatePrivacyScreen');
    expect(received?.arguments, {
      'sessionId': 'session-42',
      'controllerLabel': 'Controller',
    });
    expect(status.isFullyActive, isTrue);
  });

  test('capability rejects backends without capture exclusion', () {
    final capability = HostPrivacyScreenCapabilities.fromMap(const {
      'available': true,
      'assurance': 'bestEffort',
      'supportsCaptureExclusion': false,
      'supportsInputSuppression': false,
      'secureDesktopCoverage': false,
      'displayCount': 1,
    });

    expect(capability.canStartStandardPrivacyScreen, isFalse);
  });
}
