import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/core/input/remote_ime_input_adapter.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_geometry.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_input_settings.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_pointer_event_coalescer.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_text_input_synchronizer.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_touch_gesture_controller.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum _RemoteToolbarAction { help, settings }

final Set<RemotePointerMode> _shownGestureGuides = {};

void _showGestureGuideOnce(BuildContext context, RemotePointerMode mode) {
  if (!_shownGestureGuides.add(mode)) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (context.mounted) unawaited(_showGestureHelp(context, mode));
  });
}

Future<void> _showGestureHelp(BuildContext context, RemotePointerMode mode) {
  final gestures = mode == RemotePointerMode.direct
      ? const [
          ('轻点', '左键单击当前位置'),
          ('双击', '双击并选择单词'),
          ('按住拖动', '左键拖动或选择文字'),
          ('双击第二下按住', '按单词扩展选择范围'),
          ('双指轻点', '右键单击'),
          ('双指滑动', '滚动画面内容'),
          ('静止长按', '备用右键操作'),
        ]
      : const [
          ('单指滑动', '移动远程鼠标'),
          ('单指轻点', '左键单击'),
          ('双指轻点', '右键单击'),
          ('双指滑动', '滚动画面内容'),
          ('双击第二下按住滑动', '拖动窗口或选择文字'),
          ('拖拽锁定', '持续按住左键，适合长距离选择'),
        ];
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mode == RemotePointerMode.direct ? '直接触控操作说明' : '触控板操作说明',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              for (final gesture in gestures)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.gesture),
                  title: Text(gesture.$1),
                  subtitle: Text(gesture.$2),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _showRemoteInputSettings(
  BuildContext context, {
  required ValueNotifier<RemoteInputSettings> settings,
  required RemoteSessionController session,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => ValueListenableBuilder<RemoteInputSettings>(
      valueListenable: settings,
      builder: (context, value, _) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('输入设置与诊断', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 12),
                Text('指针灵敏度 ${value.pointerSensitivity.toStringAsFixed(2)}×'),
                Slider(
                  value: value.pointerSensitivity,
                  min: 0.5,
                  max: 2,
                  divisions: 12,
                  onChanged: (next) {
                    settings.value = value.copyWith(pointerSensitivity: next);
                  },
                ),
                Text('滚动速度 ${value.scrollSensitivity.toStringAsFixed(2)}×'),
                Slider(
                  value: value.scrollSensitivity,
                  min: 0.5,
                  max: 3,
                  divisions: 10,
                  onChanged: (next) {
                    settings.value = value.copyWith(scrollSensitivity: next);
                  },
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('拖拽锁定'),
                  subtitle: const Text('持续按住远程左键，移动指针即可选择文字'),
                  value: value.dragLock,
                  onChanged: value.pointerMode == RemotePointerMode.touchpad
                      ? (next) {
                          settings.value = value.copyWith(dragLock: next);
                        }
                      : null,
                ),
                const Divider(),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.speed),
                  title: Text(
                    session.inputRoundTripMs == null
                        ? '输入往返延迟：等待采样'
                        : '输入往返延迟：${session.inputRoundTripMs!.toStringAsFixed(1)} ms',
                  ),
                  subtitle: Text(
                    '因发送缓冲过高丢弃的过期移动：${session.droppedMotionEvents}',
                  ),
                ),
                if (kDebugMode)
                  OutlinedButton.icon(
                    onPressed: session.canSendControl
                        ? () {
                            session.sendText('你好');
                            AppMessenger.show('已发送中文诊断文本“你好”');
                          }
                        : null,
                    icon: const Icon(Icons.science_outlined),
                    label: const Text('发送中文诊断文本'),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class RemoteDesktopPanel extends StatefulWidget {
  const RemoteDesktopPanel({super.key, required this.session});

  final RemoteSessionController session;

  @override
  State<RemoteDesktopPanel> createState() => _RemoteDesktopPanelState();
}

class _RemoteDesktopPanelState extends State<RemoteDesktopPanel> {
  final _surfaceKey = GlobalKey<_RemoteDesktopSurfaceState>();
  final _inputSettings = ValueNotifier(const RemoteInputSettings());
  RemoteViewFit _viewFit = RemoteViewFit.contain;
  bool _rendererAttached = true;

  @override
  void initState() {
    super.initState();
    widget.session.addListener(_handleSessionStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _showGestureGuideOnce(context, _inputSettings.value.pointerMode);
      }
    });
  }

  Future<void> _openFullScreen() async {
    setState(() => _rendererAttached = false);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _FullScreenRemoteDesktopPage(
          session: widget.session,
          inputSettings: _inputSettings,
          initialViewFit: _viewFit,
        ),
      ),
    );
    if (mounted) {
      setState(() => _rendererAttached = true);
      AppMessenger.show('已退出全屏');
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_handleSessionStateChanged);
    _inputSettings.dispose();
    super.dispose();
  }

  void _handleSessionStateChanged() {
    if (!widget.session.canSendControl && _inputSettings.value.dragLock) {
      _inputSettings.value = _inputSettings.value.copyWith(dragLock: false);
    }
  }

  void _setPointerMode(RemotePointerMode value) {
    _inputSettings.value = _inputSettings.value.copyWith(
      pointerMode: value,
      dragLock: value == RemotePointerMode.touchpad
          ? _inputSettings.value.dragLock
          : false,
    );
    AppMessenger.show(
      value == RemotePointerMode.touchpad
          ? '触控板：双击第二下按住可拖动，双指轻点为右键'
          : '直接触控：按住拖动可选文字，双指轻点为右键',
      level: AppMessageLevel.success,
    );
    _showGestureGuideOnce(context, value);
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
        return ValueListenableBuilder<RemoteInputSettings>(
          valueListenable: _inputSettings,
          builder: (context, inputSettings, _) => Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ColoredBox(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: _RemoteToolbar(
                    session: widget.session,
                    pointerMode: inputSettings.pointerMode,
                    viewFit: _viewFit,
                    onPointerModeChanged: _setPointerMode,
                    onViewFitChanged: _setViewFit,
                    onKeyboard: () => _surfaceKey.currentState?.showKeyboard(),
                    onHelp: () =>
                        _showGestureHelp(context, inputSettings.pointerMode),
                    onInputSettings: () => _showRemoteInputSettings(
                      context,
                      settings: _inputSettings,
                      session: widget.session,
                    ),
                    onFullScreen: _openFullScreen,
                  ),
                ),
                SizedBox(
                  height: viewportHeight,
                  child: _rendererAttached
                      ? _RemoteDesktopSurface(
                          key: _surfaceKey,
                          session: widget.session,
                          inputSettings: inputSettings,
                          viewFit: _viewFit,
                          onDragLockChanged: (value) {
                            _inputSettings.value = inputSettings.copyWith(
                              dragLock: value,
                            );
                          },
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
          ),
        );
      },
    );
  }
}

class _FullScreenRemoteDesktopPage extends StatefulWidget {
  const _FullScreenRemoteDesktopPage({
    required this.session,
    required this.inputSettings,
    required this.initialViewFit,
  });

  final RemoteSessionController session;
  final ValueNotifier<RemoteInputSettings> inputSettings;
  final RemoteViewFit initialViewFit;

  @override
  State<_FullScreenRemoteDesktopPage> createState() =>
      _FullScreenRemoteDesktopPageState();
}

class _FullScreenRemoteDesktopPageState
    extends State<_FullScreenRemoteDesktopPage> {
  final _surfaceKey = GlobalKey<_RemoteDesktopSurfaceState>();
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
    if (widget.inputSettings.value.dragLock) {
      widget.inputSettings.value = widget.inputSettings.value.copyWith(
        dragLock: false,
      );
    }
    if (Platform.isIOS || Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    }
    super.dispose();
  }

  void _setPointerMode(RemotePointerMode value) {
    widget.inputSettings.value = widget.inputSettings.value.copyWith(
      pointerMode: value,
      dragLock: value == RemotePointerMode.touchpad
          ? widget.inputSettings.value.dragLock
          : false,
    );
    AppMessenger.show(
      value == RemotePointerMode.touchpad
          ? '触控板：双击第二下按住可拖动，双指轻点为右键'
          : '直接触控：按住拖动可选文字，双指轻点为右键',
      level: AppMessageLevel.success,
    );
    _showGestureGuideOnce(context, value);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteInputSettings>(
      valueListenable: widget.inputSettings,
      builder: (context, inputSettings, _) => Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          children: [
            Positioned.fill(
              child: _RemoteDesktopSurface(
                key: _surfaceKey,
                session: widget.session,
                inputSettings: inputSettings,
                viewFit: _viewFit,
                onDragLockChanged: (value) {
                  widget.inputSettings.value = inputSettings.copyWith(
                    dragLock: value,
                  );
                },
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
                    pointerMode: inputSettings.pointerMode,
                    viewFit: _viewFit,
                    leading: IconButton(
                      tooltip: '退出全屏',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                    ),
                    foregroundColor: Colors.white,
                    onPointerModeChanged: _setPointerMode,
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
                    onHelp: () =>
                        _showGestureHelp(context, inputSettings.pointerMode),
                    onInputSettings: () => _showRemoteInputSettings(
                      context,
                      settings: widget.inputSettings,
                      session: widget.session,
                    ),
                    onFullScreen: () => Navigator.of(context).pop(),
                    isFullScreen: true,
                  ),
                ),
              ),
            ),
          ],
        ),
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
    required this.onHelp,
    required this.onInputSettings,
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
  final VoidCallback onHelp;
  final VoidCallback onInputSettings;
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
                  PopupMenuButton<_RemoteToolbarAction>(
                    tooltip: '远程输入帮助与设置',
                    onSelected: (action) {
                      switch (action) {
                        case _RemoteToolbarAction.help:
                          onHelp();
                        case _RemoteToolbarAction.settings:
                          onInputSettings();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: _RemoteToolbarAction.help,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.help_outline),
                          title: Text('操作说明'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _RemoteToolbarAction.settings,
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.tune),
                          title: Text('输入设置与诊断'),
                        ),
                      ),
                    ],
                    icon: const Icon(Icons.more_horiz),
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
    required this.inputSettings,
    required this.viewFit,
    required this.onDragLockChanged,
  });

  final RemoteSessionController session;
  final RemoteInputSettings inputSettings;
  final RemoteViewFit viewFit;
  final ValueChanged<bool> onDragLockChanged;

  @override
  State<_RemoteDesktopSurface> createState() => _RemoteDesktopSurfaceState();
}

class _RemoteDesktopSurfaceState extends State<_RemoteDesktopSurface>
    with WidgetsBindingObserver {
  final _hardwareFocus = FocusNode(debugLabel: 'remote-hardware-keyboard');
  final _textFocus = FocusNode(debugLabel: 'remote-soft-keyboard');
  final _textController = TextEditingController();
  final _textSynchronizer = RemoteTextInputSynchronizer();
  final RemoteImeInputAdapter _nativeIme = MethodChannelRemoteImeInputAdapter();
  final _pointerCoalescer = RemotePointerEventCoalescer();
  final Set<int> _ignoredPointers = {};
  final Map<int, String> _mouseButtons = {};
  late final RemoteTouchGestureController _gestures =
      RemoteTouchGestureController(
        mode: widget.inputSettings.pointerMode,
        pointerSensitivity: widget.inputSettings.pointerSensitivity,
        scrollSensitivity: widget.inputSettings.scrollSensitivity,
      );
  Timer? _longPressTimer;
  Timer? _pointerFlushTimer;
  StreamSubscription<RemoteImeInputEvent>? _imeSubscription;
  late final String _imeClientId;
  final List<String> _imeDiagnostics = [];
  bool _keyboardVisible = false;
  bool _nativeImeFailed = false;
  int _compositionLength = 0;
  RemoteContentTransform? _latestTransform;
  Offset? _lastNormalizedPointer;

  RemoteSessionController get session => widget.session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _imeClientId = 'remote-surface-${identityHashCode(this)}';
    if (Platform.isIOS) {
      _imeSubscription = _nativeIme.events.listen(
        _handleNativeImeEvent,
        onError: _handleNativeImeError,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _updateGestureConfiguration();
    });
  }

  @override
  void didUpdateWidget(covariant _RemoteDesktopSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputSettings != widget.inputSettings) {
      _updateGestureConfiguration();
    }
  }

  void _updateGestureConfiguration() {
    final settings = widget.inputSettings;
    _dispatchGestureActions(
      _gestures.updateConfiguration(
        mode: settings.pointerMode,
        pointerSensitivity: settings.pointerSensitivity,
        scrollSensitivity: settings.scrollSensitivity,
        dragLock: settings.dragLock,
      ),
    );
  }

  void showKeyboard() {
    if (!session.canSendControl) {
      session.explainControlUnavailable();
      return;
    }
    if (!_keyboardVisible) {
      setState(() => _keyboardVisible = true);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_activateKeyboard());
    });
  }

  void _hideKeyboard() {
    if (Platform.isIOS) {
      unawaited(_hideNativeIme());
    } else {
      _textFocus.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
    if (mounted) {
      setState(() {
        _keyboardVisible = false;
        _compositionLength = 0;
      });
    }
  }

  Future<void> _activateKeyboard({bool announce = true}) async {
    if (Platform.isIOS && !_nativeImeFailed) {
      try {
        final shown = await _nativeIme.show(clientId: _imeClientId);
        if (!shown) throw StateError('iOS keyboard rejected first responder');
        if (announce) AppMessenger.show('即时远程键盘已打开');
        return;
      } catch (error) {
        _handleNativeImeError(error);
      }
    }
    _activateFlutterKeyboard();
    if (announce) {
      AppMessenger.show(
        Platform.isIOS ? '原生键盘不可用，已切换兼容输入模式' : '远程键盘已打开',
        level: Platform.isIOS ? AppMessageLevel.warning : AppMessageLevel.info,
      );
    }
  }

  void _activateFlutterKeyboard() {
    _resetTextInput();
    _textFocus.requestFocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  Future<void> _hideNativeIme() async {
    try {
      await _nativeIme.hide(clientId: _imeClientId);
    } catch (_) {
      // A failed bridge has already switched the UI to the Flutter fallback.
    }
  }

  void _handleNativeImeEvent(RemoteImeInputEvent event) {
    if (!mounted || event.clientId != _imeClientId || !_keyboardVisible) {
      return;
    }
    switch (event.type) {
      case RemoteImeInputEventType.composition:
        if (_compositionLength != event.compositionLength) {
          setState(() => _compositionLength = event.compositionLength);
        }
      case RemoteImeInputEventType.commit:
        if (event.text.isNotEmpty) session.sendText(event.text);
        if (_compositionLength != 0) {
          setState(() => _compositionLength = 0);
        }
      case RemoteImeInputEventType.key:
        if (const {'Backspace', 'Enter', 'Tab'}.contains(event.key)) {
          _sendSpecialKey(event.key);
        }
      case RemoteImeInputEventType.diagnostic:
        if (!kDebugMode) return;
        _imeDiagnostics.add(
          '${event.diagnosticName}: marked=${event.markedLength}, '
          'cjk=${event.containsCjk}',
        );
        if (_imeDiagnostics.length > 30) _imeDiagnostics.removeAt(0);
    }
  }

  void _handleNativeImeError(Object error, [StackTrace? stackTrace]) {
    if (!mounted || _nativeImeFailed) return;
    setState(() => _nativeImeFailed = true);
    if (_keyboardVisible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _activateFlutterKeyboard();
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_keyboardVisible &&
        const {
          AppLifecycleState.inactive,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
          AppLifecycleState.hidden,
        }.contains(state)) {
      _hideKeyboard();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _pointerFlushTimer?.cancel();
    unawaited(_imeSubscription?.cancel());
    _dispatchGestureActions(_gestures.cancelAll(releaseDragLock: true));
    _flushPointerMotion();
    if (_keyboardVisible) {
      if (Platform.isIOS) {
        unawaited(_hideNativeIme());
      } else {
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
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
          _latestTransform = transform;
          return Focus(
            focusNode: _hardwareFocus,
            autofocus: true,
            onKeyEvent: _handleKeyEvent,
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
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (event) => _pointerDown(event, transform),
                    onPointerMove: (event) => _pointerMove(event, transform),
                    onPointerUp: (event) => _pointerUp(event, transform),
                    onPointerCancel: (event) =>
                        _pointerCancel(event, transform),
                    onPointerHover: (event) => _pointerHover(event, transform),
                    onPointerSignal: (event) =>
                        _pointerSignal(event, transform),
                    child: const SizedBox.expand(),
                  ),
                ),
                if (widget.inputSettings.pointerMode ==
                        RemotePointerMode.touchpad &&
                    !_keyboardVisible)
                  Positioned(
                    right: 10,
                    bottom: 10,
                    child: SafeArea(
                      top: false,
                      left: false,
                      child: _RemotePointerControlBar(
                        dragLock: widget.inputSettings.dragLock,
                        onLeftClick: () {
                          if (widget.inputSettings.dragLock) {
                            widget.onDragLockChanged(false);
                          } else {
                            _sendRelativeButtonClick('left');
                          }
                        },
                        onRightClick: () => _sendRelativeButtonClick('right'),
                        onDragLockChanged: widget.onDragLockChanged,
                      ),
                    ),
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
                          child: Row(
                            children: [
                              if (Platform.isIOS && !_nativeImeFailed)
                                Expanded(
                                  child: InkWell(
                                    onTap: () => unawaited(
                                      _activateKeyboard(announce: false),
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 14,
                                        vertical: 10,
                                      ),
                                      child: Row(
                                        children: [
                                          const Icon(Icons.keyboard_outlined),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            child: Column(
                                              mainAxisSize: MainAxisSize.min,
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  _compositionLength > 0
                                                      ? '正在组合输入（$_compositionLength）'
                                                      : '即时远程键盘',
                                                ),
                                                const Text(
                                                  '提交后立即发送，本机不保留历史文本',
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                )
                              else
                                Expanded(
                                  child: TextField(
                                    focusNode: _textFocus,
                                    controller: _textController,
                                    autocorrect: true,
                                    enableSuggestions: true,
                                    maxLines: 1,
                                    textInputAction: TextInputAction.done,
                                    decoration: const InputDecoration(
                                      labelText: '兼容输入',
                                      prefixIcon: Icon(Icons.keyboard_outlined),
                                    ),
                                    onTap: _keepTextSelectionAtEnd,
                                    onChanged: (_) => _textChanged(),
                                    onSubmitted: (_) {
                                      _sendSpecialKey('Enter');
                                      _textFocus.requestFocus();
                                    },
                                  ),
                                ),
                              IconButton(
                                tooltip: '整句发送',
                                onPressed: _showComposedTextDialog,
                                icon: const Icon(Icons.edit_note),
                              ),
                              IconButton(
                                tooltip: '远程退格',
                                onPressed: () => _sendSpecialKey('Backspace'),
                                icon: const Icon(Icons.backspace_outlined),
                              ),
                              if (kDebugMode &&
                                  Platform.isIOS &&
                                  !_nativeImeFailed)
                                IconButton(
                                  tooltip: '输入法诊断',
                                  onPressed: _showImeDiagnostics,
                                  icon: const Icon(Icons.bug_report_outlined),
                                ),
                              IconButton(
                                tooltip: '关闭远程键盘',
                                onPressed: _hideKeyboard,
                                icon: const Icon(Icons.close),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
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
      _lastNormalizedPointer = normalized;
      final button = event.buttons & kSecondaryMouseButton != 0
          ? 'right'
          : 'left';
      _mouseButtons[event.pointer] = button;
      _sendPointerNow(
        RemotePointerPacket(
          phase: 'down',
          x: normalized.dx,
          y: normalized.dy,
          button: button,
        ),
      );
      return;
    }

    if (widget.inputSettings.pointerMode == RemotePointerMode.direct &&
        transform.normalize(event.localPosition) == null) {
      _ignoredPointers.add(event.pointer);
      return;
    }
    _dispatchGestureActions(
      _gestures.pointerDown(event.pointer, event.localPosition, DateTime.now()),
      transform,
    );
    if (widget.inputSettings.pointerMode == RemotePointerMode.direct) {
      _longPressTimer?.cancel();
      _longPressTimer = Timer(const Duration(milliseconds: 550), () {
        _dispatchGestureActions(_gestures.longPress(), transform);
      });
    }
  }

  void _pointerMove(PointerMoveEvent event, RemoteContentTransform transform) {
    if (_ignoredPointers.contains(event.pointer)) return;
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized = transform.normalize(event.localPosition);
      if (normalized != null) {
        _lastNormalizedPointer = normalized;
        _queuePointerMotion(
          RemotePointerPacket(
            phase: 'move',
            x: normalized.dx,
            y: normalized.dy,
            button: _mouseButtons[event.pointer] ?? 'left',
          ),
        );
      }
      return;
    }
    _dispatchGestureActions(
      _gestures.pointerMove(event.pointer, event.localPosition, event.delta),
      transform,
    );
  }

  void _pointerUp(PointerUpEvent event, RemoteContentTransform transform) {
    if (_ignoredPointers.remove(event.pointer)) {
      return;
    }
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized =
          transform.normalize(event.localPosition) ?? _lastNormalizedPointer;
      final button = _mouseButtons.remove(event.pointer) ?? 'left';
      if (normalized != null) {
        _sendPointerNow(
          RemotePointerPacket(
            phase: 'up',
            x: normalized.dx,
            y: normalized.dy,
            button: button,
          ),
        );
      }
      return;
    }
    _longPressTimer?.cancel();
    _dispatchGestureActions(
      _gestures.pointerUp(event.pointer, event.localPosition, DateTime.now()),
      transform,
    );
  }

  void _pointerCancel(
    PointerCancelEvent event,
    RemoteContentTransform transform,
  ) {
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized =
          transform.normalize(event.localPosition) ?? _lastNormalizedPointer;
      final button = _mouseButtons.remove(event.pointer) ?? 'left';
      if (normalized != null) {
        _sendPointerNow(
          RemotePointerPacket(
            phase: 'up',
            x: normalized.dx,
            y: normalized.dy,
            button: button,
          ),
        );
      }
      return;
    }
    _longPressTimer?.cancel();
    _dispatchGestureActions(
      _gestures.pointerCancel(event.pointer, event.localPosition),
      transform,
    );
    _ignoredPointers.remove(event.pointer);
    _mouseButtons.remove(event.pointer);
  }

  void _pointerHover(
    PointerHoverEvent event,
    RemoteContentTransform transform,
  ) {
    final normalized = transform.normalize(event.localPosition);
    if (normalized != null) {
      _lastNormalizedPointer = normalized;
      _queuePointerMotion(
        RemotePointerPacket(phase: 'move', x: normalized.dx, y: normalized.dy),
      );
    }
  }

  void _pointerSignal(
    PointerSignalEvent event,
    RemoteContentTransform transform,
  ) {
    if (event is! PointerScrollEvent) return;
    final normalized = transform.normalize(event.localPosition);
    if (normalized != null) {
      _queuePointerMotion(
        RemotePointerPacket(
          phase: 'scroll',
          x: normalized.dx,
          y: normalized.dy,
          deltaX: event.scrollDelta.dx,
          deltaY: event.scrollDelta.dy,
        ),
      );
    }
  }

  void _dispatchGestureActions(
    List<RemoteGestureAction> actions, [
    RemoteContentTransform? transform,
  ]) {
    final activeTransform = transform ?? _latestTransform;
    for (final action in actions) {
      switch (action.type) {
        case RemoteGestureActionType.haptic:
          unawaited(HapticFeedback.selectionClick());
        case RemoteGestureActionType.absoluteDown:
        case RemoteGestureActionType.absoluteMove:
        case RemoteGestureActionType.absoluteUp:
          final position = action.position;
          var normalized = position == null || activeTransform == null
              ? null
              : activeTransform.normalize(position);
          if (normalized != null) _lastNormalizedPointer = normalized;
          if (action.type == RemoteGestureActionType.absoluteUp) {
            normalized ??= _lastNormalizedPointer;
          }
          if (normalized == null) continue;
          final phase = switch (action.type) {
            RemoteGestureActionType.absoluteDown => 'down',
            RemoteGestureActionType.absoluteMove => 'move',
            RemoteGestureActionType.absoluteUp => 'up',
            _ => throw StateError('unreachable'),
          };
          final packet = RemotePointerPacket(
            phase: phase,
            x: normalized.dx,
            y: normalized.dy,
            button: action.button,
            clickCount: action.clickCount,
          );
          if (phase == 'move') {
            _queuePointerMotion(packet);
          } else {
            _sendPointerNow(packet);
          }
        case RemoteGestureActionType.relativeDown:
        case RemoteGestureActionType.relativeUp:
          _sendPointerNow(
            RemotePointerPacket(
              phase: action.type == RemoteGestureActionType.relativeDown
                  ? 'down'
                  : 'up',
              mode: 'relative',
              x: 0.5,
              y: 0.5,
              button: action.button,
              clickCount: action.clickCount,
            ),
          );
        case RemoteGestureActionType.relativeMove:
          _queuePointerMotion(
            RemotePointerPacket(
              phase: 'move',
              mode: 'relative',
              x: 0.5,
              y: 0.5,
              movementX: action.delta.dx,
              movementY: action.delta.dy,
            ),
          );
        case RemoteGestureActionType.scroll:
          final position = action.position;
          final normalized = position == null || activeTransform == null
              ? null
              : activeTransform.normalize(position);
          _queuePointerMotion(
            RemotePointerPacket(
              phase: 'scroll',
              mode: position == null ? 'relative' : 'absolute',
              x: normalized?.dx ?? 0.5,
              y: normalized?.dy ?? 0.5,
              deltaX: action.delta.dx,
              deltaY: action.delta.dy,
            ),
          );
      }
    }
  }

  void _queuePointerMotion(RemotePointerPacket packet) {
    _pointerCoalescer.add(packet);
    if (_pointerFlushTimer?.isActive == true) return;
    _pointerFlushTimer = Timer(const Duration(microseconds: 16667), () {
      _pointerFlushTimer = null;
      _flushPointerMotion();
    });
  }

  void _flushPointerMotion() {
    _pointerFlushTimer?.cancel();
    _pointerFlushTimer = null;
    for (final packet in _pointerCoalescer.drain()) {
      _sendPointerPacket(packet);
    }
  }

  void _sendPointerNow(RemotePointerPacket packet) {
    _flushPointerMotion();
    _sendPointerPacket(packet);
  }

  void _sendPointerPacket(RemotePointerPacket packet) {
    session.sendPointer(
      phase: packet.phase,
      mode: packet.mode,
      x: packet.x,
      y: packet.y,
      button: packet.button,
      clickCount: packet.clickCount,
      movementX: packet.movementX,
      movementY: packet.movementY,
      deltaX: packet.deltaX,
      deltaY: packet.deltaY,
    );
  }

  void _sendRelativeButtonClick(String button) {
    _sendPointerNow(
      RemotePointerPacket(
        phase: 'down',
        mode: 'relative',
        x: 0.5,
        y: 0.5,
        button: button,
      ),
    );
    _sendPointerNow(
      RemotePointerPacket(
        phase: 'up',
        mode: 'relative',
        x: 0.5,
        y: 0.5,
        button: button,
      ),
    );
    unawaited(HapticFeedback.selectionClick());
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

  void _textChanged() {
    final value = _textController.value;
    final edit = _textSynchronizer.update(value);
    for (var index = 0; index < edit.backspaceCount; index += 1) {
      _sendSpecialKey('Backspace');
    }
    if (edit.insertedText.isNotEmpty) {
      session.sendText(edit.insertedText);
    }
    if (_textSynchronizer.shouldCompact() &&
        (!value.composing.isValid || value.composing.isCollapsed)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resetTextInput();
      });
    }
  }

  void _resetTextInput() {
    _textSynchronizer.reset();
    _textController.clear();
  }

  void _keepTextSelectionAtEnd() {
    final value = _textController.value;
    if (value.composing.isValid && !value.composing.isCollapsed) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _textController.selection = TextSelection.collapsed(
        offset: _textController.text.length,
      );
    });
  }

  Future<void> _showComposedTextDialog() async {
    if (Platform.isIOS && !_nativeImeFailed) {
      await _hideNativeIme();
    }
    if (!mounted) return;
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('整句发送'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: 2,
          maxLines: 4,
          autocorrect: true,
          enableSuggestions: true,
          decoration: const InputDecoration(hintText: '在本机完成整句输入后，一次发送到远程设备'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('发送'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) return;
    if (text != null && text.isNotEmpty) {
      session.sendText(text);
      AppMessenger.show(
        '整句文本已发送（${text.runes.length} 个字符）',
        level: AppMessageLevel.success,
      );
    }
    if (_keyboardVisible) {
      await _activateKeyboard(announce: false);
    }
  }

  void _showImeDiagnostics() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('输入法事件诊断'),
        content: SizedBox(
          width: 420,
          child: _imeDiagnostics.isEmpty
              ? const Text('尚无事件。诊断只记录事件类型和长度，不记录输入内容。')
              : SingleChildScrollView(
                  child: SelectableText(
                    ['仅记录事件类型、组合长度和 CJK 标记：', ..._imeDiagnostics].join('\n'),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
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

class _RemotePointerControlBar extends StatelessWidget {
  const _RemotePointerControlBar({
    required this.dragLock,
    required this.onLeftClick,
    required this.onRightClick,
    required this.onDragLockChanged,
  });

  final bool dragLock;
  final VoidCallback onLeftClick;
  final VoidCallback onRightClick;
  final ValueChanged<bool> onDragLockChanged;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.68),
      borderRadius: BorderRadius.circular(24),
      child: IconTheme(
        data: const IconThemeData(color: Colors.white),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: dragLock ? '释放左键' : '左键单击',
              onPressed: onLeftClick,
              icon: const Icon(Icons.mouse_outlined),
            ),
            IconButton(
              tooltip: '右键单击',
              onPressed: onRightClick,
              icon: const Icon(Icons.menu_open),
            ),
            IconButton(
              tooltip: dragLock ? '关闭拖拽锁定' : '开启拖拽锁定',
              onPressed: () => onDragLockChanged(!dragLock),
              color: dragLock ? Colors.amber : Colors.white,
              icon: Icon(dragLock ? Icons.lock : Icons.lock_open),
            ),
          ],
        ),
      ),
    );
  }
}
