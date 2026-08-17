import 'package:flutter/painting.dart';

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
        Offset.zero & viewportSize,
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
