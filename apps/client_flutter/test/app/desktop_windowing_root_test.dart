import 'package:cross_desktop_remote/app/desktop_windowing_root.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('native secondary viewer is enabled only for accepted macOS path', () {
    expect(nativeDesktopWindowingSupported('macos'), isTrue);
    expect(nativeDesktopWindowingSupported('windows'), isFalse);
    expect(nativeDesktopWindowingSupported('linux'), isFalse);
    expect(nativeDesktopWindowingSupported('ios'), isFalse);
  });
}
