import 'package:cross_desktop_remote/app/cross_desktop_remote_app.dart';
import 'package:cross_desktop_remote/app/desktop_windowing_root.dart';
import 'package:flutter/widgets.dart';

export 'package:cross_desktop_remote/app/cross_desktop_remote_app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(buildDesktopWindowingRoot(const CrossDesktopRemoteApp()));
}
