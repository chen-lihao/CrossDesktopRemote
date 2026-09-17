import 'dart:async';
import 'dart:collection';

import 'package:cross_desktop_remote/app/design_system/app_design_tokens.dart';
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

/// Owns short-lived feedback independently for every Flutter view.
///
/// Up to four notifications are visible together. Additional items wait in a
/// bounded visual queue, so bursts remain readable without covering the whole
/// workspace. Persistent operation progress deliberately lives in page state
/// or an operation banner rather than this transient stack.
class AppNotificationCenter {
  AppNotificationCenter._();

  static final instance = AppNotificationCenter._();

  static const _dedupeWindow = Duration(seconds: 1);
  static const maxVisibleNotifications = 4;

  final Map<AppNotificationScope, Queue<AppNotification>> _queues = {};
  final Map<AppNotificationScope, List<AppNotification>> _active = {};
  final Map<AppNotificationScope, Set<GlobalKey<ScaffoldMessengerState>>>
  _presenters = {};
  final Map<AppNotificationScope, ValueNotifier<int>> _revisions = {};
  final Map<String, Timer> _dismissTimers = {};
  final Map<String, DateTime> _lastPresentedByDedupeKey = {};
  final Set<AppNotificationScope> _scheduledScopes = {};

  Listenable listenable(AppNotificationScope scope) =>
      _revisions.putIfAbsent(scope, () => ValueNotifier<int>(0));

  List<AppNotification> activeNotifications(AppNotificationScope scope) =>
      List.unmodifiable(_active[scope] ?? const <AppNotification>[]);

  @visibleForTesting
  int pendingCount(AppNotificationScope scope) => _queues[scope]?.length ?? 0;

  @visibleForTesting
  int activeCount(AppNotificationScope scope) => _active[scope]?.length ?? 0;

  @visibleForTesting
  bool hasPresenter(AppNotificationScope scope) =>
      _presenters[scope]?.isNotEmpty ?? false;

  @visibleForTesting
  bool hasActiveNotification(AppNotificationScope scope) =>
      _active[scope]?.isNotEmpty ?? false;

  void register(
    AppNotificationScope scope,
    GlobalKey<ScaffoldMessengerState> presenterKey,
  ) {
    _presenters.putIfAbsent(scope, () => {}).add(presenterKey);
    _fillVisibleSlots(scope);
  }

  void unregister(
    AppNotificationScope scope,
    GlobalKey<ScaffoldMessengerState> presenterKey, {
    bool clearPending = false,
  }) {
    final presenters = _presenters[scope];
    presenters?.remove(presenterKey);
    if (presenters != null && presenters.isEmpty) {
      _presenters.remove(scope);
    }
    if (clearPending) {
      clear(scope);
      return;
    }
    if (hasPresenter(scope)) return;

    final displayed = _active.remove(scope) ?? const <AppNotification>[];
    final queue = _queues.putIfAbsent(scope, Queue.new);
    for (final notification in displayed.reversed) {
      _cancelTimer(notification);
      queue.addFirst(notification);
    }
    _notify(scope);
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
    _fillVisibleSlots(normalized.scope);
  }

  void dismiss(AppNotificationScope scope, String notificationId) {
    final active = _active[scope];
    if (active == null) return;
    final index = active.indexWhere((item) => item.id == notificationId);
    if (index < 0) return;
    final notification = active.removeAt(index);
    _cancelTimer(notification);
    _notify(scope);
    _fillVisibleSlots(scope);
  }

  void clear(AppNotificationScope scope) {
    _queues.remove(scope);
    final active = _active.remove(scope) ?? const <AppNotification>[];
    for (final notification in active) {
      _cancelTimer(notification);
    }
    _notify(scope);
  }

  void reset() {
    for (final timer in _dismissTimers.values) {
      timer.cancel();
    }
    final scopes = <AppNotificationScope>{
      ..._queues.keys,
      ..._active.keys,
      ..._revisions.keys,
    };
    _dismissTimers.clear();
    _queues.clear();
    _active.clear();
    _lastPresentedByDedupeKey.clear();
    _scheduledScopes.clear();
    for (final scope in scopes) {
      _notify(scope);
    }
  }

  void _fillVisibleSlots(AppNotificationScope scope) {
    if (!hasPresenter(scope)) return;
    final queue = _queues[scope];
    if (queue == null || queue.isEmpty) return;
    final active = _active.putIfAbsent(scope, () => []);
    var changed = false;
    while (active.length < maxVisibleNotifications && queue.isNotEmpty) {
      final notification = queue.removeFirst();
      active.add(notification);
      _dismissTimers[_timerKey(notification)] = Timer(
        notification.effectiveDuration,
        () => dismiss(scope, notification.id),
      );
      changed = true;
    }
    if (changed) _notify(scope);
  }

  void _cancelTimer(AppNotification notification) {
    _dismissTimers.remove(_timerKey(notification))?.cancel();
  }

  String _timerKey(AppNotification notification) =>
      '${notification.scope.id}:${notification.id}';

  void _notify(AppNotificationScope scope) {
    final notifier = _revisions.putIfAbsent(scope, () => ValueNotifier<int>(0));
    final phase = SchedulerBinding.instance.schedulerPhase;
    if (phase == SchedulerPhase.idle ||
        phase == SchedulerPhase.postFrameCallbacks) {
      notifier.value++;
      return;
    }
    if (!_scheduledScopes.add(scope)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduledScopes.remove(scope);
      notifier.value++;
    });
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
    final center = AppNotificationCenter.instance;
    final layered = _AppNotificationScopeMarker(
      scope: widget.scope,
      child: Stack(
        fit: StackFit.expand,
        children: [
          widget.child,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              minimum: const EdgeInsets.fromLTRB(
                AppSpacing.sm,
                AppSpacing.md,
                AppSpacing.sm,
                0,
              ),
              child: AnimatedBuilder(
                animation: center.listenable(widget.scope),
                builder: (context, _) {
                  final notifications = center.activeNotifications(
                    widget.scope,
                  );
                  if (notifications.isEmpty) {
                    return const IgnorePointer(child: SizedBox.shrink());
                  }
                  return Align(
                    alignment: Alignment.topCenter,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: AnimatedSize(
                        duration: AppMotion.standard,
                        curve: AppMotion.standardCurve,
                        alignment: Alignment.topCenter,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (
                              var index = 0;
                              index < notifications.length;
                              index++
                            ) ...[
                              if (index > 0)
                                const SizedBox(height: AppSpacing.xs),
                              _AppNotificationCard(
                                key: ValueKey(
                                  'app-notification-${notifications[index].id}',
                                ),
                                notification: notifications[index],
                                onDismiss: () => center.dismiss(
                                  widget.scope,
                                  notifications[index].id,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
    if (widget.messengerKey != null) return layered;
    return ScaffoldMessenger(key: _ownedKey, child: layered);
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

class _AppNotificationCard extends StatelessWidget {
  const _AppNotificationCard({
    super.key,
    required this.notification,
    required this.onDismiss,
  });

  final AppNotification notification;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final visual = context.visualTheme;
    final (tone, icon) = switch (notification.severity) {
      AppMessageLevel.info => (visual.info, Icons.info_outline_rounded),
      AppMessageLevel.success => (
        visual.success,
        Icons.check_circle_outline_rounded,
      ),
      AppMessageLevel.warning => (visual.warning, Icons.warning_amber_rounded),
      AppMessageLevel.error => (scheme.error, Icons.error_outline_rounded),
    };
    final background = Color.alphaBlend(
      tone.withValues(alpha: theme.brightness == Brightness.dark ? .11 : .07),
      scheme.surfaceContainerHigh,
    );

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: AppMotion.standard,
      curve: AppMotion.standardCurve,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, -8 * (1 - value)),
          child: child,
        ),
      ),
      child: Material(
        color: background,
        elevation: 8,
        shadowColor: tone.withValues(alpha: .20),
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.inner),
          side: BorderSide(color: tone.withValues(alpha: .30)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: tone.withValues(alpha: .13),
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Icon(icon, color: tone, size: AppIconSizes.medium),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    notification.message,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (notification.action case final action?) ...[
                  const SizedBox(width: AppSpacing.xs),
                  TextButton(
                    onPressed: () {
                      action.onPressed();
                      onDismiss();
                    },
                    style: TextButton.styleFrom(foregroundColor: tone),
                    child: Text(action.label),
                  ),
                ],
                Semantics(
                  button: true,
                  label: '关闭消息',
                  child: IconButton(
                    onPressed: onDismiss,
                    icon: const Icon(Icons.close_rounded),
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
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
