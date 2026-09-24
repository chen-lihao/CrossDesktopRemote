import 'dart:async';
import 'dart:ui';

import 'package:cross_desktop_remote/app/cross_desktop_remote_app.dart';
import 'package:cross_desktop_remote/app/desktop_windowing_root.dart';
import 'package:cross_desktop_remote/core/diagnostics/diagnostic_hub.dart';
import 'package:flutter/widgets.dart';

export 'package:cross_desktop_remote/app/cross_desktop_remote_app.dart';

Future<void> main() async {
  final diagnostics = DiagnosticHub.instance;
  await runZonedGuarded<Future<void>>(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        diagnostics.recordError(
          component: 'flutter.framework',
          name: 'uncaught_framework_error',
          error: details.exception,
          stackTrace: details.stack ?? StackTrace.current,
          errorCode: 'CDR-FLUTTER-001',
          fatal: false,
        );
      };
      PlatformDispatcher.instance.onError = (error, stackTrace) {
        diagnostics.recordError(
          component: 'flutter.platform_dispatcher',
          name: 'uncaught_async_error',
          error: error,
          stackTrace: stackTrace,
          errorCode: 'CDR-FLUTTER-002',
          fatal: true,
        );
        return true;
      };
      // Diagnostics must never become an application-startup gate. Events
      // emitted before storage is ready are buffered by DiagnosticHub.
      unawaited(diagnostics.initialize());
      runApp(buildDesktopWindowingRoot(const CrossDesktopRemoteApp()));
    },
    (error, stackTrace) {
      diagnostics.recordError(
        component: 'dart.zone',
        name: 'uncaught_zone_error',
        error: error,
        stackTrace: stackTrace,
        errorCode: 'CDR-DART-001',
        fatal: true,
      );
    },
  );
}
