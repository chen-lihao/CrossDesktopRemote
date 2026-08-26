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

enum RemoteTextInputMode {
  localIme,
  remoteIme;

  String get label => switch (this) {
    RemoteTextInputMode.localIme => '本机输入法',
    RemoteTextInputMode.remoteIme => '被控端输入法',
  };

  String get description => switch (this) {
    RemoteTextInputMode.localIme => '本机选词后发送 Unicode 文本',
    RemoteTextInputMode.remoteIme => '发送物理按键，由被控端系统输入法选词',
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
    this.textInputMode = RemoteTextInputMode.localIme,
  });

  final RemotePointerMode pointerMode;
  final double pointerSensitivity;
  final double scrollSensitivity;
  final bool dragLock;
  final RemoteKeyboardMode keyboardMode;
  final RemoteTextInputMode textInputMode;

  RemoteInputSettings copyWith({
    RemotePointerMode? pointerMode,
    double? pointerSensitivity,
    double? scrollSensitivity,
    bool? dragLock,
    RemoteKeyboardMode? keyboardMode,
    RemoteTextInputMode? textInputMode,
  }) => RemoteInputSettings(
    pointerMode: pointerMode ?? this.pointerMode,
    pointerSensitivity: pointerSensitivity ?? this.pointerSensitivity,
    scrollSensitivity: scrollSensitivity ?? this.scrollSensitivity,
    dragLock: dragLock ?? this.dragLock,
    keyboardMode: keyboardMode ?? this.keyboardMode,
    textInputMode: textInputMode ?? this.textInputMode,
  );
}
