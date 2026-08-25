import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter/foundation.dart';

enum RemoteKeyboardMode {
  compact,
  system;

  String get label => switch (this) {
    RemoteKeyboardMode.compact => '快捷小键盘',
    RemoteKeyboardMode.system => '系统完整键盘',
  };
}

@immutable
class RemoteInputSettings {
  const RemoteInputSettings({
    this.pointerMode = RemotePointerMode.touchpad,
    this.pointerSensitivity = 1.25,
    this.scrollSensitivity = 2,
    this.dragLock = false,
    this.keyboardMode = RemoteKeyboardMode.system,
  });

  final RemotePointerMode pointerMode;
  final double pointerSensitivity;
  final double scrollSensitivity;
  final bool dragLock;
  final RemoteKeyboardMode keyboardMode;

  RemoteInputSettings copyWith({
    RemotePointerMode? pointerMode,
    double? pointerSensitivity,
    double? scrollSensitivity,
    bool? dragLock,
    RemoteKeyboardMode? keyboardMode,
  }) => RemoteInputSettings(
    pointerMode: pointerMode ?? this.pointerMode,
    pointerSensitivity: pointerSensitivity ?? this.pointerSensitivity,
    scrollSensitivity: scrollSensitivity ?? this.scrollSensitivity,
    dragLock: dragLock ?? this.dragLock,
    keyboardMode: keyboardMode ?? this.keyboardMode,
  );
}
