import 'dart:collection';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

enum AppMessageLevel { info, success, warning, error }

enum AppNotificationCategory {
  general,
  connection,
  display,
  clipboard,
  transfer,
  security,
}

@immutable
class AppNotificationScope {
  const AppNotificationScope(this.id);

  static const main = AppNotificationScope('main');
  static const remoteDesktop = AppNotificationScope('remote-desktop');

  final String id;

  @override
  bool operator ==(Object other) =>
      other is AppNotificationScope && other.id == id;

  @override
  int get hashCode => id.hashCode;
}

@immutable
class AppNotificationAction {
  const AppNotificationAction({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;
}

@immutable
class AppNotification {
  const AppNotification({
    required this.id,
    required this.message,
    this.category = AppNotificationCategory.general,
    this.severity = AppMessageLevel.info,
    this.dedupeKey,
    this.duration,
    this.scope = AppNotificationScope.main,
    this.action,
  });

  final String id;
  final String message;
  final AppNotificationCategory category;
  final AppMessageLevel severity;
  final String? dedupeKey;
  final Duration? duration;
  final AppNotificationScope scope;
  final AppNotificationAction? action;

  Duration get effectiveDuration =>
      duration ??
      switch (severity) {
        AppMessageLevel.info ||
        AppMessageLevel.success => const Duration(seconds: 3),
        AppMessageLevel.warning => const Duration(seconds: 5),
        AppMessageLevel.error => const Duration(seconds: 8),
      };
}

/// Owns short-lived application feedback independently for every Flutter view.
///
/// Only one notification is presented per scope. Remaining notifications stay
/// in FIFO order and are not allowed to dismiss the active one. Persistent
/// operation progress deliberately lives outside this queue.
class AppNotificationCenter {
  AppNotificationCenter._();

  static final instance = AppNotificationCenter._();

  static const _dedupeWindow = Duration(seconds: 1);

  final Map<AppNotificationScope, Queue<AppNotification>> _queues = {};
  final Map<
    AppNotificationScope,
    ScaffoldFeatureController<SnackBar, SnackBarClosedReason>
  >
  _active = {};
  final Map<AppNotificationScope, GlobalKey<ScaffoldMessengerState>>
  _messengerKeys = {};
  final Map<String, DateTime> _lastPresentedByDedupeKey = {};
  final Set<AppNotificationScope> _scheduledScopes = {};

  @visibleForTesting
  int pendingCount(AppNotificationScope scope) => _queues[scope]?.length ?? 0;

  @visibleForTesting
  bool hasPresenter(AppNotificationScope scope) =>
      _messengerKeys[scope]?.currentState != null;

  @visibleForTesting
  bool hasActiveNotification(AppNotificationScope scope) =>
      _active.containsKey(scope);

  void register(
    AppNotificationScope scope,
    GlobalKey<ScaffoldMessengerState> messengerKey,
  ) {
    _messengerKeys[scope] = messengerKey;
    _schedulePresentation(scope);
  }

  void unregister(
    AppNotificationScope scope,
    GlobalKey<ScaffoldMessengerState> messengerKey, {
    bool clearPending = false,
  }) {
    if (!identical(_messengerKeys[scope], messengerKey)) return;
    messengerKey.currentState?.clearSnackBars();
    _messengerKeys.remove(scope);
    _active.remove(scope);
    if (clearPending) _queues.remove(scope);
  }

  void enqueue(AppNotification notification) {
    final message = notification.message.trim();
    if (message.isEmpty) return;
    final normalized = AppNotification(
      id: notification.id,
      message: message,
      category: notification.category,
      severity: notification.severity,
      dedupeKey: notification.dedupeKey,
      duration: notification.duration,
      scope: notification.scope,
      action: notification.action,
    );
    final now = DateTime.now();
    _lastPresentedByDedupeKey.removeWhere(
      (_, presentedAt) => now.difference(presentedAt) >= _dedupeWindow,
    );
    final dedupeKey =
        normalized.dedupeKey ??
        '${normalized.scope.id}:${normalized.category.name}:$message';
    final lastPresented = _lastPresentedByDedupeKey[dedupeKey];
    if (lastPresented != null &&
        now.difference(lastPresented) < _dedupeWindow) {
      return;
    }
    _lastPresentedByDedupeKey[dedupeKey] = now;
    _queues.putIfAbsent(normalized.scope, Queue.new).add(normalized);
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.idle &&
        _messengerKeys[normalized.scope]?.currentState != null) {
      _presentNext(normalized.scope);
    } else {
      _schedulePresentation(normalized.scope);
    }
  }

  void clear(AppNotificationScope scope) {
    _queues.remove(scope);
    _messengerKeys[scope]?.currentState?.clearSnackBars();
    _active.remove(scope);
  }

  void reset() {
    for (final key in _messengerKeys.values) {
      key.currentState?.clearSnackBars();
    }
    _queues.clear();
    _active.clear();
    _lastPresentedByDedupeKey.clear();
    _scheduledScopes.clear();
  }

  void _schedulePresentation(AppNotificationScope scope) {
    if (!_scheduledScopes.add(scope)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduledScopes.remove(scope);
      _presentNext(scope);
    });
  }

  void _presentNext(AppNotificationScope scope) {
    if (_active.containsKey(scope)) return;
    final messenger = _messengerKeys[scope]?.currentState;
    final queue = _queues[scope];
    if (messenger == null || queue == null || queue.isEmpty) return;

    final notification = queue.removeFirst();
    final controller = messenger.showSnackBar(
      _buildSnackBar(notification, messenger.context),
    );
    _active[scope] = controller;
    controller.closed.whenComplete(() {
      if (identical(_active[scope], controller)) {
        _active.remove(scope);
      }
      _schedulePresentation(scope);
    });
  }

  SnackBar _buildSnackBar(AppNotification notification, BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground, icon) = switch (notification.severity) {
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
    final action = notification.action;
    return SnackBar(
      key: ValueKey('app-notification-${notification.id}'),
      behavior: SnackBarBehavior.floating,
      duration: notification.effectiveDuration,
      backgroundColor: background,
      showCloseIcon: action == null,
      closeIconColor: foreground,
      content: Semantics(
        liveRegion: true,
        child: Row(
          children: [
            Icon(icon, color: foreground, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                notification.message,
                style: TextStyle(color: foreground),
              ),
            ),
          ],
        ),
      ),
      action: action == null
          ? null
          : SnackBarAction(
              label: action.label,
              textColor: foreground,
              onPressed: action.onPressed,
            ),
    );
  }
}

class AppNotificationPresenter extends StatefulWidget {
  const AppNotificationPresenter({
    super.key,
    required this.scope,
    required this.child,
    this.messengerKey,
    this.clearOnDispose = false,
  });

  final AppNotificationScope scope;
  final Widget child;
  final GlobalKey<ScaffoldMessengerState>? messengerKey;
  final bool clearOnDispose;

  static AppNotificationScope? maybeScopeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<_AppNotificationScopeMarker>()
      ?.scope;

  @override
  State<AppNotificationPresenter> createState() =>
      _AppNotificationPresenterState();
}

class _AppNotificationPresenterState extends State<AppNotificationPresenter> {
  late final GlobalKey<ScaffoldMessengerState> _ownedKey;

  GlobalKey<ScaffoldMessengerState> get _messengerKey =>
      widget.messengerKey ?? _ownedKey;

  @override
  void initState() {
    super.initState();
    _ownedKey = GlobalKey<ScaffoldMessengerState>(
      debugLabel: 'notifications-${widget.scope.id}',
    );
    AppNotificationCenter.instance.register(widget.scope, _messengerKey);
  }

  @override
  void didUpdateWidget(AppNotificationPresenter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scope == widget.scope &&
        identical(oldWidget.messengerKey, widget.messengerKey)) {
      return;
    }
    final oldKey = oldWidget.messengerKey ?? _ownedKey;
    AppNotificationCenter.instance.unregister(oldWidget.scope, oldKey);
    AppNotificationCenter.instance.register(widget.scope, _messengerKey);
  }

  @override
  Widget build(BuildContext context) {
    final markedChild = _AppNotificationScopeMarker(
      scope: widget.scope,
      child: widget.child,
    );
    if (widget.messengerKey != null) return markedChild;
    return ScaffoldMessenger(key: _ownedKey, child: markedChild);
  }

  @override
  void dispose() {
    AppNotificationCenter.instance.unregister(
      widget.scope,
      _messengerKey,
      clearPending: widget.clearOnDispose,
    );
    super.dispose();
  }
}

class _AppNotificationScopeMarker extends InheritedWidget {
  const _AppNotificationScopeMarker({
    required this.scope,
    required super.child,
  });

  final AppNotificationScope scope;

  @override
  bool updateShouldNotify(_AppNotificationScopeMarker oldWidget) =>
      oldWidget.scope != scope;
}

/// Compatibility facade used by existing presentation code.
abstract final class AppMessenger {
  static final scaffoldMessengerKey = GlobalKey<ScaffoldMessengerState>();
  static final navigatorKey = GlobalKey<NavigatorState>();
  static int _nextId = 0;

  static void show(
    String message, {
    AppMessageLevel level = AppMessageLevel.info,
    AppNotificationCategory category = AppNotificationCategory.general,
    String? dedupeKey,
    Duration? duration,
    AppNotificationScope? scope,
    BuildContext? context,
    String? actionLabel,
    VoidCallback? onAction,
  }) {
    final resolvedScope =
        scope ??
        (context == null
            ? null
            : AppNotificationPresenter.maybeScopeOf(context)) ??
        AppNotificationScope.main;
    AppNotificationCenter.instance.enqueue(
      AppNotification(
        id: '${++_nextId}',
        message: message,
        category: category,
        severity: level,
        dedupeKey: dedupeKey,
        duration: duration,
        scope: resolvedScope,
        action: actionLabel == null || onAction == null
            ? null
            : AppNotificationAction(label: actionLabel, onPressed: onAction),
      ),
    );
  }

  static void dismiss({
    AppNotificationScope scope = AppNotificationScope.main,
  }) {
    AppNotificationCenter.instance.clear(scope);
  }

  static void resetForTesting() => AppNotificationCenter.instance.reset();
}
