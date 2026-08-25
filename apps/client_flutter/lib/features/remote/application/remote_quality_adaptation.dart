import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';

enum RemoteAdaptiveVideoTier {
  hd60('1080p60', 1920, 12 * 1000 * 1000, 60),
  hd30('1080p30', 1920, 7 * 1000 * 1000, 30),
  smooth60('720p60', 1280, 5 * 1000 * 1000, 60),
  smooth30('720p30', 1280, 3 * 1000 * 1000, 30);

  const RemoteAdaptiveVideoTier(
    this.label,
    this.targetLongEdge,
    this.maxBitrate,
    this.maxFramerate,
  );

  final String label;
  final int targetLongEdge;
  final int maxBitrate;
  final int maxFramerate;

  factory RemoteAdaptiveVideoTier.fromWireValue(String? value) {
    return RemoteAdaptiveVideoTier.values.firstWhere(
      (tier) => tier.name == value,
      orElse: () => RemoteAdaptiveVideoTier.hd30,
    );
  }
}

class RemoteVideoTarget {
  const RemoteVideoTarget({
    required this.label,
    required this.targetLongEdge,
    required this.maxBitrate,
    required this.maxFramerate,
    required this.prioritizeFrameRate,
  });

  factory RemoteVideoTarget.forProfile(
    RemoteQualityProfile profile, {
    RemoteAdaptiveVideoTier automaticTier = RemoteAdaptiveVideoTier.hd30,
  }) {
    if (profile == RemoteQualityProfile.automatic) {
      return RemoteVideoTarget(
        label: '自动 · ${automaticTier.label}',
        targetLongEdge: automaticTier.targetLongEdge,
        maxBitrate: automaticTier.maxBitrate,
        maxFramerate: automaticTier.maxFramerate,
        prioritizeFrameRate: automaticTier == RemoteAdaptiveVideoTier.smooth60,
      );
    }
    return RemoteVideoTarget(
      label: profile.label,
      targetLongEdge: profile.targetLongEdge,
      maxBitrate: profile.maxBitrate,
      maxFramerate: profile.maxFramerate,
      prioritizeFrameRate: profile == RemoteQualityProfile.smooth,
    );
  }

  final String label;
  final int? targetLongEdge;
  final int maxBitrate;
  final int maxFramerate;
  final bool prioritizeFrameRate;

  double scaleFor(RemoteDisplay? display) {
    final target = targetLongEdge;
    if (target == null || display == null) return 1;
    final sourceLongEdge = display.captureWidth > display.captureHeight
        ? display.captureWidth
        : display.captureHeight;
    if (sourceLongEdge <= 0 || sourceLongEdge <= target) return 1;
    return sourceLongEdge / target;
  }
}

class RemoteQualityAdaptationController {
  RemoteQualityAdaptationController({
    this.badSamplesBeforeDowngrade = 2,
    this.goodSamplesBeforeUpgrade = 10,
    this.minimumUpgradeInterval = const Duration(seconds: 15),
  });

  final int badSamplesBeforeDowngrade;
  final int goodSamplesBeforeUpgrade;
  final Duration minimumUpgradeInterval;

  RemoteAdaptiveVideoTier _tier = RemoteAdaptiveVideoTier.hd30;
  int _badSamples = 0;
  int _goodSamples = 0;
  DateTime? _startedAt;
  DateTime? _lastChangeAt;
  RemoteAdaptiveVideoTier? _previousTier;

  RemoteAdaptiveVideoTier get tier => _tier;

  void reset({DateTime? now}) {
    _tier = RemoteAdaptiveVideoTier.hd30;
    _badSamples = 0;
    _goodSamples = 0;
    _startedAt = now;
    _lastChangeAt = null;
    _previousTier = null;
  }

  void adopt(RemoteAdaptiveVideoTier tier, {DateTime? now}) {
    _tier = tier;
    _badSamples = 0;
    _goodSamples = 0;
    _startedAt ??= now ?? DateTime.now();
    _lastChangeAt = now;
    _previousTier = null;
  }

  void rollbackLastChange() {
    final previous = _previousTier;
    if (previous == null) return;
    _tier = previous;
    _previousTier = null;
    _badSamples = 0;
    _goodSamples = 0;
  }

  void confirmLastChange() => _previousTier = null;

  RemoteAdaptiveVideoTier? observe(
    RemoteMediaDiagnostics diagnostics, {
    DateTime? now,
  }) {
    final sampledAt = now ?? DateTime.now();
    _startedAt ??= sampledAt;
    if (_isBad(diagnostics)) {
      _badSamples += 1;
      _goodSamples = 0;
      if (_badSamples >= badSamplesBeforeDowngrade) {
        final next = _lowerTier(_tier);
        if (next != _tier) {
          _apply(next, sampledAt);
          return next;
        }
        _badSamples = 0;
      }
      return null;
    }

    _badSamples = 0;
    if (!_isGood(diagnostics)) {
      _goodSamples = 0;
      return null;
    }
    _goodSamples += 1;
    final since = _lastChangeAt ?? _startedAt!;
    if (_goodSamples < goodSamplesBeforeUpgrade ||
        sampledAt.difference(since) < minimumUpgradeInterval) {
      return null;
    }
    final next = _higherTier(_tier);
    if (next == _tier) {
      _goodSamples = 0;
      return null;
    }
    final nextBitrateMbps = next.maxBitrate / 1000000;
    final available = diagnostics.availableOutgoingBitrateMbps;
    if (available != null && available < nextBitrateMbps * 1.25) {
      _goodSamples = 0;
      return null;
    }
    _apply(next, sampledAt);
    return next;
  }

  void _apply(RemoteAdaptiveVideoTier next, DateTime now) {
    _previousTier = _tier;
    _tier = next;
    _badSamples = 0;
    _goodSamples = 0;
    _lastChangeAt = now;
  }

  bool _isBad(RemoteMediaDiagnostics diagnostics) {
    final reason = diagnostics.qualityLimitationReason?.toLowerCase();
    final target = _tier;
    final dynamicContent = (diagnostics.bitrateMbps ?? 0) >= 0.5;
    final fpsTooLow =
        diagnostics.framesPerSecond != null &&
        diagnostics.framesPerSecond! < target.maxFramerate * 0.72 &&
        dynamicContent;
    return (diagnostics.packetLossPercent ?? 0) >= 2 ||
        (diagnostics.networkRoundTripMs ?? 0) >= 100 ||
        (diagnostics.availableOutgoingBitrateMbps ?? double.infinity) <
            target.maxBitrate / 1000000 * 0.75 ||
        reason == 'bandwidth' ||
        reason == 'cpu' ||
        (diagnostics.framesDroppedDelta ?? 0) > 2 ||
        (diagnostics.freezeCountDelta ?? 0) > 0 ||
        fpsTooLow;
  }

  bool _isGood(RemoteMediaDiagnostics diagnostics) {
    final fps = diagnostics.framesPerSecond;
    if (fps == null || fps < _tier.maxFramerate * 0.9) return false;
    final reason = diagnostics.qualityLimitationReason?.toLowerCase();
    if (reason != null && reason != 'none' && reason.isNotEmpty) return false;
    if ((diagnostics.packetLossPercent ?? 0) >= 0.5 ||
        (diagnostics.networkRoundTripMs ?? 0) >= 40 ||
        (diagnostics.framesDroppedDelta ?? 0) > 0 ||
        (diagnostics.freezeCountDelta ?? 0) > 0) {
      return false;
    }
    final encodeBudgetMs = 1000 / _tier.maxFramerate;
    return (diagnostics.encodeMsPerFrame ?? 0) < encodeBudgetMs * 0.7;
  }

  static RemoteAdaptiveVideoTier _lowerTier(RemoteAdaptiveVideoTier tier) {
    return switch (tier) {
      RemoteAdaptiveVideoTier.hd60 => RemoteAdaptiveVideoTier.hd30,
      RemoteAdaptiveVideoTier.hd30 => RemoteAdaptiveVideoTier.smooth60,
      RemoteAdaptiveVideoTier.smooth60 => RemoteAdaptiveVideoTier.smooth30,
      RemoteAdaptiveVideoTier.smooth30 => RemoteAdaptiveVideoTier.smooth30,
    };
  }

  static RemoteAdaptiveVideoTier _higherTier(RemoteAdaptiveVideoTier tier) {
    return switch (tier) {
      RemoteAdaptiveVideoTier.hd60 => RemoteAdaptiveVideoTier.hd60,
      RemoteAdaptiveVideoTier.hd30 => RemoteAdaptiveVideoTier.hd60,
      RemoteAdaptiveVideoTier.smooth60 => RemoteAdaptiveVideoTier.hd30,
      RemoteAdaptiveVideoTier.smooth30 => RemoteAdaptiveVideoTier.smooth60,
    };
  }
}
