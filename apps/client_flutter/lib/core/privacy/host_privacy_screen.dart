import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum HostPrivacyMode {
  disabled,
  standardRequired;

  String get label => switch (this) {
    HostPrivacyMode.disabled => '关闭',
    HostPrivacyMode.standardRequired => '标准隐私屏',
  };

  String get description => switch (this) {
    HostPrivacyMode.disabled => '被远程控制时，本机显示器仍显示桌面内容',
    HostPrivacyMode.standardRequired => '被远程控制时覆盖全部本机显示器；任何显示器覆盖失败都会终止连接',
  };
}

enum HostPrivacyAssurance { unavailable, bestEffort, verified }

enum HostPrivacyScreenPhase {
  inactive,
  preparing,
  active,
  degraded,
  failed,
  restoring,
}

@immutable
class HostPrivacyScreenCapabilities {
  const HostPrivacyScreenCapabilities({
    required this.available,
    required this.assurance,
    required this.supportsCaptureExclusion,
    required this.supportsInputSuppression,
    required this.secureDesktopCoverage,
    required this.displayCount,
    this.limitation,
  });

  const HostPrivacyScreenCapabilities.unavailable({String? limitation})
    : this(
        available: false,
        assurance: HostPrivacyAssurance.unavailable,
        supportsCaptureExclusion: false,
        supportsInputSuppression: false,
        secureDesktopCoverage: false,
        displayCount: 0,
        limitation: limitation,
      );

  factory HostPrivacyScreenCapabilities.fromMap(Map<Object?, Object?> value) {
    final assuranceName = value['assurance'] as String? ?? 'unavailable';
    return HostPrivacyScreenCapabilities(
      available: value['available'] == true,
      assurance: HostPrivacyAssurance.values.firstWhere(
        (item) => item.name == assuranceName,
        orElse: () => HostPrivacyAssurance.unavailable,
      ),
      supportsCaptureExclusion: value['supportsCaptureExclusion'] == true,
      supportsInputSuppression: value['supportsInputSuppression'] == true,
      secureDesktopCoverage: value['secureDesktopCoverage'] == true,
      displayCount: (value['displayCount'] as num?)?.toInt() ?? 0,
      limitation: value['limitation'] as String?,
    );
  }

  final bool available;
  final HostPrivacyAssurance assurance;
  final bool supportsCaptureExclusion;
  final bool supportsInputSuppression;
  final bool secureDesktopCoverage;
  final int displayCount;
  final String? limitation;

  bool get canStartStandardPrivacyScreen =>
      available && supportsCaptureExclusion && displayCount > 0;
}

@immutable
class HostPrivacyScreenStatus {
  const HostPrivacyScreenStatus({
    required this.phase,
    required this.coveredDisplayCount,
    required this.expectedDisplayCount,
    required this.captureExcluded,
    this.failureReason,
  });

  const HostPrivacyScreenStatus.inactive()
    : this(
        phase: HostPrivacyScreenPhase.inactive,
        coveredDisplayCount: 0,
        expectedDisplayCount: 0,
        captureExcluded: false,
      );

  factory HostPrivacyScreenStatus.fromMap(Map<Object?, Object?> value) {
    final phaseName = value['phase'] as String? ?? 'failed';
    return HostPrivacyScreenStatus(
      phase: HostPrivacyScreenPhase.values.firstWhere(
        (item) => item.name == phaseName,
        orElse: () => HostPrivacyScreenPhase.failed,
      ),
      coveredDisplayCount: (value['coveredDisplayCount'] as num?)?.toInt() ?? 0,
      expectedDisplayCount:
          (value['expectedDisplayCount'] as num?)?.toInt() ?? 0,
      captureExcluded: value['captureExcluded'] == true,
      failureReason: value['failureReason'] as String?,
    );
  }

  final HostPrivacyScreenPhase phase;
  final int coveredDisplayCount;
  final int expectedDisplayCount;
  final bool captureExcluded;
  final String? failureReason;

  bool get isFullyActive =>
      phase == HostPrivacyScreenPhase.active &&
      captureExcluded &&
      expectedDisplayCount > 0 &&
      coveredDisplayCount == expectedDisplayCount;
}

abstract interface class HostPrivacyScreenProvider {
  Future<HostPrivacyScreenCapabilities> getPrivacyScreenCapabilities();

  Future<HostPrivacyScreenStatus> activatePrivacyScreen({
    required String sessionId,
    required String controllerLabel,
  });

  Future<HostPrivacyScreenStatus> getPrivacyScreenStatus();

  Future<void> deactivatePrivacyScreen();
}

abstract interface class HostPrivacyScreenBridge {
  Future<HostPrivacyScreenCapabilities> getCapabilities();

  Future<HostPrivacyScreenStatus> activate({
    required String sessionId,
    required String controllerLabel,
  });

  Future<HostPrivacyScreenStatus> getStatus();

  Future<void> deactivate();
}

class MethodChannelHostPrivacyScreenBridge implements HostPrivacyScreenBridge {
  const MethodChannelHostPrivacyScreenBridge({MethodChannel? channel})
    : _channel =
          channel ??
          const MethodChannel(
            'com.crossdesktopremote.cross_desktop_remote/input',
          );

  final MethodChannel _channel;

  @override
  Future<HostPrivacyScreenCapabilities> getCapabilities() async {
    final value =
        await _channel.invokeMapMethod<Object?, Object?>(
          'getPrivacyScreenCapabilities',
        ) ??
        const <Object?, Object?>{};
    return HostPrivacyScreenCapabilities.fromMap(value);
  }

  @override
  Future<HostPrivacyScreenStatus> activate({
    required String sessionId,
    required String controllerLabel,
  }) async {
    final value =
        await _channel.invokeMapMethod<Object?, Object?>(
          'activatePrivacyScreen',
          <String, Object?>{
            'sessionId': sessionId,
            'controllerLabel': controllerLabel,
          },
        ) ??
        const <Object?, Object?>{};
    return HostPrivacyScreenStatus.fromMap(value);
  }

  @override
  Future<HostPrivacyScreenStatus> getStatus() async {
    final value =
        await _channel.invokeMapMethod<Object?, Object?>(
          'getPrivacyScreenStatus',
        ) ??
        const <Object?, Object?>{};
    return HostPrivacyScreenStatus.fromMap(value);
  }

  @override
  Future<void> deactivate() =>
      _channel.invokeMethod<void>('deactivatePrivacyScreen');
}
