import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_geometry.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('contain excludes letterboxing from pointer coordinates', () {
    final transform = RemoteContentTransform.forViewport(
      sourceSize: const Size(1920, 1080),
      viewportSize: const Size(1000, 1000),
      fit: BoxFit.contain,
    );

    expect(
      transform.destinationRect,
      const Rect.fromLTRB(0, 218.75, 1000, 781.25),
    );
    expect(transform.normalize(const Offset(500, 500)), const Offset(0.5, 0.5));
    expect(transform.normalize(const Offset(500, 100)), isNull);
  });

  test('cover maps a cropped viewport back into the full remote screen', () {
    final transform = RemoteContentTransform.forViewport(
      sourceSize: const Size(1920, 1080),
      viewportSize: const Size(1000, 1000),
      fit: BoxFit.cover,
    );

    expect(transform.normalize(const Offset(500, 500)), const Offset(0.5, 0.5));
    expect(
      transform.normalize(const Offset(0, 500))!.dx,
      closeTo(0.21875, 0.0001),
    );
    expect(transform.normalize(const Offset(1000, 500)), isNull);
  });
}
