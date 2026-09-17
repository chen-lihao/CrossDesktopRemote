import 'dart:async';

import 'package:cross_desktop_remote/app/appearance/app_appearance_controller.dart';
import 'package:cross_desktop_remote/app/routes.dart';
import 'package:cross_desktop_remote/app/theme.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:flutter/material.dart';

class CrossDesktopRemoteApp extends StatefulWidget {
  const CrossDesktopRemoteApp({super.key});

  @override
  State<CrossDesktopRemoteApp> createState() => _CrossDesktopRemoteAppState();
}

class _CrossDesktopRemoteAppState extends State<CrossDesktopRemoteApp> {
  final _appearance = AppAppearanceController.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_appearance.load());
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _appearance,
      builder: (context, _) => MaterialApp(
        title: 'CrossDesktopRemote',
        debugShowCheckedModeBanner: false,
        navigatorKey: AppMessenger.navigatorKey,
        scaffoldMessengerKey: AppMessenger.scaffoldMessengerKey,
        builder: (context, child) => AppNotificationPresenter(
          scope: AppNotificationScope.main,
          messengerKey: AppMessenger.scaffoldMessengerKey,
          child: child ?? const SizedBox.shrink(),
        ),
        theme: CrossDesktopTheme.light(),
        darkTheme: CrossDesktopTheme.dark(),
        themeMode: _appearance.themeMode,
        themeAnimationDuration: const Duration(milliseconds: 220),
        themeAnimationCurve: Curves.easeOutCubic,
        initialRoute: AppRoutes.home,
        routes: AppRoutes.routes,
      ),
    );
  }
}

typedef MainApp = CrossDesktopRemoteApp;
