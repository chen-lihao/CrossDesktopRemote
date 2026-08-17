import 'package:cross_desktop_remote/features/home/presentation/home_shell.dart';
import 'package:flutter/widgets.dart';

abstract final class AppRoutes {
  static const home = '/';

  static final Map<String, WidgetBuilder> routes = {
    home: (_) => const HomeShell(),
  };
}
