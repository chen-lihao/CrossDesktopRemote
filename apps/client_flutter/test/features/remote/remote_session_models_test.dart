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
    expect(diagnostics.forDisplay('2')?.hdrActive, isTrue);
  });
}
