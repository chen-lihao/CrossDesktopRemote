import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  test('decodes the actual ScreenCaptureKit configuration result', () {
    final configuration = DesktopCaptureConfiguration.fromMap({
      'result': true,
      'sourceId': '69733248',
      'captureGeneration': 7,
      'width': 1920,
      'height': 1306,
      'frameRate': 30,
    });

    expect(configuration.applied, isTrue);
    expect(configuration.sourceId, '69733248');
    expect(configuration.captureGeneration, 7);
    expect(configuration.hasValidGeometry, isTrue);
    expect(configuration.width, 1920);
    expect(configuration.height, 1306);
  });
}
