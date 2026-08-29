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
    required this.activeContentRect,
  });

  factory RemoteContentTransform.forViewport({
    required Size sourceSize,
    required Size viewportSize,
    required BoxFit fit,
    Rect? activeContentRect,
    Offset viewportOffset = Offset.zero,
  }) {
    if (sourceSize.isEmpty || viewportSize.isEmpty) {
      return RemoteContentTransform(
        sourceSize: sourceSize,
        sourceRect: Rect.zero,
        destinationRect: Rect.zero,
        activeContentRect: Rect.zero,
      );
    }
    final sourceBounds = Offset.zero & sourceSize;
    final requestedActiveRect = activeContentRect ?? sourceBounds;
    final activeRect = requestedActiveRect.intersect(sourceBounds);
    if (activeRect.isEmpty) {
      return RemoteContentTransform(
        sourceSize: sourceSize,
        sourceRect: Rect.zero,
        destinationRect: Rect.zero,
        activeContentRect: Rect.zero,
      );
    }
    final fitted = applyBoxFit(fit, activeRect.size, viewportSize);
    final fittedSourceRect = Alignment.center.inscribe(
      fitted.source,
      Offset.zero & activeRect.size,
    );
    return RemoteContentTransform(
      sourceSize: sourceSize,
      sourceRect: fittedSourceRect.shift(activeRect.topLeft),
      destinationRect: Alignment.center.inscribe(
        fitted.destination,
        viewportOffset & viewportSize,
      ),
      activeContentRect: activeRect,
    );
  }

  final Size sourceSize;
  final Rect sourceRect;
  final Rect destinationRect;
  final Rect activeContentRect;

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
    final sourceX = sourceRect.left + sourceRect.width * destinationX;
    final sourceY = sourceRect.top + sourceRect.height * destinationY;
    return Offset(
      (sourceX - activeContentRect.left) / activeContentRect.width,
      (sourceY - activeContentRect.top) / activeContentRect.height,
    );
  }
}

/// Layout for painting the complete decoder texture behind a clipped viewport
/// so [visibleSourceRect] is the only visible portion. This keeps native
/// decoder textures on Windows and iOS on the exact same geometry contract as
/// absolute pointer input, without a second renderer-owned aspect fit.
class RemoteTextureCropLayout {
  const RemoteTextureCropLayout({required this.fullTextureRect});

  factory RemoteTextureCropLayout.forViewport({
    required Size encodedSize,
    required Rect visibleSourceRect,
    required Size viewportSize,
  }) {
    if (encodedSize.isEmpty ||
        visibleSourceRect.isEmpty ||
        viewportSize.isEmpty) {
      return const RemoteTextureCropLayout(fullTextureRect: Rect.zero);
    }
    final encodedBounds = Offset.zero & encodedSize;
    final visible = visibleSourceRect.intersect(encodedBounds);
    if (visible.isEmpty) {
      return const RemoteTextureCropLayout(fullTextureRect: Rect.zero);
    }
    final scaleX = viewportSize.width / visible.width;
    final scaleY = viewportSize.height / visible.height;
    return RemoteTextureCropLayout(
      fullTextureRect: Rect.fromLTWH(
        -visible.left * scaleX,
        -visible.top * scaleY,
        encodedSize.width * scaleX,
        encodedSize.height * scaleY,
      ),
    );
  }

  final Rect fullTextureRect;
}
