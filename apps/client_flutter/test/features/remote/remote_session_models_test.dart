import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'remote display descriptor round trips through the control envelope',
    () {
      const display = RemoteDisplay(
        id: '69733248',
        name: 'Studio Display',
        width: 5120,
        height: 2880,
        isPrimary: false,
      );

      final decoded = RemoteDisplay.fromMessage(display.toMessage());

      expect(decoded.id, display.id);
      expect(decoded.name, display.name);
      expect(decoded.resolutionLabel, '5120×2880');
      expect(decoded.isPrimary, isFalse);
    },
  );

  test(
    'quality profiles calculate sender downscale from the source display',
    () {
      const display = RemoteDisplay(
        id: '1',
        name: '4K Display',
        width: 3840,
        height: 2160,
        isPrimary: true,
      );

      expect(RemoteQualityProfile.smooth.scaleFor(display), 3);
      expect(RemoteQualityProfile.high.scaleFor(display), 2);
      expect(RemoteQualityProfile.ultra.scaleFor(display), 1.5);
      expect(RemoteQualityProfile.original.scaleFor(display), 1);
      expect(
        RemoteQualityProfile.fromWireValue('ultra'),
        RemoteQualityProfile.ultra,
      );
    },
  );

  test('quality profiles never upscale a Sidecar source', () {
    const sidecar = RemoteDisplay(
      id: 'sidecar',
      name: 'Sidecar Display',
      width: 1311,
      height: 892,
      isPrimary: false,
    );

    expect(RemoteQualityProfile.automatic.scaleFor(sidecar), 1);
    expect(RemoteQualityProfile.high.scaleFor(sidecar), 1);
    expect(RemoteQualityProfile.ultra.scaleFor(sidecar), 1);
    expect(RemoteQualityProfile.automatic.maxFramerate, 60);
    expect(RemoteQualityProfile.ultra.maxFramerate, 30);
  });

  test(
    'Retina and Sidecar quality profiles use capture pixels, not points',
    () {
      const sidecar = RemoteDisplay(
        id: 'sidecar-retina',
        name: 'Sidecar Display',
        width: 1311,
        height: 892,
        pixelWidth: 2622,
        pixelHeight: 1784,
        pointPixelScale: 2,
        isPrimary: false,
      );

      expect(sidecar.resolutionLabel, '2622×1784');
      expect(
        sidecar.geometryDiagnosticsLabel,
        '1311×892 pt · 2622×1784 px · 2.00x',
      );
      expect(
        RemoteQualityProfile.automatic.scaleFor(sidecar),
        closeTo(1.3656, .001),
      );
      expect(
        RemoteQualityProfile.ultra.scaleFor(sidecar),
        closeTo(1.0242, .001),
      );
      expect(RemoteDisplay.fromMessage(sidecar.toMessage()).captureWidth, 2622);
    },
  );

  test('video frame size extracts the active video RTP geometry', () {
    final size = RemoteVideoFrameSize.fromRtcStats([
      {
        'type': 'outbound-rtp',
        'kind': 'audio',
        'frameWidth': 1920,
        'frameHeight': 1080,
      },
      {
        'type': 'inbound-rtp',
        'kind': 'video',
        'frameWidth': 1920,
        'frameHeight': 1080,
      },
      {
        'type': 'outbound-rtp',
        'kind': 'video',
        'frameWidth': 1311,
        'frameHeight': 892,
      },
    ], statType: 'outbound-rtp');

    expect(size?.label, '1311×892');
    expect(
      size?.approximatelyMatches(
        const RemoteVideoFrameSize(width: 1310, height: 892),
      ),
      isTrue,
    );
    expect(
      size?.approximatelyMatches(
        const RemoteVideoFrameSize(width: 1920, height: 1080),
      ),
      isFalse,
    );
  });

  test('video geometry state safely decodes protocol values', () {
    expect(
      RemoteVideoGeometryState.fromWireValue('adapting'),
      RemoteVideoGeometryState.adapting,
    );
    expect(
      RemoteVideoGeometryState.fromWireValue('future-state'),
      RemoteVideoGeometryState.stable,
    );
  });

  test('color diagnostics preserve range and per-display HDR state', () {
    final diagnostics = RemoteColorDiagnostics.fromMessage({
      'capture': {
        'pixelFormat': '420v/NV12',
        'range': 'Video Range',
        'colorPrimaries': 'ITU_R_709_2',
        'transferFunction': 'ITU_R_709_2',
        'yCbCrMatrix': 'ITU_R_709_2',
        'colorSpace': 'ITU-R BT.709',
        'captureDynamicRange': 'SDR',
        'normalization': 'Core Image GPU HDR→SDR',
        'normalizationBypassed': false,
        'normalizationDurationMs': 2.5,
        'rawFrame': {
          'stage': 'screen-capture-kit-raw',
          'width': 3024,
          'height': 1964,
          'pixelFormat': '420v/NV12',
          'range': 'Video Range',
          'colorPrimaries': 'ITU_R_709_2',
          'transferFunction': 'ITU_R_709_2',
          'yCbCrMatrix': 'ITU_R_709_2',
          'sampleCount': 1000,
          'lumaMin': 16,
          'lumaMax': 235,
          'nominalBlack': 16,
          'nominalWhite': 235,
          'belowNominalBlackPercent': 0,
          'aboveNominalWhitePercent': 0,
          'lumaHistogram16': List<int>.filled(16, 1),
        },
        'encoderInput': {
          'stage': 'webrtc-encoder-input',
          'pixelFormat': '420v/NV12',
          'range': 'Video Range',
          'sampleCount': 100,
          'lumaMin': 16,
          'lumaMax': 235,
          'nominalBlack': 16,
          'nominalWhite': 235,
        },
      },
      'displays': [
        {
          'id': '2',
          'name': 'Studio Display',
          'colorSpace': 'Display P3',
          'hdrActive': true,
          'hdrCapable': true,
          'currentEdrHeadroom': 1.6,
          'potentialEdrHeadroom': 2.0,
        },
      ],
    });

    expect(diagnostics.pixelFormat, '420v/NV12');
    expect(diagnostics.range, 'Video Range');
    expect(diagnostics.captureDynamicRange, 'SDR');
    expect(diagnostics.normalization, 'Core Image GPU HDR→SDR');
    expect(diagnostics.normalizationBypassed, isFalse);
    expect(diagnostics.normalizationDurationMs, 2.5);
    expect(diagnostics.rawFrame?.dimensions, '3024×1964');
    expect(diagnostics.rawFrame?.lumaHistogram16, hasLength(16));
    expect(diagnostics.encoderInput?.aboveNominalWhitePercent, 0);
    expect(diagnostics.forDisplay('2')?.hdrActive, isTrue);
  });
}
