import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_geometry.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class RemoteDesktopPanel extends StatefulWidget {
  const RemoteDesktopPanel({super.key, required this.session});

  final RemoteSessionController session;

  @override
  State<RemoteDesktopPanel> createState() => _RemoteDesktopPanelState();
}

class _RemoteDesktopPanelState extends State<RemoteDesktopPanel> {
  final _surfaceKey = GlobalKey<_RemoteDesktopSurfaceState>();
  RemotePointerMode _pointerMode = RemotePointerMode.touchpad;
  RemoteViewFit _viewFit = RemoteViewFit.contain;
  bool _rendererAttached = true;

  Future<void> _openFullScreen() async {
    setState(() => _rendererAttached = false);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _FullScreenRemoteDesktopPage(
          session: widget.session,
          initialPointerMode: _pointerMode,
          initialViewFit: _viewFit,
        ),
      ),
    );
    if (mounted) {
      setState(() => _rendererAttached = true);
      AppMessenger.show('已退出全屏');
    }
  }

  void _setViewFit(RemoteViewFit value) {
    setState(() => _viewFit = value);
    AppMessenger.show(
      value == RemoteViewFit.contain ? '画面模式：完整适应' : '画面模式：填满并裁剪',
      level: AppMessageLevel.success,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.session.remoteRenderer,
      builder: (context, _) {
        final viewportHeight = (MediaQuery.sizeOf(context).height * 0.52)
            .clamp(300.0, 640.0)
            .toDouble();
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: _RemoteToolbar(
                  session: widget.session,
                  pointerMode: _pointerMode,
                  viewFit: _viewFit,
                  onPointerModeChanged: (value) =>
                      setState(() => _pointerMode = value),
                  onViewFitChanged: _setViewFit,
                  onKeyboard: () => _surfaceKey.currentState?.showKeyboard(),
                  onFullScreen: _openFullScreen,
                ),
              ),
              SizedBox(
                height: viewportHeight,
                child: _rendererAttached
                    ? _RemoteDesktopSurface(
                        key: _surfaceKey,
                        session: widget.session,
                        pointerMode: _pointerMode,
                        viewFit: _viewFit,
                      )
                    : const ColoredBox(
                        color: Colors.black,
                        child: Center(child: CircularProgressIndicator()),
                      ),
              ),
              if (widget.session.controlError != null ||
                  widget.session.accessibilityGranted != true)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Icon(
                        Icons.info_outline,
                        color: Theme.of(context).colorScheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.session.controlError ??
                              '当前仅可观看，被控设备尚未允许鼠标和键盘输入。',
                        ),
                      ),
                      TextButton(
                        onPressed: widget.session.refreshRemoteStatus,
                        child: const Text('重新检查'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _FullScreenRemoteDesktopPage extends StatefulWidget {
  const _FullScreenRemoteDesktopPage({
    required this.session,
    required this.initialPointerMode,
    required this.initialViewFit,
  });

  final RemoteSessionController session;
  final RemotePointerMode initialPointerMode;
  final RemoteViewFit initialViewFit;

  @override
  State<_FullScreenRemoteDesktopPage> createState() =>
      _FullScreenRemoteDesktopPageState();
}

class _FullScreenRemoteDesktopPageState
    extends State<_FullScreenRemoteDesktopPage> {
  final _surfaceKey = GlobalKey<_RemoteDesktopSurfaceState>();
  late RemotePointerMode _pointerMode = widget.initialPointerMode;
  late RemoteViewFit _viewFit = widget.initialViewFit;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      AppMessenger.show('已进入全屏，可从顶部工具栏调出远程键盘');
    });
    if (Platform.isIOS || Platform.isAndroid) {
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky),
      );
    }
  }

  @override
  void dispose() {
    if (Platform.isIOS || Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _RemoteDesktopSurface(
              key: _surfaceKey,
              session: widget.session,
              pointerMode: _pointerMode,
              viewFit: _viewFit,
            ),
          ),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            child: SafeArea(
              bottom: false,
              child: ColoredBox(
                color: Colors.black.withValues(alpha: 0.72),
                child: _RemoteToolbar(
                  session: widget.session,
                  pointerMode: _pointerMode,
                  viewFit: _viewFit,
                  leading: IconButton(
                    tooltip: '退出全屏',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                  ),
                  foregroundColor: Colors.white,
                  onPointerModeChanged: (value) =>
                      setState(() => _pointerMode = value),
                  onViewFitChanged: (value) {
                    setState(() => _viewFit = value);
                    AppMessenger.show(
                      value == RemoteViewFit.contain
                          ? '画面模式：完整适应'
                          : '画面模式：填满并裁剪',
                      level: AppMessageLevel.success,
                    );
                  },
                  onKeyboard: () => _surfaceKey.currentState?.showKeyboard(),
                  onFullScreen: () => Navigator.of(context).pop(),
                  isFullScreen: true,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RemoteToolbar extends StatelessWidget {
  const _RemoteToolbar({
    required this.session,
    required this.pointerMode,
    required this.viewFit,
    required this.onPointerModeChanged,
    required this.onViewFitChanged,
    required this.onKeyboard,
    required this.onFullScreen,
    this.leading,
    this.foregroundColor,
    this.isFullScreen = false,
  });

  final RemoteSessionController session;
  final RemotePointerMode pointerMode;
  final RemoteViewFit viewFit;
  final ValueChanged<RemotePointerMode> onPointerModeChanged;
  final ValueChanged<RemoteViewFit> onViewFitChanged;
  final VoidCallback onKeyboard;
  final VoidCallback onFullScreen;
  final Widget? leading;
  final Color? foregroundColor;
  final bool isFullScreen;

  @override
  Widget build(BuildContext context) {
    final selected = session.selectedDisplay;
    final color = foregroundColor ?? Theme.of(context).colorScheme.onSurface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 720;
        return IconTheme(
          data: IconThemeData(color: color),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: color),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  ?leading,
                  PopupMenuButton<String>(
                    enabled: session.displays.isNotEmpty,
                    tooltip: '切换显示器',
                    onSelected: session.selectDisplay,
                    itemBuilder: (context) => [
                      for (final display in session.displays)
                        PopupMenuItem(
                          value: display.id,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              display.id == session.selectedDisplayId
                                  ? Icons.check_circle
                                  : Icons.monitor_outlined,
                            ),
                            title: Text(display.name),
                            subtitle: Text(display.resolutionLabel),
                          ),
                        ),
                    ],
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: compact
                          ? const Icon(Icons.monitor_outlined, size: 20)
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.monitor_outlined, size: 20),
                                const SizedBox(width: 6),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 150,
                                  ),
                                  child: Text(
                                    selected?.name ?? '等待显示器',
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const Icon(Icons.arrow_drop_down),
                              ],
                            ),
                    ),
                  ),
                  const Spacer(),
                  if (!compact)
                    Icon(
                      session.canSendControl
                          ? Icons.mouse_outlined
                          : Icons.visibility_outlined,
                      size: 18,
                      color: session.canSendControl ? Colors.green : color,
                    ),
                  PopupMenuButton<RemotePointerMode>(
                    tooltip: '控制模式',
                    initialValue: pointerMode,
                    onSelected: (value) {
                      onPointerModeChanged(value);
                      AppMessenger.show(
                        value == RemotePointerMode.touchpad
                            ? '已切换为触控板模式'
                            : '已切换为直接触控模式',
                        level: AppMessageLevel.success,
                      );
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: RemotePointerMode.touchpad,
                        child: Text('触控板模式'),
                      ),
                      PopupMenuItem(
                        value: RemotePointerMode.direct,
                        child: Text('直接触控模式'),
                      ),
                    ],
                    icon: Icon(
                      pointerMode == RemotePointerMode.touchpad
                          ? Icons.touch_app_outlined
                          : Icons.ads_click_outlined,
                    ),
                  ),
                  IconButton(
                    tooltip: viewFit == RemoteViewFit.contain
                        ? '填满并裁剪'
                        : '完整适应',
                    onPressed: () => onViewFitChanged(
                      viewFit == RemoteViewFit.contain
                          ? RemoteViewFit.cover
                          : RemoteViewFit.contain,
                    ),
                    icon: Icon(
                      viewFit == RemoteViewFit.contain
                          ? Icons.fit_screen_outlined
                          : Icons.crop_free,
                    ),
                  ),
                  PopupMenuButton<RemoteQualityProfile>(
                    enabled: !session.qualityPending,
                    tooltip: '传输清晰度：${session.qualityStatusLabel}',
                    initialValue: session.selectedQuality,
                    onSelected: session.selectQuality,
                    itemBuilder: (context) => [
                      for (final profile in RemoteQualityProfile.values)
                        PopupMenuItem(
                          value: profile,
                          child: ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              profile == session.selectedQuality
                                  ? Icons.check_circle
                                  : Icons.high_quality_outlined,
                            ),
                            title: Text(profile.label),
                          ),
                        ),
                    ],
                    icon: session.qualityPending
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.high_quality_outlined),
                  ),
                  IconButton(
                    tooltip: session.canSendControl ? '远程键盘' : '远程键盘（等待输入权限）',
                    onPressed: onKeyboard,
                    icon: const Icon(Icons.keyboard_outlined),
                  ),
                  IconButton(
                    tooltip: '刷新显示器',
                    onPressed: () {
                      session.refreshRemoteDisplays();
                      AppMessenger.show('正在刷新远程显示器');
                    },
                    icon: const Icon(Icons.refresh),
                  ),
                  IconButton(
                    tooltip: isFullScreen ? '退出全屏' : '进入全屏',
                    onPressed: onFullScreen,
                    icon: Icon(
                      isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _RemoteDesktopSurface extends StatefulWidget {
  const _RemoteDesktopSurface({
    super.key,
    required this.session,
    required this.pointerMode,
    required this.viewFit,
  });

  final RemoteSessionController session;
  final RemotePointerMode pointerMode;
  final RemoteViewFit viewFit;

  @override
  State<_RemoteDesktopSurface> createState() => _RemoteDesktopSurfaceState();
}

class _RemoteDesktopSurfaceState extends State<_RemoteDesktopSurface> {
  static const _textSentinel = '\u200B';
  static const _dragThreshold = 7.0;

  final _hardwareFocus = FocusNode(debugLabel: 'remote-hardware-keyboard');
  final _textFocus = FocusNode(debugLabel: 'remote-soft-keyboard');
  late final TextEditingController _textController =
      TextEditingController.fromValue(
        const TextEditingValue(
          text: _textSentinel,
          selection: TextSelection.collapsed(offset: _textSentinel.length),
        ),
      );
  final Map<int, Offset> _activePointers = {};
  final Set<int> _ignoredPointers = {};
  final Map<int, String> _mouseButtons = {};
  Timer? _longPressTimer;
  int? _primaryPointer;
  Offset? _directDownPosition;
  Offset? _lastTapPosition;
  DateTime? _lastTapTime;
  bool _directDragging = false;
  bool _directLongPress = false;
  bool _multiTouchGesture = false;
  bool _trackpadMoved = false;
  bool _keyboardVisible = false;

  RemoteSessionController get session => widget.session;

  void showKeyboard() {
    if (!session.canSendControl) {
      session.explainControlUnavailable();
      return;
    }
    if (!_keyboardVisible) {
      setState(() => _keyboardVisible = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _resetTextInput();
      _textFocus.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    });
    AppMessenger.show('远程键盘已打开，输入内容将发送到远程设备');
  }

  void _hideKeyboard() {
    _textFocus.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    if (mounted) {
      setState(() => _keyboardVisible = false);
    }
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    if (_keyboardVisible) {
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
    _hardwareFocus.dispose();
    _textFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session.remoteRenderer,
      builder: (context, _) => LayoutBuilder(
        builder: (context, constraints) {
          final renderer = session.remoteRenderer.value;
          final display = session.selectedDisplay;
          final sourceSize = renderer.width > 0 && renderer.height > 0
              ? Size(renderer.width, renderer.height)
              : Size(
                  (display?.width ?? 16).toDouble(),
                  (display?.height ?? 10).toDouble(),
                );
          final boxFit = widget.viewFit == RemoteViewFit.contain
              ? BoxFit.contain
              : BoxFit.cover;
          final transform = RemoteContentTransform.forViewport(
            sourceSize: sourceSize,
            viewportSize: constraints.biggest,
            fit: boxFit,
          );
          return Focus(
            focusNode: _hardwareFocus,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) => _pointerDown(event, transform),
              onPointerMove: (event) => _pointerMove(event, transform),
              onPointerUp: (event) => _pointerUp(event, transform),
              onPointerCancel: (event) => _pointerCancel(event, transform),
              onPointerHover: (event) => _pointerHover(event, transform),
              onPointerSignal: (event) => _pointerSignal(event, transform),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  RTCVideoView(
                    session.remoteRenderer,
                    key: ValueKey(widget.viewFit),
                    objectFit: widget.viewFit == RemoteViewFit.contain
                        ? RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
                        : RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                  ),
                  if (_keyboardVisible)
                    Positioned(
                      left: 8,
                      right: 8,
                      bottom: 8,
                      child: SafeArea(
                        top: false,
                        child: Material(
                          elevation: 8,
                          borderRadius: BorderRadius.circular(14),
                          clipBehavior: Clip.antiAlias,
                          child: Focus(
                            onKeyEvent: _handleKeyEvent,
                            child: TextField(
                              focusNode: _textFocus,
                              controller: _textController,
                              autocorrect: false,
                              enableSuggestions: false,
                              maxLines: 1,
                              textInputAction: TextInputAction.send,
                              decoration: InputDecoration(
                                labelText: '远程输入',
                                prefixIcon: const Icon(Icons.keyboard_outlined),
                                suffixIcon: IconButton(
                                  tooltip: '关闭远程键盘',
                                  onPressed: _hideKeyboard,
                                  icon: const Icon(Icons.close),
                                ),
                              ),
                              onChanged: _textChanged,
                              onSubmitted: (_) {
                                _sendSpecialKey('Enter');
                                _resetTextInput();
                                _textFocus.requestFocus();
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  void _pointerDown(PointerDownEvent event, RemoteContentTransform transform) {
    if (!session.canSendControl) {
      session.explainControlUnavailable();
      return;
    }
    _hardwareFocus.requestFocus();
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized = transform.normalize(event.localPosition);
      if (normalized == null) return;
      final button = event.buttons & kSecondaryMouseButton != 0
          ? 'right'
          : 'left';
      _mouseButtons[event.pointer] = button;
      _sendAbsolute('down', normalized, button: button);
      return;
    }

    _activePointers[event.pointer] = event.localPosition;
    if (widget.pointerMode == RemotePointerMode.touchpad) {
      if (_activePointers.length > 1) _multiTouchGesture = true;
      return;
    }
    if (transform.normalize(event.localPosition) == null) {
      _ignoredPointers.add(event.pointer);
      return;
    }
    if (_primaryPointer == null) {
      _primaryPointer = event.pointer;
      _directDownPosition = event.localPosition;
      _startLongPress(transform);
    } else {
      _multiTouchGesture = true;
      _longPressTimer?.cancel();
    }
  }

  void _pointerMove(PointerMoveEvent event, RemoteContentTransform transform) {
    if (_ignoredPointers.contains(event.pointer)) return;
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized = transform.normalize(event.localPosition);
      if (normalized != null) {
        _sendAbsolute(
          'move',
          normalized,
          button: _mouseButtons[event.pointer] ?? 'left',
        );
      }
      return;
    }

    final previous = _activePointers[event.pointer];
    _activePointers[event.pointer] = event.localPosition;
    if (widget.pointerMode == RemotePointerMode.touchpad) {
      if (event.delta.distance > 0.5) _trackpadMoved = true;
      if (_activePointers.length > 1) {
        _multiTouchGesture = true;
        session.sendPointer(
          phase: 'scroll',
          mode: 'relative',
          x: 0.5,
          y: 0.5,
          deltaX: -event.delta.dx * 2,
          deltaY: -event.delta.dy * 2,
        );
      } else {
        session.sendPointer(
          phase: 'move',
          mode: 'relative',
          x: 0.5,
          y: 0.5,
          movementX: event.delta.dx * 1.25,
          movementY: event.delta.dy * 1.25,
        );
      }
      return;
    }
    if (_multiTouchGesture && previous != null) {
      final normalized = transform.normalize(event.localPosition);
      if (normalized != null) {
        session.sendPointer(
          phase: 'scroll',
          x: normalized.dx,
          y: normalized.dy,
          deltaX: -event.delta.dx * 2,
          deltaY: -event.delta.dy * 2,
        );
      }
      return;
    }
    if (event.pointer != _primaryPointer) return;
    final down = _directDownPosition;
    final normalized = transform.normalize(event.localPosition);
    if (down == null || normalized == null) return;
    if (!_directDragging &&
        !_directLongPress &&
        (event.localPosition - down).distance >= _dragThreshold) {
      _longPressTimer?.cancel();
      final initial = transform.normalize(down);
      if (initial != null) {
        _sendAbsolute('down', initial);
        _directDragging = true;
      }
    }
    if (_directDragging || _directLongPress) {
      _sendAbsolute(
        'move',
        normalized,
        button: _directLongPress ? 'right' : 'left',
      );
    }
  }

  void _pointerUp(PointerUpEvent event, RemoteContentTransform transform) {
    if (_ignoredPointers.remove(event.pointer)) {
      _activePointers.remove(event.pointer);
      return;
    }
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized = transform.normalize(event.localPosition);
      final button = _mouseButtons.remove(event.pointer) ?? 'left';
      if (normalized != null) _sendAbsolute('up', normalized, button: button);
      return;
    }

    if (widget.pointerMode == RemotePointerMode.touchpad) {
      _activePointers.remove(event.pointer);
      if (_activePointers.isEmpty) {
        if (!_trackpadMoved) {
          _sendRelativeClick(_multiTouchGesture ? 'right' : 'left');
        }
        _resetGesture();
      }
      return;
    }

    _longPressTimer?.cancel();
    _activePointers.remove(event.pointer);
    if (event.pointer == _primaryPointer && !_multiTouchGesture) {
      final normalized = transform.normalize(event.localPosition);
      if (normalized != null) {
        if (_directDragging) {
          _sendAbsolute('up', normalized);
        } else if (_directLongPress) {
          _sendAbsolute('up', normalized, button: 'right');
        } else {
          final count = _nextClickCount(event.localPosition);
          _sendAbsolute('down', normalized, clickCount: count);
          _sendAbsolute('up', normalized, clickCount: count);
        }
      }
    }
    if (_activePointers.isEmpty) _resetGesture();
  }

  void _pointerCancel(
    PointerCancelEvent event,
    RemoteContentTransform transform,
  ) {
    final normalized = transform.normalize(event.localPosition);
    if (normalized != null && (_directDragging || _directLongPress)) {
      _sendAbsolute(
        'up',
        normalized,
        button: _directLongPress ? 'right' : 'left',
      );
    }
    _activePointers.remove(event.pointer);
    _ignoredPointers.remove(event.pointer);
    _mouseButtons.remove(event.pointer);
    if (_activePointers.isEmpty) _resetGesture();
  }

  void _pointerHover(
    PointerHoverEvent event,
    RemoteContentTransform transform,
  ) {
    final normalized = transform.normalize(event.localPosition);
    if (normalized != null) _sendAbsolute('move', normalized);
  }

  void _pointerSignal(
    PointerSignalEvent event,
    RemoteContentTransform transform,
  ) {
    if (event is! PointerScrollEvent) return;
    final normalized = transform.normalize(event.localPosition);
    if (normalized != null) {
      session.sendPointer(
        phase: 'scroll',
        x: normalized.dx,
        y: normalized.dy,
        deltaX: event.scrollDelta.dx,
        deltaY: event.scrollDelta.dy,
      );
    }
  }

  void _startLongPress(RemoteContentTransform transform) {
    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 550), () {
      final position = _directDownPosition;
      if (position == null || _multiTouchGesture || _directDragging) return;
      final normalized = transform.normalize(position);
      if (normalized != null) {
        _directLongPress = true;
        _sendAbsolute('down', normalized, button: 'right');
      }
    });
  }

  int _nextClickCount(Offset position) {
    final now = DateTime.now();
    final doubleClick =
        _lastTapTime != null &&
        now.difference(_lastTapTime!) < const Duration(milliseconds: 350) &&
        _lastTapPosition != null &&
        (position - _lastTapPosition!).distance < 24;
    _lastTapTime = doubleClick ? null : now;
    _lastTapPosition = doubleClick ? null : position;
    return doubleClick ? 2 : 1;
  }

  void _sendAbsolute(
    String phase,
    Offset normalized, {
    String button = 'left',
    int clickCount = 1,
  }) {
    session.sendPointer(
      phase: phase,
      x: normalized.dx,
      y: normalized.dy,
      button: button,
      clickCount: clickCount,
    );
  }

  void _sendRelativeClick(String button) {
    for (final phase in const ['down', 'up']) {
      session.sendPointer(
        phase: phase,
        mode: 'relative',
        x: 0.5,
        y: 0.5,
        button: button,
      );
    }
  }

  void _resetGesture() {
    _longPressTimer?.cancel();
    _primaryPointer = null;
    _directDownPosition = null;
    _directDragging = false;
    _directLongPress = false;
    _multiTouchGesture = false;
    _trackpadMoved = false;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!session.canSendControl) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final modifiers = <String>[
      if (keyboard.isMetaPressed) 'command',
      if (keyboard.isControlPressed) 'control',
      if (keyboard.isAltPressed) 'option',
      if (keyboard.isShiftPressed) 'shift',
    ];
    final keyName = _remoteKeyName(event.logicalKey);
    final shortcut =
        keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed;
    if (keyName != null &&
        (shortcut || event.character == null || event.character!.isEmpty)) {
      session.sendKey(
        phase: event is KeyUpEvent ? 'up' : 'down',
        key: keyName,
        modifiers: modifiers,
      );
      return KeyEventResult.handled;
    }
    if (!_textFocus.hasFocus && event is KeyDownEvent) {
      final character = event.character;
      if (character != null && character.isNotEmpty) {
        session.sendText(character);
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  void _textChanged(String value) {
    final composing = _textController.value.composing;
    if (composing.isValid && !composing.isCollapsed) return;
    if (value.isEmpty) {
      _sendSpecialKey('Backspace');
    } else {
      final committed = value.startsWith(_textSentinel)
          ? value.substring(_textSentinel.length)
          : value;
      if (committed.isNotEmpty) session.sendText(committed);
    }
    _resetTextInput();
  }

  void _resetTextInput() {
    _textController.value = const TextEditingValue(
      text: _textSentinel,
      selection: TextSelection.collapsed(offset: _textSentinel.length),
    );
  }

  void _sendSpecialKey(String key) {
    session.sendKey(phase: 'down', key: key, modifiers: const []);
    session.sendKey(phase: 'up', key: key, modifiers: const []);
  }

  String? _remoteKeyName(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length == 1 && RegExp('[A-Za-z]').hasMatch(label)) {
      return 'Key${label.toUpperCase()}';
    }
    if (label.length == 1 && RegExp('[0-9]').hasMatch(label)) {
      return 'Digit$label';
    }
    return <LogicalKeyboardKey, String>{
      LogicalKeyboardKey.enter: 'Enter',
      LogicalKeyboardKey.numpadEnter: 'Enter',
      LogicalKeyboardKey.backspace: 'Backspace',
      LogicalKeyboardKey.delete: 'Delete',
      LogicalKeyboardKey.tab: 'Tab',
      LogicalKeyboardKey.escape: 'Escape',
      LogicalKeyboardKey.space: 'Space',
      LogicalKeyboardKey.arrowLeft: 'ArrowLeft',
      LogicalKeyboardKey.arrowRight: 'ArrowRight',
      LogicalKeyboardKey.arrowUp: 'ArrowUp',
      LogicalKeyboardKey.arrowDown: 'ArrowDown',
      LogicalKeyboardKey.home: 'Home',
      LogicalKeyboardKey.end: 'End',
      LogicalKeyboardKey.pageUp: 'PageUp',
      LogicalKeyboardKey.pageDown: 'PageDown',
      LogicalKeyboardKey.f1: 'F1',
      LogicalKeyboardKey.f2: 'F2',
      LogicalKeyboardKey.f3: 'F3',
      LogicalKeyboardKey.f4: 'F4',
      LogicalKeyboardKey.f5: 'F5',
      LogicalKeyboardKey.f6: 'F6',
      LogicalKeyboardKey.f7: 'F7',
      LogicalKeyboardKey.f8: 'F8',
      LogicalKeyboardKey.f9: 'F9',
      LogicalKeyboardKey.f10: 'F10',
      LogicalKeyboardKey.f11: 'F11',
      LogicalKeyboardKey.f12: 'F12',
      LogicalKeyboardKey.minus: 'Minus',
      LogicalKeyboardKey.equal: 'Equal',
      LogicalKeyboardKey.bracketLeft: 'BracketLeft',
      LogicalKeyboardKey.bracketRight: 'BracketRight',
      LogicalKeyboardKey.backslash: 'Backslash',
      LogicalKeyboardKey.semicolon: 'Semicolon',
      LogicalKeyboardKey.quote: 'Quote',
      LogicalKeyboardKey.comma: 'Comma',
      LogicalKeyboardKey.period: 'Period',
      LogicalKeyboardKey.slash: 'Slash',
      LogicalKeyboardKey.backquote: 'Backquote',
    }[key];
  }
}
