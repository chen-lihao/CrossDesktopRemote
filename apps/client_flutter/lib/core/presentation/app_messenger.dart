import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

enum AppMessageLevel { info, success, warning, error }

abstract final class AppMessenger {
  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static OverlayEntry? _entry;
  static Timer? _dismissTimer;

  static void show(
    String message, {
    AppMessageLevel level = AppMessageLevel.info,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final overlay = navigatorKey.currentState?.overlay;
    if (overlay == null || message.trim().isEmpty) {
      return;
    }

    dismiss();
    _entry = OverlayEntry(
      builder: (context) => _AppMessageOverlay(
        message: message.trim(),
        level: level,
        actionLabel: actionLabel,
        onAction: onAction == null
            ? null
            : () {
                dismiss();
                onAction();
              },
      ),
    );
    overlay.insert(_entry!);
    _dismissTimer = Timer(
      level == AppMessageLevel.error
          ? const Duration(seconds: 6)
          : const Duration(seconds: 3),
      dismiss,
    );
  }

  static void dismiss() {
    _dismissTimer?.cancel();
    _dismissTimer = null;
    _entry?.remove();
    _entry = null;
  }
}

class _AppMessageOverlay extends StatelessWidget {
  const _AppMessageOverlay({
    required this.message,
    required this.level,
    this.actionLabel,
    this.onAction,
  });

  final String message;
  final AppMessageLevel level;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
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
    final top = math.max(media.padding.top + 12, media.size.height * 0.17);

    return Positioned(
      key: const ValueKey('app-message-overlay'),
      top: top,
      left: 16,
      right: 16,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: Material(
              color: background,
              elevation: 10,
              shadowColor: Colors.black45,
              borderRadius: BorderRadius.circular(14),
              child: Semantics(
                liveRegion: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(icon, color: foreground, size: 20),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          message,
                          style: TextStyle(color: foreground),
                        ),
                      ),
                      if (actionLabel != null && onAction != null) ...[
                        const SizedBox(width: 8),
                        TextButton(
                          onPressed: onAction,
                          style: TextButton.styleFrom(
                            foregroundColor: foreground,
                          ),
                          child: Text(actionLabel!),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
