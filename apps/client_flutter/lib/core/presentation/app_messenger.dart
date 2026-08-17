import 'package:flutter/material.dart';

enum AppMessageLevel { info, success, warning, error }

abstract final class AppMessenger {
  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();

  static void show(
    String message, {
    AppMessageLevel level = AppMessageLevel.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final messenger = scaffoldMessengerKey.currentState;
    final context = scaffoldMessengerKey.currentContext;
    if (messenger == null || context == null || message.trim().isEmpty) {
      return;
    }
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = switch (level) {
      AppMessageLevel.info => (
        scheme.inverseSurface,
        scheme.onInverseSurface,
        Icons.info_outline,
      ),
      AppMessageLevel.success => (
        const Color(0xFF166534),
        Colors.white,
        Icons.check_circle_outline,
      ),
      AppMessageLevel.warning => (
        const Color(0xFF92400E),
        Colors.white,
        Icons.warning_amber_outlined,
      ),
      AppMessageLevel.error => (
        scheme.error,
        scheme.onError,
        Icons.error_outline,
      ),
    };

    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          backgroundColor: background,
          duration: level == AppMessageLevel.error
              ? const Duration(seconds: 6)
              : const Duration(seconds: 3),
          content: Semantics(
            liveRegion: true,
            child: Row(
              children: [
                Icon(icon, color: foreground, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(message, style: TextStyle(color: foreground)),
                ),
              ],
            ),
          ),
          action: actionLabel != null && onAction != null
              ? SnackBarAction(
                  label: actionLabel,
                  textColor: foreground,
                  onPressed: onAction,
                )
              : null,
        ),
      );
  }
}
