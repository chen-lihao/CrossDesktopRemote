import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_geometry.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('locks the committed source geometry during display switching', () {
    final size = resolveRemotePresentationSourceSize(
      rendererSize: const Size(1311, 892),
      fallbackSize: const Size(1311, 892),
      committedSize: const Size(1920, 1080),
      geometryLocked: true,
    );

    expect(size, const Size(1920, 1080));
  });

  test('keeps the explicitly committed target geometry authoritative', () {
    final size = resolveRemotePresentationSourceSize(
      rendererSize: const Size(1920, 1080),
      fallbackSize: const Size(1920, 1080),
      committedSize: const Size(1311, 892),
      geometryLocked: false,
    );

    expect(size, const Size(1311, 892));
  });

  test(
    'ignores an uncommitted renderer aspect change outside a transaction',
    () {
      final size = resolveRemotePresentationSourceSize(
        rendererSize: const Size(1920, 832),
        fallbackSize: const Size(1920, 1080),
        committedSize: const Size(1920, 1080),
        geometryLocked: false,
      );

      expect(size, const Size(1920, 1080));
    },
  );

  test('recovered main display fills the expected iPad contain width', () {
    final sourceSize = resolveRemotePresentationSourceSize(
      rendererSize: const Size(1920, 832),
      fallbackSize: const Size(1920, 1080),
      committedSize: const Size(1920, 1080),
      geometryLocked: false,
    );
    final transform = RemoteContentTransform.forViewport(
      sourceSize: sourceSize,
      viewportSize: const Size(1568, 1048),
      fit: BoxFit.contain,
    );

    expect(transform.destinationRect.width, 1568);
    expect(transform.destinationRect.height, closeTo(882, 0.001));
    expect(
      transform.normalize(transform.destinationRect.center),
      const Offset(.5, .5),
    );
  });

  test('detects material aspect ratio changes without reacting to scaling', () {
    expect(
      remoteAspectRatiosDiffer(const Size(1920, 1080), const Size(1280, 720)),
      isFalse,
    );
    expect(
      remoteAspectRatiosDiffer(const Size(1920, 1080), const Size(1311, 892)),
      isTrue,
    );
  });

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

  test('Sidecar contain geometry remains centered on both axes', () {
    final transform = RemoteContentTransform.forViewport(
      sourceSize: const Size(1311, 892),
      viewportSize: const Size(1366, 1024),
      fit: BoxFit.contain,
    );

    final rect = transform.destinationRect;
    expect(rect.center, const Offset(683, 512));
    expect(rect.left, closeTo(0, 0.001));
    expect(rect.top, greaterThan(0));
    expect(rect.top, closeTo(1024 - rect.bottom, 0.001));
    expect(transform.normalize(rect.center), const Offset(0.5, 0.5));
  });

  test('centers content inside an offset usable viewport', () {
    final transform = RemoteContentTransform.forViewport(
      sourceSize: const Size(16, 10),
      viewportSize: const Size(800, 500),
      viewportOffset: const Offset(0, 80),
      fit: BoxFit.contain,
    );

    expect(transform.destinationRect, const Rect.fromLTWH(0, 80, 800, 500));
    expect(transform.normalize(const Offset(400, 330)), const Offset(.5, .5));
    expect(transform.normalize(const Offset(400, 40)), isNull);
  });

  test('maps direct touch through the encoded active-content rectangle', () {
    final transform = RemoteContentTransform.forViewport(
      sourceSize: const Size(1920, 1080),
      activeContentRect: const Rect.fromLTWH(160, 108, 1600, 864),
      viewportSize: const Size(1000, 540),
      fit: BoxFit.contain,
    );

    expect(transform.destinationRect, const Rect.fromLTWH(0, 0, 1000, 540));
    expect(transform.normalize(const Offset(500, 270)), const Offset(.5, .5));
    expect(transform.normalize(const Offset(0, 270))!.dx, closeTo(0, 0.0001));
    expect(
      transform.normalize(const Offset(999.999, 270))!.dx,
      closeTo(1, 0.0001),
    );
  });
}
