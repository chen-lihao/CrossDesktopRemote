import 'dart:async';
import 'dart:io';

import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/remote_ime_input_adapter.dart';
import 'package:cross_desktop_remote/core/input/remote_shortcut_policy.dart';
import 'package:cross_desktop_remote/core/platform/desktop_window_mode.dart';
import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/core/signaling/remote_capabilities.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/desktop_mouse_click_tracker.dart';
import 'package:cross_desktop_remote/features/remote/presentation/explicit_file_transfer_center.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_composed_text_editor.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_desktop_geometry.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_display_adjustment.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_input_settings.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_keyboard_translator.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_pointer_event_coalescer.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_text_input_synchronizer.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_touch_gesture_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/windows_remote_ime_coordinator.dart';
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
  ValueChanged<RemoteKeyboardMode>? onKeyboardModeChanged,
  ValueChanged<RemoteTextInputMode>? onTextInputModeChanged,
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
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('远程键盘模式'),
                  subtitle: const Text('快捷键使用小键盘，文字和拼音使用系统键盘'),
                  trailing: DropdownButton<RemoteKeyboardMode>(
                    value: value.keyboardMode,
                    onChanged: (mode) {
                      if (mode != null) {
                        settings.value = value.copyWith(keyboardMode: mode);
                        onKeyboardModeChanged?.call(mode);
                      }
                    },
                    items: [
                      for (final mode in RemoteKeyboardMode.values)
                        DropdownMenuItem(value: mode, child: Text(mode.label)),
                    ],
                  ),
                ),
                if (Platform.isMacOS || Platform.isWindows || Platform.isLinux)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('文字输入方式'),
                    subtitle: Text(
                      value.textInputMode == RemoteTextInputMode.remoteIme &&
                              !session.remoteSupportsPhysicalKeyboard
                          ? '被控端未声明物理键盘能力，当前使用本机输入法'
                          : value.textInputMode.description,
                    ),
                    trailing: DropdownButton<RemoteTextInputMode>(
                      value: value.textInputMode,
                      onChanged: (mode) {
                        if (mode == null) return;
                        if (mode == RemoteTextInputMode.remoteIme &&
                            !session.remoteSupportsPhysicalKeyboard) {
                          AppMessenger.show(
                            '当前被控端不支持系统输入法模式',
                            level: AppMessageLevel.warning,
                          );
                          return;
                        }
                        settings.value = value.copyWith(textInputMode: mode);
                        onTextInputModeChanged?.call(mode);
                      },
                      items: [
                        for (final mode in RemoteTextInputMode.values)
                          DropdownMenuItem(
                            value: mode,
                            child: Text(mode.label),
                          ),
                      ],
                    ),
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

Future<void> _showRemoteDisplayAdjustment(
  BuildContext context, {
  required RemoteDisplayAdjustmentController adjustment,
  required RemoteSessionController session,
}) {
  session.refreshColorDiagnostics();
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => AnimatedBuilder(
      animation: session,
      builder: (context, _) => ValueListenableBuilder<RemoteDisplayAdjustment>(
        valueListenable: adjustment,
        builder: (context, value, _) {
          final diagnostics = session.colorDiagnostics;
          final display = diagnostics?.forDisplay(session.selectedDisplayId);
          final selectedDisplay = session.selectedDisplay;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('显示调整', style: Theme.of(context).textTheme.titleLarge),
                const SizedBox(height: 6),
                const Text('设置按远程设备和显示器独立保存。采集端已裁切的高光无法在这里恢复。'),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final mode in RemoteDisplayAdjustmentMode.values)
                      ChoiceChip(
                        label: Text(mode.label),
                        selected: value.mode == mode,
                        onSelected: (_) => adjustment.setMode(mode),
                      ),
                  ],
                ),
                if (value.mode == RemoteDisplayAdjustmentMode.custom) ...[
                  const SizedBox(height: 16),
                  Text('亮度 ${(value.brightness * 100).round()}'),
                  Slider(
                    value: value.brightness,
                    min: -0.25,
                    max: 0.25,
                    divisions: 20,
                    onChanged: (next) =>
                        adjustment.updateCustom(brightness: next),
                  ),
                  Text('对比度 ${value.contrast.toStringAsFixed(2)}×'),
                  Slider(
                    value: value.contrast,
                    min: 0.7,
                    max: 1.3,
                    divisions: 24,
                    onChanged: (next) =>
                        adjustment.updateCustom(contrast: next),
                  ),
                  Text('饱和度 ${value.saturation.toStringAsFixed(2)}×'),
                  Slider(
                    value: value.saturation,
                    min: 0,
                    max: 1.5,
                    divisions: 30,
                    onChanged: (next) =>
                        adjustment.updateCustom(saturation: next),
                  ),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: adjustment.reset,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('恢复当前显示器默认值'),
                  ),
                ),
                const Divider(height: 28),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '色彩诊断',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    IconButton(
                      tooltip: '刷新色彩诊断',
                      onPressed: session.refreshColorDiagnostics,
                      icon: const Icon(Icons.refresh),
                    ),
                  ],
                ),
                if (diagnostics == null)
                  const Text('等待被控 Mac 返回采集和显示器色彩信息……')
                else ...[
                  _ColorDiagnosticRow(
                    label: '像素格式 / Range',
                    value: '${diagnostics.pixelFormat} · ${diagnostics.range}',
                  ),
                  _ColorDiagnosticRow(
                    label: '色彩原色',
                    value: diagnostics.colorPrimaries,
                  ),
                  _ColorDiagnosticRow(
                    label: '传递函数',
                    value: diagnostics.transferFunction,
                  ),
                  _ColorDiagnosticRow(
                    label: 'YCbCr Matrix',
                    value: diagnostics.yCbCrMatrix,
                  ),
                  _ColorDiagnosticRow(
                    label: '采集色彩空间 / 动态范围',
                    value:
                        '${diagnostics.colorSpace} · ${diagnostics.captureDynamicRange}',
                  ),
                  _ColorDiagnosticRow(
                    label: 'Mac 色彩归一化',
                    value: diagnostics.normalizationDurationMs == null
                        ? diagnostics.normalization
                        : '${diagnostics.normalization} · '
                              '${diagnostics.normalizationDurationMs!.toStringAsFixed(2)} ms',
                  ),
                  if (diagnostics.frameGeometry case final geometry?)
                    _ColorDiagnosticRow(
                      label: 'SCK ContentRect / Scale',
                      value: geometry.label,
                    ),
                  if (diagnostics.rawFrame case final raw?) ...[
                    _ColorDiagnosticRow(
                      label: '① SCK 原始帧',
                      value: _formatFrameColorCheckpoint(raw),
                    ),
                    _ColorDiagnosticRow(
                      label: '① 16 桶灰阶',
                      value: raw.histogramLabel,
                    ),
                  ],
                  if (diagnostics.encoderInput case final encoder?) ...[
                    _ColorDiagnosticRow(
                      label: '② 编码器输入',
                      value: _formatFrameColorCheckpoint(encoder),
                    ),
                    _ColorDiagnosticRow(
                      label: '② 16 桶灰阶',
                      value: encoder.histogramLabel,
                    ),
                  ],
                  _ColorDiagnosticRow(
                    label: 'WebRTC 目标 / 发送 / 接收',
                    value:
                        '${session.expectedVideoFrameSize?.label ?? 'Unknown'} / '
                        '${session.outboundVideoFrameSize?.label ?? 'Unknown'} / '
                        '${session.inboundVideoFrameSize?.label ?? 'Unknown'}',
                  ),
                  _ColorDiagnosticRow(
                    label: '控制端已提交画面几何',
                    value: session.committedFrameGeometry?.label ?? 'Unknown',
                  ),
                  _ColorDiagnosticRow(
                    label: '逻辑坐标 / 采集像素',
                    value:
                        selectedDisplay?.geometryDiagnosticsLabel ?? 'Unknown',
                  ),
                  if (session.decoderOutputColorDiagnostics
                      case final decoder?) ...[
                    _ColorDiagnosticRow(
                      label: '③ iPad 解码帧',
                      value: _formatFrameColorCheckpoint(decoder),
                    ),
                    _ColorDiagnosticRow(
                      label: '③ 16 桶灰阶',
                      value: decoder.histogramLabel,
                    ),
                  ],
                  if (session.renderOutputColorDiagnostics
                      case final rendered?) ...[
                    _ColorDiagnosticRow(
                      label: 'iPad Texture 输入',
                      value: _formatFrameColorCheckpoint(rendered),
                    ),
                    _ColorDiagnosticRow(
                      label: '接收端转换',
                      value: session.receiverColorConversion ?? 'Unknown',
                    ),
                  ],
                  _ColorDiagnosticRow(
                    label: '当前 Mac 显示器',
                    value: display == null
                        ? 'Unknown'
                        : '${display.name} · ${display.colorSpace}',
                  ),
                  _ColorDiagnosticRow(
                    label: 'HDR / EDR',
                    value: display == null
                        ? 'Unknown'
                        : '${display.hdrActive ? '已开启' : '未开启'} · '
                              '当前 ${display.currentEdrHeadroom.toStringAsFixed(2)}× / '
                              '潜力 ${display.potentialEdrHeadroom.toStringAsFixed(2)}×',
                  ),
                ],
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    OutlinedButton.icon(
                      onPressed: session.showRemoteGrayscaleTestPattern,
                      icon: const Icon(Icons.gradient_outlined),
                      label: const Text('在 Mac 显示灰阶图'),
                    ),
                    OutlinedButton.icon(
                      onPressed: session.openRemoteDisplaySettings,
                      icon: const Icon(Icons.monitor_outlined),
                      label: const Text('打开 Mac 显示器设置'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  '诊断只上传抽样灰阶统计和色彩附件，不上传屏幕像素。A/B 验证时临时切换 Mac HDR 后刷新；关闭 HDR 只用于定位。',
                ),
              ],
            ),
          );
        },
      ),
    ),
  );
}

String _formatFrameColorCheckpoint(RemoteFrameColorDiagnostics value) {
  return '${value.dimensions} · ${value.pixelFormat} · ${value.range}\n'
      'Y ${value.lumaMin}～${value.lumaMax}（标称 '
      '${value.nominalBlack}～${value.nominalWhite}） · '
      '低于黑位 ${value.belowNominalBlackPercent.toStringAsFixed(2)}% · '
      '高于白位 ${value.aboveNominalWhitePercent.toStringAsFixed(2)}%\n'
      '${value.colorPrimaries} · ${value.transferFunction} · '
      '${value.yCbCrMatrix}';
}

class _ColorDiagnosticRow extends StatelessWidget {
  const _ColorDiagnosticRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 150, child: Text(label)),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}

class RemoteDesktopPanel extends StatefulWidget {
  const RemoteDesktopPanel({
    super.key,
    required this.session,
    this.initialInputSettings = const RemoteInputSettings(),
    this.onKeyboardModeChanged,
    this.onTextInputModeChanged,
    this.desktopFullScreen = false,
    this.onDesktopFullScreenChanged,
  });

  final RemoteSessionController session;
  final RemoteInputSettings initialInputSettings;
  final ValueChanged<RemoteKeyboardMode>? onKeyboardModeChanged;
  final ValueChanged<RemoteTextInputMode>? onTextInputModeChanged;
  final bool desktopFullScreen;
  final Future<bool> Function(bool enabled)? onDesktopFullScreenChanged;

  @override
  State<RemoteDesktopPanel> createState() => _RemoteDesktopPanelState();
}

class _RemoteDesktopPanelState extends State<RemoteDesktopPanel> {
  final _surfaceKey = GlobalKey<_RemoteDesktopSurfaceState>();
  late final ValueNotifier<RemoteInputSettings> _inputSettings;
  final _displayAdjustment = RemoteDisplayAdjustmentController();
  RemoteViewFit _viewFit = RemoteViewFit.contain;
  bool _rendererAttached = true;
  String? _displayAdjustmentTarget;

  @override
  void initState() {
    super.initState();
    _inputSettings = ValueNotifier(widget.initialInputSettings);
    widget.session.addListener(_handleSessionStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _syncDisplayAdjustmentTarget();
        _showGestureGuideOnce(context, _inputSettings.value.pointerMode);
      }
    });
  }

  Future<void> _openFullScreen() async {
    if (Platform.isWindows && widget.onDesktopFullScreenChanged != null) {
      final changed = await widget.onDesktopFullScreenChanged!(true);
      if (changed && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _surfaceKey.currentState?.requestHardwareKeyboardFocus();
        });
        AppMessenger.show('已进入全屏，按 Esc 可退出');
      }
      return;
    }
    setState(() => _rendererAttached = false);
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _FullScreenRemoteDesktopPage(
          session: widget.session,
          inputSettings: _inputSettings,
          displayAdjustment: _displayAdjustment,
          initialViewFit: _viewFit,
          onKeyboardModeChanged: widget.onKeyboardModeChanged,
          onTextInputModeChanged: widget.onTextInputModeChanged,
        ),
      ),
    );
    if (mounted) {
      setState(() => _rendererAttached = true);
      AppMessenger.show('已退出全屏');
    }
  }

  Future<void> _closeDesktopFullScreen() async {
    final changed = await widget.onDesktopFullScreenChanged?.call(false);
    if (changed == true && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _surfaceKey.currentState?.requestHardwareKeyboardFocus();
      });
      AppMessenger.show('已退出全屏');
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_handleSessionStateChanged);
    _inputSettings.dispose();
    _displayAdjustment.dispose();
    super.dispose();
  }

  void _handleSessionStateChanged() {
    if (!widget.session.canSendControl && _inputSettings.value.dragLock) {
      _inputSettings.value = _inputSettings.value.copyWith(dragLock: false);
    }
    _syncDisplayAdjustmentTarget();
  }

  void _syncDisplayAdjustmentTarget() {
    final deviceId = widget.session.remoteDeviceId;
    final displayId = widget.session.selectedDisplayId;
    final target = deviceId == null || displayId == null
        ? null
        : '$deviceId/$displayId';
    if (_displayAdjustmentTarget == target) return;
    _displayAdjustmentTarget = target;
    unawaited(
      _displayAdjustment.selectTarget(deviceId: deviceId, displayId: displayId),
    );
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

  void _showKeyboard(RemoteKeyboardMode mode) {
    _setKeyboardMode(mode);
    _surfaceKey.currentState?.showKeyboard(mode);
  }

  void _setKeyboardMode(RemoteKeyboardMode mode) {
    _inputSettings.value = _inputSettings.value.copyWith(keyboardMode: mode);
    widget.onKeyboardModeChanged?.call(mode);
  }

  void _setTextInputMode(RemoteTextInputMode mode) {
    _inputSettings.value = _inputSettings.value.copyWith(textInputMode: mode);
    widget.onTextInputModeChanged?.call(mode);
    _surfaceKey.currentState?.requestHardwareKeyboardFocus();
    AppMessenger.show('文字输入：${mode.label}');
  }

  Widget _buildToolbar(
    BuildContext context,
    RemoteInputSettings inputSettings, {
    required bool desktopFullScreen,
  }) {
    return ColoredBox(
      color: desktopFullScreen
          ? Colors.black.withValues(alpha: 0.9)
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      child: _RemoteToolbar(
        session: widget.session,
        pointerMode: inputSettings.pointerMode,
        viewFit: _viewFit,
        onPointerModeChanged: _setPointerMode,
        onViewFitChanged: _setViewFit,
        keyboardMode: inputSettings.keyboardMode,
        onKeyboardModeSelected: _showKeyboard,
        textInputMode: inputSettings.textInputMode,
        onTextInputModeSelected: _setTextInputMode,
        onHelp: () => _showGestureHelp(context, inputSettings.pointerMode),
        onInputSettings: () => _showRemoteInputSettings(
          context,
          settings: _inputSettings,
          session: widget.session,
          onKeyboardModeChanged: _setKeyboardMode,
          onTextInputModeChanged: _setTextInputMode,
        ),
        onDisplayAdjustment: () => _showRemoteDisplayAdjustment(
          context,
          adjustment: _displayAdjustment,
          session: widget.session,
        ),
        onFileTransfer: () =>
            showExplicitFileTransferCenter(context, widget.session),
        onFullScreen: desktopFullScreen
            ? () => unawaited(_closeDesktopFullScreen())
            : _openFullScreen,
        foregroundColor: desktopFullScreen ? Colors.white : null,
        isFullScreen: desktopFullScreen,
      ),
    );
  }

  Widget _buildRemoteSurface(
    RemoteInputSettings inputSettings, {
    required bool desktopFullScreen,
  }) {
    if (!_rendererAttached) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return _RemoteDesktopSurface(
      key: _surfaceKey,
      session: widget.session,
      inputSettings: inputSettings,
      displayAdjustment: _displayAdjustment,
      viewFit: _viewFit,
      preserveVideoViewportWhenKeyboardVisible: desktopFullScreen,
      desktopFullScreen: desktopFullScreen,
      onExitDesktopFullScreen: desktopFullScreen
          ? () => unawaited(_closeDesktopFullScreen())
          : null,
      onKeyboardModeChanged: _setKeyboardMode,
      onDragLockChanged: (value) {
        _inputSettings.value = inputSettings.copyWith(dragLock: value);
      },
    );
  }

  Widget _buildControlWarning(BuildContext context) {
    return Padding(
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
              widget.session.controlError ?? '当前仅可观看，被控设备尚未允许鼠标和键盘输入。',
            ),
          ),
          TextButton(
            onPressed: widget.session.refreshRemoteStatus,
            child: const Text('重新检查'),
          ),
        ],
      ),
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
          builder: (context, inputSettings, _) {
            if (widget.desktopFullScreen) {
              return Material(
                color: Colors.black,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildToolbar(
                      context,
                      inputSettings,
                      desktopFullScreen: true,
                    ),
                    _FileClipboardPasteProgress(session: widget.session),
                    Expanded(
                      child: _buildRemoteSurface(
                        inputSettings,
                        desktopFullScreen: true,
                      ),
                    ),
                  ],
                ),
              );
            }
            return Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildToolbar(
                    context,
                    inputSettings,
                    desktopFullScreen: false,
                  ),
                  _FileClipboardPasteProgress(session: widget.session),
                  SizedBox(
                    height: viewportHeight,
                    child: _buildRemoteSurface(
                      inputSettings,
                      desktopFullScreen: false,
                    ),
                  ),
                  if (widget.session.controlError != null ||
                      widget.session.accessibilityGranted != true)
                    _buildControlWarning(context),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _FullScreenRemoteDesktopPage extends StatefulWidget {
  const _FullScreenRemoteDesktopPage({
    required this.session,
    required this.inputSettings,
    required this.displayAdjustment,
    required this.initialViewFit,
    this.onKeyboardModeChanged,
    this.onTextInputModeChanged,
  });

  final RemoteSessionController session;
  final ValueNotifier<RemoteInputSettings> inputSettings;
  final RemoteDisplayAdjustmentController displayAdjustment;
  final RemoteViewFit initialViewFit;
  final ValueChanged<RemoteKeyboardMode>? onKeyboardModeChanged;
  final ValueChanged<RemoteTextInputMode>? onTextInputModeChanged;

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

  void _showKeyboard(RemoteKeyboardMode mode) {
    _setKeyboardMode(mode);
    _surfaceKey.currentState?.showKeyboard(mode);
  }

  void _setKeyboardMode(RemoteKeyboardMode mode) {
    widget.inputSettings.value = widget.inputSettings.value.copyWith(
      keyboardMode: mode,
    );
    widget.onKeyboardModeChanged?.call(mode);
  }

  void _setTextInputMode(RemoteTextInputMode mode) {
    widget.inputSettings.value = widget.inputSettings.value.copyWith(
      textInputMode: mode,
    );
    widget.onTextInputModeChanged?.call(mode);
    _surfaceKey.currentState?.requestHardwareKeyboardFocus();
    AppMessenger.show('文字输入：${mode.label}');
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<RemoteInputSettings>(
      valueListenable: widget.inputSettings,
      builder: (context, inputSettings, _) => Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              ColoredBox(
                color: Colors.black.withValues(alpha: 0.88),
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
                  keyboardMode: inputSettings.keyboardMode,
                  onKeyboardModeSelected: _showKeyboard,
                  textInputMode: inputSettings.textInputMode,
                  onTextInputModeSelected: _setTextInputMode,
                  onHelp: () =>
                      _showGestureHelp(context, inputSettings.pointerMode),
                  onInputSettings: () => _showRemoteInputSettings(
                    context,
                    settings: widget.inputSettings,
                    session: widget.session,
                    onKeyboardModeChanged: _setKeyboardMode,
                    onTextInputModeChanged: _setTextInputMode,
                  ),
                  onDisplayAdjustment: () => _showRemoteDisplayAdjustment(
                    context,
                    adjustment: widget.displayAdjustment,
                    session: widget.session,
                  ),
                  onFileTransfer: () =>
                      showExplicitFileTransferCenter(context, widget.session),
                  onFullScreen: () => Navigator.of(context).pop(),
                  isFullScreen: true,
                ),
              ),
              _FileClipboardPasteProgress(session: widget.session),
              Expanded(
                child: _RemoteDesktopSurface(
                  key: _surfaceKey,
                  session: widget.session,
                  inputSettings: inputSettings,
                  displayAdjustment: widget.displayAdjustment,
                  viewFit: _viewFit,
                  preserveVideoViewportWhenKeyboardVisible: true,
                  onKeyboardModeChanged: _setKeyboardMode,
                  onDragLockChanged: (value) {
                    widget.inputSettings.value = inputSettings.copyWith(
                      dragLock: value,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileClipboardPasteProgress extends StatelessWidget {
  const _FileClipboardPasteProgress({required this.session});

  final RemoteSessionController session;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        if (!session.fileClipboardPastePending) {
          return const SizedBox.shrink();
        }
        final progress = session.fileClipboardPasteTask?.progress;
        final colorScheme = Theme.of(context).colorScheme;
        return Material(
          color: colorScheme.primaryContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.content_paste_go_outlined, size: 18),
                const SizedBox(width: 10),
                Expanded(child: Text(session.fileClipboardPasteStatus)),
                const SizedBox(width: 12),
                SizedBox(
                  width: 120,
                  child: LinearProgressIndicator(value: progress),
                ),
              ],
            ),
          ),
        );
      },
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
    required this.keyboardMode,
    required this.onKeyboardModeSelected,
    required this.textInputMode,
    required this.onTextInputModeSelected,
    required this.onHelp,
    required this.onInputSettings,
    required this.onDisplayAdjustment,
    required this.onFileTransfer,
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
  final RemoteKeyboardMode keyboardMode;
  final ValueChanged<RemoteKeyboardMode> onKeyboardModeSelected;
  final RemoteTextInputMode textInputMode;
  final ValueChanged<RemoteTextInputMode> onTextInputModeSelected;
  final VoidCallback onHelp;
  final VoidCallback onInputSettings;
  final VoidCallback onDisplayAdjustment;
  final VoidCallback onFileTransfer;
  final VoidCallback onFullScreen;
  final Widget? leading;
  final Color? foregroundColor;
  final bool isFullScreen;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final selected = session.selectedDisplay;
        final color =
            foregroundColor ?? Theme.of(context).colorScheme.onSurface;
        return LayoutBuilder(
          builder: (context, constraints) {
            final compact = constraints.maxWidth < 720;
            return IconTheme(
              data: IconThemeData(color: color),
              child: DefaultTextStyle.merge(
                style: TextStyle(color: color),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    children: [
                      ?leading,
                      PopupMenuButton<String>(
                        enabled:
                            session.displays.isNotEmpty &&
                            !session.displaySwitchPending,
                        tooltip: '切换显示器',
                        onSelected: (value) {
                          if (value == '__refresh_displays__') {
                            session.refreshRemoteDisplays();
                            AppMessenger.show('正在刷新远程显示器列表');
                            return;
                          }
                          session.selectDisplay(value);
                        },
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
                          const PopupMenuDivider(),
                          const PopupMenuItem(
                            value: '__refresh_displays__',
                            child: ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(Icons.refresh),
                              title: Text('刷新显示器列表'),
                            ),
                          ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: compact
                              ? SizedBox.square(
                                  dimension: 32,
                                  child: Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      const Icon(
                                        Icons.monitor_outlined,
                                        size: 20,
                                      ),
                                      if (session.displaySwitchPending)
                                        const Positioned(
                                          right: 1,
                                          bottom: 1,
                                          child: SizedBox.square(
                                            dimension: 10,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 1.5,
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                )
                              : SizedBox(
                                  width: 210,
                                  child: Row(
                                    children: [
                                      const Icon(
                                        Icons.monitor_outlined,
                                        size: 20,
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          selected?.name ?? '等待显示器',
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      SizedBox.square(
                                        dimension: 18,
                                        child: session.displaySwitchPending
                                            ? const Padding(
                                                padding: EdgeInsets.all(2),
                                                child:
                                                    CircularProgressIndicator(
                                                      strokeWidth: 1.8,
                                                    ),
                                              )
                                            : const Icon(
                                                Icons.arrow_drop_down,
                                                size: 18,
                                              ),
                                      ),
                                    ],
                                  ),
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
                      if (session.localExplicitFileTransferSupported)
                        Badge.count(
                          isLabelVisible:
                              session.pendingIncomingFileTransferCount > 0,
                          count: session.pendingIncomingFileTransferCount,
                          child: IconButton(
                            tooltip: session.explicitFileTransferReady
                                ? '文件传输'
                                : '文件传输尚未就绪',
                            onPressed: onFileTransfer,
                            icon: const Icon(Icons.swap_horiz),
                          ),
                        ),
                      PopupMenuButton<RemoteQualityProfile>(
                        enabled: !session.qualityPending,
                        tooltip: '传输清晰度：${session.qualityStatusLabel}',
                        initialValue: session.selectedQuality,
                        onSelected: session.selectQuality,
                        itemBuilder: (context) => [
                          for (final profile in RemoteQualityProfile.values)
                            if (!profile.desktopControllerOnly ||
                                Platform.isMacOS ||
                                Platform.isWindows ||
                                Platform.isLinux)
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
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.high_quality_outlined),
                      ),
                      IconButton(
                        tooltip: '显示调整与色彩诊断',
                        onPressed: onDisplayAdjustment,
                        icon: const Icon(Icons.tonality_outlined),
                      ),
                      if ((Platform.isMacOS || Platform.isWindows) &&
                          session.remoteHostPlatform ==
                              HostPlatformType.windows.name &&
                          session.remoteSupportsPhysicalKeyboard)
                        PopupMenuButton<RemoteTextInputMode>(
                          tooltip: '文字输入：${textInputMode.label}',
                          initialValue: textInputMode,
                          onSelected: onTextInputModeSelected,
                          itemBuilder: (context) => [
                            for (final mode in RemoteTextInputMode.values)
                              PopupMenuItem(
                                value: mode,
                                child: ListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  leading: Icon(
                                    mode == textInputMode
                                        ? Icons.check_circle
                                        : Icons.translate,
                                  ),
                                  title: Text(mode.label),
                                  subtitle: Text(
                                    mode == RemoteTextInputMode.remoteIme
                                        ? '直接发送物理按键；请在 Windows 用 Win+Space 选择微软拼音'
                                        : mode.description,
                                  ),
                                ),
                              ),
                          ],
                          icon: Icon(
                            textInputMode == RemoteTextInputMode.remoteIme
                                ? Icons.language
                                : Icons.translate,
                          ),
                        ),
                      PopupMenuButton<RemoteKeyboardMode>(
                        tooltip: session.canSendControl
                            ? (Platform.isWindows
                                  ? '兼容键盘与快捷键'
                                  : '远程键盘：${keyboardMode.label}')
                            : '远程键盘（等待输入权限）',
                        initialValue: keyboardMode,
                        onSelected: onKeyboardModeSelected,
                        itemBuilder: (context) => [
                          for (final mode in RemoteKeyboardMode.values)
                            PopupMenuItem(
                              value: mode,
                              child: ListTile(
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                                leading: Icon(
                                  mode == RemoteKeyboardMode.compact
                                      ? Icons.keyboard_command_key
                                      : Icons.keyboard_outlined,
                                ),
                                title: Text(mode.label),
                                subtitle: Text(
                                  mode == RemoteKeyboardMode.compact
                                      ? '快捷键和方向键，不打开输入法'
                                      : (Platform.isWindows
                                            ? '兼容文本输入；远程画面已支持直接拼音'
                                            : '文字、拼音、符号和表情'),
                                ),
                              ),
                            ),
                        ],
                        icon: Icon(
                          keyboardMode == RemoteKeyboardMode.compact
                              ? Icons.keyboard_command_key
                              : Icons.keyboard_outlined,
                        ),
                      ),
                      IconButton(
                        tooltip: '修复当前画面与控制',
                        onPressed: session.sessionRepairPending
                            ? null
                            : () => unawaited(session.repairRemoteSession()),
                        icon: session.sessionRepairPending
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.refresh),
                      ),
                      IconButton(
                        tooltip: isFullScreen ? '退出全屏' : '进入全屏',
                        onPressed: onFullScreen,
                        icon: Icon(
                          isFullScreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
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
    required this.displayAdjustment,
    required this.viewFit,
    required this.onKeyboardModeChanged,
    required this.onDragLockChanged,
    this.preserveVideoViewportWhenKeyboardVisible = false,
    this.desktopFullScreen = false,
    this.onExitDesktopFullScreen,
  });

  final RemoteSessionController session;
  final RemoteInputSettings inputSettings;
  final RemoteDisplayAdjustmentController displayAdjustment;
  final RemoteViewFit viewFit;
  final ValueChanged<RemoteKeyboardMode> onKeyboardModeChanged;
  final ValueChanged<bool> onDragLockChanged;
  final bool preserveVideoViewportWhenKeyboardVisible;
  final bool desktopFullScreen;
  final VoidCallback? onExitDesktopFullScreen;

  @override
  State<_RemoteDesktopSurface> createState() => _RemoteDesktopSurfaceState();
}

class _RemoteDesktopSurfaceState extends State<_RemoteDesktopSurface>
    with WidgetsBindingObserver {
  final _hardwareFocus = FocusNode(debugLabel: 'remote-hardware-keyboard');
  final _textFocus = FocusNode(debugLabel: 'remote-soft-keyboard');
  final _textController = TextEditingController();
  final _textSynchronizer = RemoteTextInputSynchronizer();
  late final DesktopRemoteImeCoordinator _desktopIme =
      DesktopRemoteImeCoordinator(synchronizer: _textSynchronizer);
  final _desktopKeyboard = RemoteKeyboardTranslator();
  final RemoteImeInputAdapter _nativeIme = MethodChannelRemoteImeInputAdapter();
  final _pointerCoalescer = RemotePointerEventCoalescer();
  final _desktopClickTracker = DesktopMouseClickTracker();
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
  Timer? _switchOverlayDelayTimer;
  Timer? _switchOverlaySlowTimer;
  StreamSubscription<RemoteImeInputEvent>? _imeSubscription;
  late final String _imeClientId;
  final List<String> _imeDiagnostics = [];
  bool _keyboardVisible = false;
  bool _nativeImeFailed = false;
  bool _switchOverlayVisible = false;
  bool _switchOverlaySlow = false;
  bool _lastDisplaySwitchPending = false;
  bool _lastCanSendControl = false;
  bool _presentationGeometryLocked = false;
  int _presentationSwitchToken = 0;
  Size? _committedVideoSourceSize;
  int _compositionLength = 0;
  late RemoteKeyboardMode _activeKeyboardMode;
  Rect _systemKeyboardFrame = Rect.zero;
  bool _systemKeyboardDocked = false;
  Offset _compactKeyboardOffset = Offset.zero;
  final Set<String> _compactModifiers = {};
  final Set<PhysicalKeyboardKey> _primaryShortcutKeys = {};
  RemoteContentTransform? _latestTransform;
  String? _lastPresentationGeometryDiagnostic;
  Offset? _lastNormalizedPointer;
  Offset _desktopImeAnchor = const Offset(24, 24);

  RemoteSessionController get session => widget.session;

  bool get _usesDesktopKeyboard =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux;

  bool get _usesDesktopIme => Platform.isWindows || Platform.isMacOS;

  bool get _remoteHostImeActive =>
      _usesDesktopKeyboard &&
      widget.inputSettings.textInputMode == RemoteTextInputMode.remoteIme &&
      session.remoteHostPlatform == HostPlatformType.windows.name &&
      session.remoteSupportsPhysicalKeyboard;

  bool get _desktopDirectImeAvailable =>
      _usesDesktopIme &&
      !_remoteHostImeActive &&
      !_keyboardVisible &&
      session.canSendControl;

  void requestHardwareKeyboardFocus() {
    if (!mounted) return;
    if (_remoteHostImeActive) {
      _textFocus.unfocus();
      _hardwareFocus.requestFocus();
    } else if (_desktopDirectImeAvailable) {
      unawaited(_activateDesktopDirectIme());
    } else {
      _hardwareFocus.requestFocus();
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _textController.addListener(_textChanged);
    _activeKeyboardMode = widget.inputSettings.keyboardMode;
    _lastDisplaySwitchPending = session.displaySwitchPending;
    _lastCanSendControl = session.canSendControl;
    _committedVideoSourceSize =
        _committedFrameGeometrySourceSize() ?? _currentRendererSourceSize();
    _presentationGeometryLocked = _lastDisplaySwitchPending;
    session.addListener(_handleDisplaySwitchState);
    _imeClientId = 'remote-surface-${identityHashCode(this)}';
    if (Platform.isIOS) {
      _imeSubscription = _nativeIme.events.listen(
        _handleNativeImeEvent,
        onError: _handleNativeImeError,
      );
    }
    if (Platform.isWindows) {
      unawaited(_loadDesktopMouseDoubleClickSettings());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateGestureConfiguration();
      if (_desktopDirectImeAvailable) {
        unawaited(_activateDesktopDirectIme());
      }
    });
    if (_lastDisplaySwitchPending) {
      _presentationSwitchToken += 1;
      _scheduleDisplaySwitchOverlay(
        immediate: _pendingDisplayChangesAspectRatio(),
        rebuild: false,
      );
    }
  }

  Future<void> _loadDesktopMouseDoubleClickSettings() async {
    try {
      final settings =
          await PlatformDesktopWindowModeController.mouseDoubleClickSettings();
      if (mounted) _desktopClickTracker.updateSettings(settings);
    } catch (_) {
      // The conservative defaults remain valid on older Windows runners.
    }
  }

  @override
  void didUpdateWidget(covariant _RemoteDesktopSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.inputSettings != widget.inputSettings) {
      _updateGestureConfiguration();
      if (!_keyboardVisible) {
        _activeKeyboardMode = widget.inputSettings.keyboardMode;
      }
      if (oldWidget.inputSettings.textInputMode !=
          widget.inputSettings.textInputMode) {
        _releaseDesktopKeys();
        _resetTextInput();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) requestHardwareKeyboardFocus();
        });
      }
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

  void showKeyboard([RemoteKeyboardMode? mode]) {
    if (!session.canSendControl) {
      session.explainControlUnavailable();
      return;
    }
    final nextMode = mode ?? widget.inputSettings.keyboardMode;
    if (nextMode == RemoteKeyboardMode.system && _remoteHostImeActive) {
      setState(() {
        _activeKeyboardMode = nextMode;
        _keyboardVisible = false;
      });
      _releaseDesktopKeys();
      _textFocus.unfocus();
      _hardwareFocus.requestFocus();
      AppMessenger.show('已使用被控端 Windows 输入法，可直接键入拼音');
      return;
    }
    if (nextMode == RemoteKeyboardMode.compact) {
      if ((_keyboardVisible &&
              _activeKeyboardMode == RemoteKeyboardMode.system) ||
          _usesDesktopIme) {
        if (Platform.isIOS) {
          unawaited(_hideNativeIme());
        } else {
          _textFocus.unfocus();
          SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        }
      }
      setState(() {
        _activeKeyboardMode = nextMode;
        _keyboardVisible = true;
        _compositionLength = 0;
        _systemKeyboardFrame = Rect.zero;
        _systemKeyboardDocked = false;
      });
      _hardwareFocus.requestFocus();
      AppMessenger.show('快捷小键盘已打开，可拖动并使用常用组合键');
      return;
    }
    setState(() {
      _activeKeyboardMode = nextMode;
      _keyboardVisible = true;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_activateKeyboard());
    });
  }

  void _hideKeyboard() {
    if (_activeKeyboardMode == RemoteKeyboardMode.system) {
      if (Platform.isIOS) {
        unawaited(_hideNativeIme());
      } else {
        _textFocus.unfocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
    }
    if (mounted) {
      setState(() {
        _keyboardVisible = false;
        _compositionLength = 0;
        _systemKeyboardFrame = Rect.zero;
        _systemKeyboardDocked = false;
        _compactModifiers.clear();
      });
      if (_usesDesktopIme) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_activateDesktopDirectIme());
        });
      }
    }
  }

  void _handleDisplaySwitchState() {
    final canSendControl = session.canSendControl;
    if (_lastCanSendControl && !canSendControl) {
      _desktopClickTracker.reset();
    }
    _lastCanSendControl = canSendControl;
    final pending = session.displaySwitchPending;
    if (pending == _lastDisplaySwitchPending) return;
    _lastDisplaySwitchPending = pending;
    if (pending) {
      _longPressTimer?.cancel();
      _pointerFlushTimer?.cancel();
      _pointerFlushTimer = null;
      _pointerCoalescer.clear();
      _gestures.cancelAll(releaseDragLock: true);
      _ignoredPointers.clear();
      _mouseButtons.clear();
      _lastNormalizedPointer = null;
      _desktopClickTracker.reset();
      final rendererSize = _currentRendererSourceSize();
      if (rendererSize != null) _committedVideoSourceSize = rendererSize;
      _presentationGeometryLocked = true;
      _presentationSwitchToken += 1;
      _scheduleDisplaySwitchOverlay(
        immediate: _pendingDisplayChangesAspectRatio(),
      );
      return;
    }
    _switchOverlayDelayTimer?.cancel();
    _switchOverlaySlowTimer?.cancel();
    unawaited(_commitDisplaySwitchPresentation(_presentationSwitchToken));
  }

  void _scheduleDisplaySwitchOverlay({
    required bool immediate,
    bool rebuild = true,
  }) {
    _switchOverlayDelayTimer?.cancel();
    _switchOverlaySlowTimer?.cancel();
    void updateInitialState() {
      _switchOverlayVisible = immediate;
      _switchOverlaySlow = false;
    }

    if (rebuild && mounted) {
      setState(updateInitialState);
    } else {
      updateInitialState();
    }
    if (!immediate) {
      _switchOverlayDelayTimer = Timer(const Duration(milliseconds: 120), () {
        if (!mounted || !session.displaySwitchPending) return;
        setState(() => _switchOverlayVisible = true);
      });
    }
    _switchOverlaySlowTimer = Timer(const Duration(milliseconds: 800), () {
      if (!mounted || !session.displaySwitchPending) return;
      setState(() {
        _switchOverlayVisible = true;
        _switchOverlaySlow = true;
      });
    });
  }

  Future<void> _commitDisplaySwitchPresentation(int token) async {
    // The session controller clears displaySwitchPending only after the target
    // key frame, RTP geometry, and platform renderer geometry are stable.
    // Commit that already-validated geometry in one layout pass, then reveal
    // it on the following Flutter frame.
    if (!mounted ||
        session.displaySwitchPending ||
        token != _presentationSwitchToken) {
      return;
    }
    final geometrySize = _committedFrameGeometrySourceSize();
    final fallbackSize = _selectedDisplaySourceSize();
    setState(() {
      _committedVideoSourceSize = geometrySize ?? fallbackSize;
      _presentationGeometryLocked = false;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        session.displaySwitchPending ||
        token != _presentationSwitchToken) {
      return;
    }
    if (_switchOverlayVisible || _switchOverlaySlow) {
      setState(() {
        _switchOverlayVisible = false;
        _switchOverlaySlow = false;
      });
    }
  }

  Size? _currentRendererSourceSize() {
    final renderer = session.remoteRenderer.value;
    if (renderer.width <= 0 || renderer.height <= 0) return null;
    return Size(renderer.width, renderer.height);
  }

  RemoteFrameGeometry? _committedFrameGeometry() {
    final geometry = session.committedFrameGeometry;
    final renderedDisplayId = session.renderedDisplayId;
    if (geometry == null ||
        !geometry.isValid ||
        renderedDisplayId == null ||
        geometry.displayId != renderedDisplayId) {
      return null;
    }
    return geometry;
  }

  Size? _committedFrameGeometrySourceSize() {
    final geometry = _committedFrameGeometry();
    if (geometry == null) return null;
    return Size(
      geometry.encodedWidth.toDouble(),
      geometry.encodedHeight.toDouble(),
    );
  }

  Size _selectedDisplaySourceSize() {
    final display = session.selectedDisplay;
    return Size(
      (display?.captureWidth ?? 16).toDouble(),
      (display?.captureHeight ?? 10).toDouble(),
    );
  }

  bool _pendingDisplayChangesAspectRatio() {
    RemoteDisplay? current;
    RemoteDisplay? target;
    for (final display in session.displays) {
      if (display.id ==
          (session.renderedDisplayId ?? session.selectedDisplayId)) {
        current = display;
      }
      if (display.id == session.pendingDisplayId) target = display;
    }
    if (current == null || target == null) return true;
    return remoteAspectRatiosDiffer(
      Size(current.captureWidth.toDouble(), current.captureHeight.toDouble()),
      Size(target.captureWidth.toDouble(), target.captureHeight.toDouble()),
    );
  }

  void _changeKeyboardMode(RemoteKeyboardMode mode) {
    widget.onKeyboardModeChanged(mode);
    showKeyboard(mode);
  }

  void _toggleCompactModifier(String modifier) {
    setState(() {
      if (!_compactModifiers.remove(modifier)) {
        _compactModifiers.add(modifier);
      }
    });
  }

  void _sendCompactKey(String key, [List<String>? fixedModifiers]) {
    final modifiers =
        fixedModifiers ?? _compactModifiers.toList(growable: false);
    session.sendKey(phase: 'down', key: key, modifiers: modifiers);
    session.sendKey(phase: 'up', key: key, modifiers: modifiers);
    unawaited(HapticFeedback.selectionClick());
  }

  void _sendPrimaryShortcut(String key) {
    unawaited(session.sendPrimaryShortcut(key));
    unawaited(HapticFeedback.selectionClick());
  }

  void _moveCompactKeyboard(
    DragUpdateDetails details,
    BoxConstraints constraints,
  ) {
    final horizontalLimit = (constraints.maxWidth - 120).clamp(0.0, 720.0) / 2;
    final verticalLimit = (constraints.maxHeight - 100).clamp(0.0, 720.0);
    setState(() {
      _compactKeyboardOffset = Offset(
        (_compactKeyboardOffset.dx + details.delta.dx).clamp(
          -horizontalLimit,
          horizontalLimit,
        ),
        (_compactKeyboardOffset.dy + details.delta.dy).clamp(
          -verticalLimit,
          0.0,
        ),
      );
    });
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
    await _activateFlutterKeyboard();
    if (announce) {
      AppMessenger.show(
        Platform.isIOS ? '原生键盘不可用，已切换兼容输入模式' : '远程键盘已打开',
        level: Platform.isIOS ? AppMessageLevel.warning : AppMessageLevel.info,
      );
    }
  }

  Future<void> _activateFlutterKeyboard() async {
    _resetTextInput();
    _textFocus.requestFocus();
    // Desktop platforms must attach EditableText as the active TextInputClient
    // before their input method starts emitting composition updates. Opening
    // the connection in the same microtask can lose the first composition.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted ||
        !_keyboardVisible ||
        _activeKeyboardMode != RemoteKeyboardMode.system) {
      return;
    }
    _textFocus.requestFocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  Future<void> _activateDesktopDirectIme() async {
    if (!_desktopDirectImeAvailable) return;
    _textFocus.requestFocus();
    // The transparent EditableText must finish attaching before the desktop
    // input method sends its first composition update. Keeping this client
    // mounted also preserves IME focus across geometry/full-screen changes.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || !_desktopDirectImeAvailable) return;
    _textFocus.requestFocus();
    await SystemChannels.textInput.invokeMethod<void>('TextInput.show');
  }

  void _suspendDesktopDirectIme() {
    if (!_usesDesktopIme || _keyboardVisible) return;
    _textFocus.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    _resetTextInput(rebuildComposition: false);
  }

  Future<void> _hideNativeIme() async {
    try {
      await _nativeIme.hide(clientId: _imeClientId);
    } catch (_) {
      // A failed bridge has already switched the UI to the Flutter fallback.
    }
  }

  void _handleNativeImeEvent(RemoteImeInputEvent event) {
    if (!mounted ||
        event.clientId != _imeClientId ||
        !_keyboardVisible ||
        _activeKeyboardMode != RemoteKeyboardMode.system) {
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
      case RemoteImeInputEventType.keyboardFrame:
        if (_systemKeyboardFrame != event.keyboardFrame ||
            _systemKeyboardDocked != event.keyboardDocked) {
          setState(() {
            _systemKeyboardFrame = event.keyboardVisible
                ? event.keyboardFrame
                : Rect.zero;
            _systemKeyboardDocked =
                event.keyboardVisible && event.keyboardDocked;
          });
        }
    }
  }

  void _handleNativeImeError(Object error, [StackTrace? stackTrace]) {
    if (!mounted || _nativeImeFailed) return;
    setState(() => _nativeImeFailed = true);
    if (_keyboardVisible && _activeKeyboardMode == RemoteKeyboardMode.system) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_activateFlutterKeyboard());
      });
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_usesDesktopKeyboard && state != AppLifecycleState.resumed) {
      _releaseDesktopKeys();
    }
    if (_usesDesktopIme && state != AppLifecycleState.resumed) {
      _suspendDesktopDirectIme();
    }
    if (_keyboardVisible &&
        const {
          AppLifecycleState.inactive,
          AppLifecycleState.paused,
          AppLifecycleState.detached,
          AppLifecycleState.hidden,
        }.contains(state)) {
      _hideKeyboard();
    }
    if (_usesDesktopKeyboard &&
        state == AppLifecycleState.resumed &&
        (_usesDesktopIme || widget.desktopFullScreen)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        requestHardwareKeyboardFocus();
      });
    }
  }

  void _handleHardwareFocusChanged(bool focused) {
    if (_usesDesktopKeyboard && !focused) {
      _releaseDesktopKeys();
    }
  }

  void _releaseDesktopKeys() {
    _primaryShortcutKeys.clear();
    for (final action in _desktopKeyboard.releaseAll()) {
      _dispatchKeyboardAction(action);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _pointerFlushTimer?.cancel();
    _switchOverlayDelayTimer?.cancel();
    _switchOverlaySlowTimer?.cancel();
    session.removeListener(_handleDisplaySwitchState);
    unawaited(_imeSubscription?.cancel());
    _dispatchGestureActions(_gestures.cancelAll(releaseDragLock: true));
    _desktopClickTracker.reset();
    _flushPointerMotion();
    _releaseDesktopKeys();
    if ((_keyboardVisible &&
            _activeKeyboardMode == RemoteKeyboardMode.system) ||
        (_usesDesktopIme && _textFocus.hasFocus)) {
      if (Platform.isIOS) {
        unawaited(_hideNativeIme());
      } else {
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      }
    }
    _hardwareFocus.dispose();
    _textFocus.dispose();
    _textController.removeListener(_textChanged);
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
          final rendererSize = Size(renderer.width, renderer.height);
          final fallbackSize = _selectedDisplaySourceSize();
          final frameGeometry = _committedFrameGeometry();
          final geometrySourceSize = frameGeometry == null
              ? null
              : Size(
                  frameGeometry.encodedWidth.toDouble(),
                  frameGeometry.encodedHeight.toDouble(),
                );
          final sourceSize = resolveRemotePresentationSourceSize(
            rendererSize: rendererSize,
            fallbackSize: fallbackSize,
            committedSize: geometrySourceSize ?? _committedVideoSourceSize,
            geometryLocked: _presentationGeometryLocked,
          );
          if (_committedVideoSourceSize == null &&
              !_presentationGeometryLocked &&
              !rendererSize.isEmpty) {
            _committedVideoSourceSize = rendererSize;
          }
          final boxFit = widget.viewFit == RemoteViewFit.contain
              ? BoxFit.contain
              : BoxFit.cover;
          // The remote canvas keeps a stable size while either keyboard floats
          // above it. Resizing this viewport changes the pointer transform and
          // makes the remote desktop unreadably small in full-screen mode.
          final viewportHeight = constraints.maxHeight;
          final transform = RemoteContentTransform.forViewport(
            sourceSize: sourceSize,
            viewportSize: Size(constraints.maxWidth, viewportHeight),
            fit: boxFit,
            activeContentRect: frameGeometry == null
                ? null
                : Rect.fromLTWH(
                    frameGeometry.activeContentX,
                    frameGeometry.activeContentY,
                    frameGeometry.activeContentWidth,
                    frameGeometry.activeContentHeight,
                  ),
          );
          _latestTransform = transform;
          _logPresentationGeometry(
            transform: transform,
            viewportSize: Size(constraints.maxWidth, viewportHeight),
            rendererSize: rendererSize,
            frameGeometry: frameGeometry,
          );
          return Focus(
            focusNode: _hardwareFocus,
            autofocus: true,
            onFocusChange: _handleHardwareFocusChanged,
            onKeyEvent: _handleKeyEvent,
            child: MouseRegion(
              onEnter: (_) {
                if (_desktopDirectImeAvailable) {
                  unawaited(_activateDesktopDirectIme());
                } else if (_usesDesktopKeyboard && !_textFocus.hasFocus) {
                  _hardwareFocus.requestFocus();
                }
              },
              child: Stack(
                fit: StackFit.expand,
                clipBehavior: Clip.hardEdge,
                children: [
                  const ColoredBox(color: Colors.black),
                  Positioned.fromRect(
                    rect: transform.destinationRect,
                    child: ValueListenableBuilder<RemoteDisplayAdjustment>(
                      valueListenable: widget.displayAdjustment,
                      builder: (context, adjustment, child) {
                        if (adjustment.isIdentity) return child!;
                        return ColorFiltered(
                          colorFilter: ColorFilter.matrix(
                            adjustment.colorMatrix,
                          ),
                          child: child!,
                        );
                      },
                      child:
                          usesCropAwareRemoteTexture(Platform.operatingSystem)
                          ? _RemoteVideoTexture(
                              renderer: session.remoteRenderer,
                              encodedSize: transform.sourceSize,
                              visibleSourceRect: transform.sourceRect,
                            )
                          : RTCVideoView(
                              session.remoteRenderer,
                              key: const ValueKey('remoteVideoView'),
                              // Other controllers retain the legacy view until
                              // their native texture path is physically tested.
                              objectFit: RTCVideoViewObjectFit
                                  .RTCVideoViewObjectFitCover,
                            ),
                    ),
                  ),
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: (event) => _pointerDown(event, transform),
                      onPointerMove: (event) => _pointerMove(event, transform),
                      onPointerUp: (event) => _pointerUp(event, transform),
                      onPointerCancel: (event) =>
                          _pointerCancel(event, transform),
                      onPointerHover: (event) =>
                          _pointerHover(event, transform),
                      onPointerSignal: (event) =>
                          _pointerSignal(event, transform),
                      child: const SizedBox.expand(),
                    ),
                  ),
                  if (_desktopDirectImeAvailable)
                    _buildDesktopImeProxy(constraints),
                  if (session.sessionRepairPending)
                    const Positioned.fill(
                      child: AbsorbPointer(
                        child: ColoredBox(
                          color: Color(0x66000000),
                          child: Center(
                            child: Card(
                              child: Padding(
                                padding: EdgeInsets.symmetric(
                                  horizontal: 20,
                                  vertical: 14,
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                    SizedBox(width: 12),
                                    Text('正在修复当前画面与控制状态'),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
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
                  if (_keyboardVisible &&
                      _activeKeyboardMode == RemoteKeyboardMode.system)
                    _buildSystemKeyboardBar(context),
                  if (_keyboardVisible &&
                      _activeKeyboardMode == RemoteKeyboardMode.compact)
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Transform.translate(
                        offset: _compactKeyboardOffset,
                        child: _CompactRemoteKeyboard(
                          modifiers: _compactModifiers,
                          primaryShortcutLabel:
                              session.remotePrimaryShortcutLabel,
                          commandLabel: RemoteShortcutPolicy.commandLabel(
                            session.remoteHostPlatform,
                          ),
                          onDragUpdate: (details) =>
                              _moveCompactKeyboard(details, constraints),
                          onModifierChanged: _toggleCompactModifier,
                          onKey: _sendCompactKey,
                          onPrimaryShortcut: _sendPrimaryShortcut,
                          onSystemKeyboard: () =>
                              _changeKeyboardMode(RemoteKeyboardMode.system),
                          onClose: _hideKeyboard,
                        ),
                      ),
                    ),
                  Positioned.fill(
                    child: IgnorePointer(
                      ignoring:
                          !session.displaySwitchPending &&
                          !_switchOverlayVisible,
                      child: AnimatedOpacity(
                        opacity: _switchOverlayVisible ? 1 : 0,
                        duration: const Duration(milliseconds: 120),
                        curve: Curves.easeOut,
                        child: _DisplaySwitchOverlay(
                          displayName: session.displays
                              .where(
                                (item) => item.id == session.pendingDisplayId,
                              )
                              .firstOrNull
                              ?.name,
                          takingLonger: _switchOverlaySlow,
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

  void _logPresentationGeometry({
    required RemoteContentTransform transform,
    required Size viewportSize,
    required Size rendererSize,
    required RemoteFrameGeometry? frameGeometry,
  }) {
    if (!kDebugMode) return;
    String sizeLabel(Size size) =>
        '${size.width.toStringAsFixed(0)}x${size.height.toStringAsFixed(0)}';
    String rectLabel(Rect rect) =>
        '${rect.left.toStringAsFixed(1)},${rect.top.toStringAsFixed(1)} '
        '${rect.width.toStringAsFixed(1)}x${rect.height.toStringAsFixed(1)}';
    final diagnostic =
        'platform=${Platform.operatingSystem} '
        'display=${frameGeometry?.displayId ?? session.renderedDisplayId ?? 'unknown'} '
        'generation=${frameGeometry?.generation ?? 0} '
        'renderer=${sizeLabel(rendererSize)} '
        'encoded=${sizeLabel(transform.sourceSize)} '
        'active=${rectLabel(transform.activeContentRect)} '
        'source=${rectLabel(transform.sourceRect)} '
        'destination=${rectLabel(transform.destinationRect)} '
        'viewport=${sizeLabel(viewportSize)}';
    if (diagnostic == _lastPresentationGeometryDiagnostic) return;
    _lastPresentationGeometryDiagnostic = diagnostic;
    debugPrint('CrossDesktopRemote presentation geometry: $diagnostic');
  }

  Widget _buildDesktopImeProxy(BoxConstraints constraints) {
    const proxyWidth = 180.0;
    const proxyHeight = 28.0;
    final maximumLeft = (constraints.maxWidth - proxyWidth - 8).clamp(
      8.0,
      double.infinity,
    );
    final maximumTop = (constraints.maxHeight - proxyHeight - 8).clamp(
      8.0,
      double.infinity,
    );
    final left = _desktopImeAnchor.dx.clamp(8.0, maximumLeft);
    final top = _desktopImeAnchor.dy.clamp(8.0, maximumTop);
    return Positioned(
      left: left,
      top: top,
      width: proxyWidth,
      height: proxyHeight,
      child: ExcludeSemantics(
        child: IgnorePointer(
          child: Opacity(
            // Keep a real laid-out EditableText so the desktop IME can position
            // its candidate window near the last remote click. Text and cursor
            // stay transparent so no local editor is exposed.
            opacity: 0.01,
            child: TextField(
              key: const ValueKey('desktopRemoteImeProxy'),
              focusNode: _textFocus,
              controller: _textController,
              autocorrect: true,
              enableSuggestions: true,
              enableInteractiveSelection: false,
              maxLines: 1,
              showCursor: false,
              style: const TextStyle(color: Colors.transparent, fontSize: 14),
              cursorColor: Colors.transparent,
              decoration: const InputDecoration.collapsed(hintText: ''),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSystemKeyboardBar(BuildContext context) {
    final reportedInset = _systemKeyboardDocked
        ? _systemKeyboardFrame.height
        : 0.0;
    final mediaInset = MediaQuery.viewInsetsOf(context).bottom;
    final bottomInset = widget.preserveVideoViewportWhenKeyboardVisible
        ? (reportedInset > mediaInset ? reportedInset : mediaInset)
        : 0.0;
    final floating =
        _systemKeyboardFrame != Rect.zero &&
        !_systemKeyboardDocked &&
        widget.preserveVideoViewportWhenKeyboardVisible;
    return Positioned(
      left: 8,
      right: 8,
      top: floating ? 8 : null,
      bottom: floating ? null : bottomInset + 8,
      child: SafeArea(
        top: floating,
        bottom: !floating && bottomInset == 0,
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
                      onTap: () =>
                          unawaited(_activateKeyboard(announce: false)),
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
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _compositionLength > 0
                                        ? '正在组合输入（$_compositionLength）'
                                        : '即时远程键盘',
                                  ),
                                  const Text(
                                    '画面保持原尺寸；提交后立即发送',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
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
                      autofocus: _usesDesktopIme,
                      autocorrect: true,
                      enableSuggestions: true,
                      maxLines: 1,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: _usesDesktopIme
                            ? (_compositionLength > 0
                                  ? '输入法组合中（$_compositionLength）'
                                  : '桌面端兼容文本输入')
                            : '兼容输入',
                        helperText: _usesDesktopIme
                            ? '远程画面已支持直接输入；此输入框仅作兼容后备'
                            : null,
                        prefixIcon: const Icon(Icons.keyboard_outlined),
                      ),
                      onTap: _keepTextSelectionAtEnd,
                      onTapOutside: _usesDesktopIme
                          ? (_) {
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted &&
                                    _keyboardVisible &&
                                    _activeKeyboardMode ==
                                        RemoteKeyboardMode.system) {
                                  _textFocus.requestFocus();
                                }
                              });
                            }
                          : null,
                      onSubmitted: _usesDesktopIme
                          ? null
                          : (_) {
                              _sendSpecialKey('Enter');
                              _textFocus.requestFocus();
                            },
                    ),
                  ),
                IconButton(
                  tooltip: '快捷小键盘',
                  onPressed: () =>
                      _changeKeyboardMode(RemoteKeyboardMode.compact),
                  icon: const Icon(Icons.keyboard_command_key),
                ),
                IconButton(
                  tooltip: '本地编辑后发送（兼容）',
                  onPressed: _showComposedTextDialog,
                  icon: const Icon(Icons.edit_note),
                ),
                IconButton(
                  tooltip: '远程退格',
                  onPressed: () => _sendSpecialKey('Backspace'),
                  icon: const Icon(Icons.backspace_outlined),
                ),
                if (kDebugMode && Platform.isIOS && !_nativeImeFailed)
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
    );
  }

  void _pointerDown(PointerDownEvent event, RemoteContentTransform transform) {
    if (!session.canSendControl) {
      session.explainControlUnavailable();
      return;
    }
    if (_desktopDirectImeAvailable) {
      final nextAnchor = event.localPosition;
      if ((_desktopImeAnchor - nextAnchor).distanceSquared > 16) {
        setState(() => _desktopImeAnchor = nextAnchor);
      }
      unawaited(_activateDesktopDirectIme());
    } else if (_usesDesktopKeyboard &&
        _keyboardVisible &&
        _activeKeyboardMode == RemoteKeyboardMode.system) {
      // Clicking the remote desktop must not detach the TextInputClient while
      // the user is selecting candidates in a desktop input method.
      _textFocus.requestFocus();
    } else {
      _hardwareFocus.requestFocus();
    }
    if (event.kind == PointerDeviceKind.mouse ||
        event.kind == PointerDeviceKind.trackpad) {
      final normalized = transform.normalize(event.localPosition);
      if (normalized == null) return;
      _lastNormalizedPointer = normalized;
      final button = event.buttons & kSecondaryMouseButton != 0
          ? 'right'
          : 'left';
      final clickCount = _desktopClickTracker.pointerDown(
        pointer: event.pointer,
        button: button,
        displayId: session.renderedDisplayId ?? session.selectedDisplayId,
        position: event.localPosition,
        time: DateTime.now(),
      );
      _mouseButtons[event.pointer] = button;
      _sendPointerNow(
        RemotePointerPacket(
          phase: 'down',
          x: normalized.dx,
          y: normalized.dy,
          button: button,
          clickCount: clickCount,
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
      _desktopClickTracker.pointerMove(
        pointer: event.pointer,
        position: event.localPosition,
      );
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
      final clickCount = _desktopClickTracker.pointerUp(
        pointer: event.pointer,
        position: event.localPosition,
        time: DateTime.now(),
      );
      if (normalized != null) {
        _sendPointerNow(
          RemotePointerPacket(
            phase: 'up',
            x: normalized.dx,
            y: normalized.dy,
            button: button,
            clickCount: clickCount,
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
      final clickCount = _desktopClickTracker.pointerCancel(event.pointer);
      if (normalized != null) {
        _sendPointerNow(
          RemotePointerPacket(
            phase: 'up',
            x: normalized.dx,
            y: normalized.dy,
            button: button,
            clickCount: clickCount,
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
    if (_handlePrimaryShortcut(event)) return KeyEventResult.handled;
    if (_remoteHostImeActive) {
      if (widget.desktopFullScreen &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) widget.onExitDesktopFullScreen?.call();
        return KeyEventResult.handled;
      }
      final actions = _desktopKeyboard.translate(
        event,
        modifiers: _remoteModifiers(HardwareKeyboard.instance),
        physicalOnly: true,
      );
      for (final action in actions) {
        _dispatchKeyboardAction(action);
      }
      return actions.isEmpty ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    if (_textFocus.hasFocus) {
      if (!_usesDesktopIme || _desktopIme.isComposing) {
        // Let the active IME own candidate selection, cancellation and editing.
        return KeyEventResult.ignored;
      }
      if (widget.desktopFullScreen &&
          event.logicalKey == LogicalKeyboardKey.escape) {
        if (event is KeyDownEvent) widget.onExitDesktopFullScreen?.call();
        return KeyEventResult.handled;
      }
      final keyboard = HardwareKeyboard.instance;
      final modifiers = _remoteModifiers(keyboard);
      final shortcut = _remoteShortcutPressed(keyboard);
      final shouldRoute = _desktopIme.shouldRouteToRemote(
        event,
        shortcutPressed: shortcut,
        remoteKeyIsPressed: _desktopKeyboard.isPressed(event.physicalKey),
      );
      if (!shouldRoute) {
        // Printable input goes through EditableText so the local input method
        // can produce a composing range and one committed Unicode result.
        return KeyEventResult.ignored;
      }
      if (_desktopIme.shouldResetBufferBefore(event)) {
        _resetTextInput();
      }
      final actions = _desktopKeyboard.translate(event, modifiers: modifiers);
      for (final action in actions) {
        _dispatchKeyboardAction(action);
      }
      return actions.isEmpty ? KeyEventResult.ignored : KeyEventResult.handled;
    }
    if (widget.desktopFullScreen &&
        event.logicalKey == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) widget.onExitDesktopFullScreen?.call();
      return KeyEventResult.handled;
    }
    final keyboard = HardwareKeyboard.instance;
    final modifiers = _remoteModifiers(keyboard);
    if (_usesDesktopKeyboard) {
      final actions = _desktopKeyboard.translate(event, modifiers: modifiers);
      for (final action in actions) {
        _dispatchKeyboardAction(action);
      }
      return actions.isEmpty ? KeyEventResult.ignored : KeyEventResult.handled;
    }

    // Keep the established mobile hardware-keyboard behavior unchanged.
    final keyName = remoteKeyName(event.logicalKey);
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

  bool _handlePrimaryShortcut(KeyEvent event) {
    if (event is KeyUpEvent && _primaryShortcutKeys.remove(event.physicalKey)) {
      return true;
    }
    final wireKey = RemoteShortcutPolicy.commonWireKey(event.logicalKey);
    if (wireKey == null) return false;
    final keyboard = HardwareKeyboard.instance;
    final primaryPressed = RemoteShortcutPolicy.localPrimaryPressed(
      platform: currentRemoteControllerPlatform(),
      metaPressed: keyboard.isMetaPressed,
      controlPressed: keyboard.isControlPressed,
    );
    if (!primaryPressed || keyboard.isAltPressed || keyboard.isShiftPressed) {
      return false;
    }
    if (event is KeyDownEvent && _primaryShortcutKeys.add(event.physicalKey)) {
      unawaited(session.sendPrimaryShortcut(wireKey));
    }
    return event is KeyDownEvent || event is KeyRepeatEvent;
  }

  List<String> _remoteModifiers(HardwareKeyboard keyboard) => <String>[
    if (keyboard.isMetaPressed) 'command',
    if (keyboard.isControlPressed) 'control',
    if (keyboard.isAltPressed) 'option',
    if (keyboard.isShiftPressed) 'shift',
  ];

  bool _remoteShortcutPressed(HardwareKeyboard keyboard) {
    final altGraph =
        keyboard.isControlPressed &&
        keyboard.isAltPressed &&
        keyboard.logicalKeysPressed.contains(LogicalKeyboardKey.altRight);
    return keyboard.isMetaPressed ||
        (!altGraph && (keyboard.isControlPressed || keyboard.isAltPressed));
  }

  void _dispatchKeyboardAction(RemoteKeyboardAction action) {
    switch (action.type) {
      case RemoteKeyboardActionType.key:
        session.sendKey(
          phase: action.phase!,
          key: action.key!,
          modifiers: action.modifiers,
          physicalHidUsage: action.physicalHidUsage,
          repeat: action.repeat,
        );
      case RemoteKeyboardActionType.text:
        final text = action.text;
        if (text != null && text.isNotEmpty) session.sendText(text);
    }
  }

  void _textChanged() {
    final value = _textController.value;
    final edit = _usesDesktopIme
        ? _desktopIme.update(value)
        : _textSynchronizer.update(value);
    final composing = value.composing;
    final compositionLength = _usesDesktopIme
        ? _desktopIme.compositionLength
        : (composing.isValid && !composing.isCollapsed
              ? composing.end - composing.start
              : 0);
    if (_compositionLength != compositionLength && mounted) {
      setState(() => _compositionLength = compositionLength);
    }
    for (var index = 0; index < edit.backspaceCount; index += 1) {
      _sendSpecialKey('Backspace');
    }
    if (edit.insertedText.isNotEmpty) {
      session.sendText(edit.insertedText);
    }
    final shouldCompact = _usesDesktopIme
        ? _desktopIme.shouldCompact()
        : _textSynchronizer.shouldCompact();
    if (shouldCompact &&
        (!value.composing.isValid || value.composing.isCollapsed)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resetTextInput();
      });
    }
  }

  void _resetTextInput({bool rebuildComposition = true}) {
    if (_usesDesktopIme) {
      _desktopIme.reset();
    } else {
      _textSynchronizer.reset();
    }
    _textController.clear();
    if (_compositionLength != 0) {
      if (rebuildComposition && mounted) {
        setState(() => _compositionLength = 0);
      } else {
        _compositionLength = 0;
      }
    }
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
    final text = await showRemoteComposedTextEditor(context);
    if (!mounted) return;
    if (text != null && text.isNotEmpty) {
      session.sendText(text);
      AppMessenger.show(
        '本地编辑文本已发送（${text.runes.length} 个字符）',
        level: AppMessageLevel.success,
      );
    }
    if (_keyboardVisible && _activeKeyboardMode == RemoteKeyboardMode.system) {
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
}

class _RemoteVideoTexture extends StatelessWidget {
  const _RemoteVideoTexture({
    required this.renderer,
    required this.encodedSize,
    required this.visibleSourceRect,
  });

  final RTCVideoRenderer renderer;
  final Size encodedSize;
  final Rect visibleSourceRect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportSize = Size(constraints.maxWidth, constraints.maxHeight);
        final layout = RemoteTextureCropLayout.forViewport(
          encodedSize: encodedSize,
          visibleSourceRect: visibleSourceRect,
          viewportSize: viewportSize,
        );
        final textureId = renderer.textureId;
        if (!renderer.renderVideo ||
            textureId == null ||
            layout.fullTextureRect.isEmpty) {
          return const ColoredBox(color: Colors.black);
        }
        return ClipRect(
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned.fromRect(
                rect: layout.fullTextureRect,
                child: Texture(
                  textureId: textureId,
                  filterQuality: FilterQuality.medium,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _DisplaySwitchOverlay extends StatelessWidget {
  const _DisplaySwitchOverlay({
    required this.displayName,
    required this.takingLonger,
  });

  final String? displayName;
  final bool takingLonger;

  @override
  Widget build(BuildContext context) {
    final target = displayName?.trim();
    return ColoredBox(
      // Geometry is committed underneath this surface before fade-out. It must
      // be fully opaque or users can still see the old and target aspect ratios
      // resize through the transition.
      color: Colors.black,
      child: Center(
        child: Semantics(
          liveRegion: true,
          label: takingLonger ? '等待目标显示器画面' : '正在切换显示器',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (takingLonger)
                const SizedBox.square(
                  dimension: 30,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    color: Colors.white,
                  ),
                )
              else
                const Icon(
                  Icons.screenshot_monitor_outlined,
                  color: Colors.white,
                  size: 34,
                ),
              const SizedBox(height: 14),
              Text(
                target == null || target.isEmpty
                    ? '正在切换远程显示器'
                    : '正在切换到 $target',
                style: Theme.of(context).textTheme.titleMedium
                    ?.copyWith(color: Colors.white),
              ),
              if (takingLonger) ...[
                const SizedBox(height: 6),
                const Text(
                  '等待目标画面解码完成…',
                  style: TextStyle(color: Colors.white70),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _CompactRemoteKeyboard extends StatelessWidget {
  const _CompactRemoteKeyboard({
    required this.modifiers,
    required this.primaryShortcutLabel,
    required this.commandLabel,
    required this.onDragUpdate,
    required this.onModifierChanged,
    required this.onKey,
    required this.onPrimaryShortcut,
    required this.onSystemKeyboard,
    required this.onClose,
  });

  final Set<String> modifiers;
  final String primaryShortcutLabel;
  final String commandLabel;
  final GestureDragUpdateCallback onDragUpdate;
  final ValueChanged<String> onModifierChanged;
  final void Function(String key, List<String>? modifiers) onKey;
  final ValueChanged<String> onPrimaryShortcut;
  final VoidCallback onSystemKeyboard;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.all(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Material(
          elevation: 14,
          color: Theme.of(context).colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 6, 10, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanUpdate: onDragUpdate,
                  child: Row(
                    children: [
                      const Icon(Icons.drag_indicator, size: 20),
                      const SizedBox(width: 6),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text('快捷小键盘'),
                            Text(
                              '可拖动；文字和拼音请切换系统键盘',
                              style: TextStyle(fontSize: 11),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '系统完整键盘',
                        onPressed: onSystemKeyboard,
                        icon: const Icon(Icons.keyboard_outlined),
                      ),
                      IconButton(
                        visualDensity: VisualDensity.compact,
                        tooltip: '关闭快捷小键盘',
                        onPressed: onClose,
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 10),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final item in [
                      ('command', commandLabel),
                      const ('control', 'Ctrl'),
                      const ('option', 'Option'),
                      const ('shift', '⇧'),
                    ])
                      FilterChip(
                        label: Text(item.$2),
                        selected: modifiers.contains(item.$1),
                        onSelected: (_) => onModifierChanged(item.$1),
                      ),
                    _CompactKeyButton(
                      label: 'Esc',
                      onPressed: () => onKey('Escape', null),
                    ),
                    _CompactKeyButton(
                      label: 'Tab',
                      onPressed: () => onKey('Tab', null),
                    ),
                    _CompactKeyButton(
                      label: 'Enter',
                      onPressed: () => onKey('Enter', null),
                    ),
                    _CompactKeyButton(
                      icon: Icons.backspace_outlined,
                      tooltip: '退格',
                      onPressed: () => onKey('Backspace', null),
                    ),
                    _CompactKeyButton(
                      label: 'Del',
                      onPressed: () => onKey('Delete', null),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  alignment: WrapAlignment.center,
                  children: [
                    _CompactKeyButton(
                      icon: Icons.arrow_back,
                      tooltip: '向左',
                      onPressed: () => onKey('ArrowLeft', null),
                    ),
                    _CompactKeyButton(
                      icon: Icons.arrow_upward,
                      tooltip: '向上',
                      onPressed: () => onKey('ArrowUp', null),
                    ),
                    _CompactKeyButton(
                      icon: Icons.arrow_downward,
                      tooltip: '向下',
                      onPressed: () => onKey('ArrowDown', null),
                    ),
                    _CompactKeyButton(
                      icon: Icons.arrow_forward,
                      tooltip: '向右',
                      onPressed: () => onKey('ArrowRight', null),
                    ),
                    _CompactKeyButton(
                      label: '$primaryShortcutLabel+A',
                      tooltip: '全选',
                      onPressed: () => onPrimaryShortcut('KeyA'),
                    ),
                    _CompactKeyButton(
                      label: '$primaryShortcutLabel+C',
                      tooltip: '复制',
                      onPressed: () => onPrimaryShortcut('KeyC'),
                    ),
                    _CompactKeyButton(
                      label: Platform.isIOS ? '粘贴' : '$primaryShortcutLabel+V',
                      tooltip: Platform.isIOS ? '读取当前 iPad 剪贴板并粘贴到远程设备' : '粘贴',
                      onPressed: () => onPrimaryShortcut('KeyV'),
                    ),
                    _CompactKeyButton(
                      label: '$primaryShortcutLabel+X',
                      tooltip: '剪切',
                      onPressed: () => onPrimaryShortcut('KeyX'),
                    ),
                    _CompactKeyButton(
                      label: '$primaryShortcutLabel+Z',
                      tooltip: '撤销',
                      onPressed: () => onPrimaryShortcut('KeyZ'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _CompactKeyButton extends StatelessWidget {
  const _CompactKeyButton({
    required this.onPressed,
    this.label,
    this.icon,
    this.tooltip,
  }) : assert(label != null || icon != null);

  final VoidCallback onPressed;
  final String? label;
  final IconData? icon;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final button = icon == null
        ? FilledButton.tonal(
            onPressed: onPressed,
            style: FilledButton.styleFrom(
              minimumSize: const Size(48, 42),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              visualDensity: VisualDensity.compact,
            ),
            child: Text(label!),
          )
        : IconButton.filledTonal(
            onPressed: onPressed,
            visualDensity: VisualDensity.compact,
            icon: Icon(icon, size: 20),
          );
    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
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
