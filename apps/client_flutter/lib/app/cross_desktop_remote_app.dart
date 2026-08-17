import 'package:cross_desktop_remote/app/routes.dart';
import 'package:cross_desktop_remote/app/theme.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:flutter/material.dart';

class CrossDesktopRemoteApp extends StatelessWidget {
  const CrossDesktopRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CrossDesktopRemote',
      debugShowCheckedModeBanner: false,
      scaffoldMessengerKey: AppMessenger.scaffoldMessengerKey,
      theme: CrossDesktopTheme.light(),
      darkTheme: CrossDesktopTheme.dark(),
      themeMode: ThemeMode.system,
      initialRoute: AppRoutes.home,
      routes: AppRoutes.routes,
    );
  }
}

typedef MainApp = CrossDesktopRemoteApp;
