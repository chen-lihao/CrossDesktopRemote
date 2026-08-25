import 'package:flutter/painting.dart';

Size resolveRemotePresentationSourceSize({
  required Size rendererSize,
  required Size fallbackSize,
  Size? committedSize,
  required bool geometryLocked,
}) {
  // A display-switch transaction explicitly commits the renderer geometry.
  // Keep that snapshot authoritative until the next transaction so a stale or
  // transitional native resize notification cannot change both the canvas and
  // direct-touch mapping outside the switch overlay.
  if (committedSize != null && !committedSize.isEmpty) {
    return committedSize;
  }
  if (geometryLocked) return fallbackSize;
  if (!rendererSize.isEmpty) return rendererSize;
  return fallbackSize;
}

bool remoteAspectRatiosDiffer(
  Size first,
  Size second, {
  double tolerance = 0.015,
}) {
  if (first.isEmpty || second.isEmpty) return false;
  final ratio = first.aspectRatio / second.aspectRatio;
  return (ratio - 1).abs() > tolerance;
}

class RemoteContentTransform {
  const RemoteContentTransform({
    required this.sourceSize,
    required this.sourceRect,
    required this.destinationRect,
  });

  factory RemoteContentTransform.forViewport({
    required Size sourceSize,
    required Size viewportSize,
    required BoxFit fit,
    Offset viewportOffset = Offset.zero,
  }) {
    if (sourceSize.isEmpty || viewportSize.isEmpty) {
      return RemoteContentTransform(
        sourceSize: sourceSize,
        sourceRect: Rect.zero,
        destinationRect: Rect.zero,
      );
    }
    final fitted = applyBoxFit(fit, sourceSize, viewportSize);
    return RemoteContentTransform(
      sourceSize: sourceSize,
      sourceRect: Alignment.center.inscribe(
        fitted.source,
        Offset.zero & sourceSize,
      ),
      destinationRect: Alignment.center.inscribe(
        fitted.destination,
        viewportOffset & viewportSize,
      ),
    );
  }

  final Size sourceSize;
  final Rect sourceRect;
  final Rect destinationRect;

  Offset? normalize(Offset viewportPosition) {
    if (sourceRect.isEmpty ||
        destinationRect.isEmpty ||
        !destinationRect.contains(viewportPosition)) {
      return null;
    }
    final destinationX =
        (viewportPosition.dx - destinationRect.left) / destinationRect.width;
    final destinationY =
        (viewportPosition.dy - destinationRect.top) / destinationRect.height;
    return Offset(
      (sourceRect.left + sourceRect.width * destinationX) / sourceSize.width,
      (sourceRect.top + sourceRect.height * destinationY) / sourceSize.height,
    );
  }
}
