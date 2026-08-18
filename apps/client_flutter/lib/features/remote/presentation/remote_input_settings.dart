import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter/foundation.dart';

@immutable
class RemoteInputSettings {
  const RemoteInputSettings({
    this.pointerMode = RemotePointerMode.touchpad,
    this.pointerSensitivity = 1.25,
    this.scrollSensitivity = 2,
    this.dragLock = false,
  });

  final RemotePointerMode pointerMode;
  final double pointerSensitivity;
  final double scrollSensitivity;
  final bool dragLock;

  RemoteInputSettings copyWith({
    RemotePointerMode? pointerMode,
    double? pointerSensitivity,
    double? scrollSensitivity,
    bool? dragLock,
  }) => RemoteInputSettings(
    pointerMode: pointerMode ?? this.pointerMode,
    pointerSensitivity: pointerSensitivity ?? this.pointerSensitivity,
    scrollSensitivity: scrollSensitivity ?? this.scrollSensitivity,
    dragLock: dragLock ?? this.dragLock,
  );
}
