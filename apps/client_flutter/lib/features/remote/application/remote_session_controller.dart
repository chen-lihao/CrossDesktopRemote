import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cross_desktop_remote/core/input/mac_input_bridge.dart';
import 'package:cross_desktop_remote/core/input/remote_text_chunks.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_client.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_input_sequence_guard.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum RemoteSessionState {
  idle,
  initializing,
  waitingForPeer,
  awaitingApproval,
  connecting,
  streaming,
  disconnected,
  failed,
}

class RemoteSessionController extends ChangeNotifier {
  RemoteSessionController({
    required this.role,
    SignalingClient? signalingClient,
    MacInputBridge? inputBridge,
  }) : _signaling = signalingClient ?? SignalingClient(),
       _inputBridge = inputBridge ?? const MacInputBridge();

  final RemoteRole role;
  final SignalingClient _signaling;
  final MacInputBridge _inputBridge;
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final StreamController<RemoteNotice> _notices =
      StreamController<RemoteNotice>.broadcast(sync: true);
  final RemoteInputSequenceGuard _inputSequenceGuard =
      RemoteInputSequenceGuard();

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _controlChannel;
  RTCDataChannel? _motionChannel;
  MediaStream? _localStream;
  RTCRtpSender? _videoSender;
  List<DesktopCapturerSource> _displaySources = const [];
  List<RemoteDisplay> _displays = const [];
  StreamSubscription<DesktopCapturerSource>? _displayAddedSubscription;
  StreamSubscription<DesktopCapturerSource>? _displayRemovedSubscription;
  Timer? _displayRefreshTimer;
  Timer? _inputPermissionPollTimer;
  Timer? _qualityRequestTimer;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;
  bool _rendererReady = false;
  bool _closing = false;
  bool _authorizingPeer = false;
  bool _checkingInputPermission = false;
  bool _inputConfirmed = false;
  bool _qualityPending = false;
  bool _screenCaptureGranted = false;
  bool? _accessibilityGranted;
  int _inputSequence = 0;
  int _inputPermissionPollAttempts = 0;
  int _motionEventsSinceProbe = 0;
  int _droppedMotionEvents = 0;
  double? _inputRoundTripMs;
  String? _selectedDisplayId;
  String? _controlError;
  String? _error;
  DateTime? _lastControlUnavailableNotice;
  RemoteQualityProfile _selectedQuality = RemoteQualityProfile.automatic;
  int? _actualVideoWidth;
  int? _actualVideoHeight;
  String _statusMessage = '尚未连接';
  RemoteSessionState _state = RemoteSessionState.idle;

  RemoteSessionState get state => _state;
  Stream<RemoteNotice> get notices => _notices.stream;
  String get statusMessage => _statusMessage;
  String? get error => _error;
  String? get controlError => _controlError;
  bool get screenCaptureGranted => _screenCaptureGranted;
  bool? get accessibilityGranted => _accessibilityGranted;
  RemoteQualityProfile get selectedQuality => _selectedQuality;
  bool get qualityPending => _qualityPending;
  double? get inputRoundTripMs => _inputRoundTripMs;
  int get droppedMotionEvents => _droppedMotionEvents;
  String get qualityStatusLabel {
    final width = _actualVideoWidth;
    final height = _actualVideoHeight;
    if (width != null && height != null && width > 0 && height > 0) {
      return '${_selectedQuality.label} · $width×$height';
    }
    return _selectedQuality.label;
  }

  List<RemoteDisplay> get displays => _displays;
  String? get selectedDisplayId => _selectedDisplayId;
  RemoteDisplay? get selectedDisplay {
    for (final display in _displays) {
      if (display.id == _selectedDisplayId) {
        return display;
      }
    }
    return _displays.firstOrNull;
  }

  bool get hasRemoteVideo => remoteRenderer.srcObject != null;
  bool get canSendControl =>
      role == RemoteRole.controller &&
      _controlChannel?.state == RTCDataChannelState.RTCDataChannelOpen &&
      _accessibilityGranted == true;

  Future<void> initialize() async {
    if (_rendererReady) {
      return;
    }
    _setState(RemoteSessionState.initializing, '正在初始化视频渲染器');
    try {
      await remoteRenderer.initialize();
      _rendererReady = true;
      if (role == RemoteRole.host && Platform.isMacOS) {
        try {
          _accessibilityGranted = await _inputBridge.checkInputAccess();
          _controlError = _accessibilityGranted == true
              ? null
              : '本机尚未允许远程鼠标和键盘输入';
        } catch (_) {
          // Native channels are unavailable in widget tests and early startup.
        }
      }
      _setState(RemoteSessionState.idle, '尚未连接');
    } catch (error) {
      _fail('视频渲染器初始化失败：$error');
    }
  }

  Future<void> connect({
    required String serverUrl,
    required String roomCode,
  }) async {
    if (!_rendererReady) {
      await initialize();
    }
    if (!_rendererReady) {
      return;
    }

    await _closeSession(notifyPeer: false);
    _closing = false;
    _error = null;
    if (role == RemoteRole.controller) {
      _controlError = null;
    }
    _inputConfirmed = false;
    _emitNotice('正在连接远程设备');

    try {
      final endpoint = buildSignalingUri(
        serverUrl: serverUrl,
        roomCode: roomCode,
        role: role,
      );
      await _createPeerConnection();
      _setState(RemoteSessionState.connecting, '正在连接信令服务');
      await _signaling.connect(
        uri: endpoint,
        onMessage: (message) async {
          try {
            await _handleSignalingMessage(message);
          } catch (error) {
            _fail('信令处理失败：$error');
          }
        },
        onDone: _handleSignalingClosed,
      );
    } catch (error) {
      await _closeSession(notifyPeer: false);
      _fail('连接失败：$error');
    }
  }

  Future<void> approve() async {
    if (role != RemoteRole.host) {
      return;
    }
    await _authorizePeer();
  }

  Future<void> reject() async {
    if (_signaling.isConnected) {
      _signaling.send({'type': 'reject'});
    }
    await _closeSession(notifyPeer: false);
    _setState(RemoteSessionState.disconnected, '已拒绝连接');
  }

  Future<void> disconnect() async {
    await _closeSession(notifyPeer: true);
    _setState(RemoteSessionState.disconnected, '会话已断开');
    _emitNotice('远程会话已断开');
  }

  void sendPointer({
    required String phase,
    required double x,
    required double y,
    String mode = 'absolute',
    String button = 'left',
    int clickCount = 1,
    double movementX = 0,
    double movementY = 0,
    double deltaX = 0,
    double deltaY = 0,
  }) {
    final displayId = _selectedDisplayId;
    if (!canSendControl || displayId == null) {
      if (phase == 'down') {
        explainControlUnavailable();
      }
      return;
    }
    final isMotion = phase == 'move' || phase == 'scroll';
    final probe = isMotion && ++_motionEventsSinceProbe >= 30;
    if (probe) _motionEventsSinceProbe = 0;
    final message = <String, dynamic>{
      'type': 'pointer',
      'version': 2,
      'sequence': ++_inputSequence,
      'sentAtUnixMicros': DateTime.now().microsecondsSinceEpoch,
      if (probe) 'latencyProbe': true,
      'displayId': displayId,
      'mode': mode,
      'phase': phase,
      'button': button,
      'clickCount': clickCount,
      'x': x.clamp(0, 1),
      'y': y.clamp(0, 1),
      'movementX': movementX,
      'movementY': movementY,
      'deltaX': deltaX,
      'deltaY': deltaY,
    };
    if (isMotion) {
      _sendMotion(message);
    } else {
      _sendControl(message);
    }
  }

  void sendKey({
    required String phase,
    required String key,
    required List<String> modifiers,
  }) {
    if (!canSendControl) {
      explainControlUnavailable();
      return;
    }
    _sendControl({
      'type': 'keyboard',
      'version': 2,
      'sequence': ++_inputSequence,
      'sentAtUnixMicros': DateTime.now().microsecondsSinceEpoch,
      'inputType': 'key',
      'phase': phase,
      'key': key,
      'modifiers': modifiers,
    });
  }

  void sendText(String text) {
    if (!canSendControl || text.isEmpty) {
      if (text.isNotEmpty) {
        explainControlUnavailable();
      }
      return;
    }
    for (final chunk in chunkRemoteText(text)) {
      _sendControl({
        'type': 'keyboard',
        'version': 2,
        'sequence': ++_inputSequence,
        'sentAtUnixMicros': DateTime.now().microsecondsSinceEpoch,
        'inputType': 'text',
        'text': chunk,
      });
    }
  }

  void selectDisplay(String displayId) {
    if (role != RemoteRole.controller ||
        !displays.any((display) => display.id == displayId)) {
      return;
    }
    _sendControl({
      'type': 'select-display',
      'version': 2,
      'displayId': displayId,
    });
    _emitNotice('正在切换远程显示器');
  }

  Future<void> requestHostInputPermission() async {
    if (role != RemoteRole.host || !Platform.isMacOS) {
      return;
    }
    try {
      _accessibilityGranted = await _inputBridge.requestInputAccess();
      if (_accessibilityGranted == true) {
        _controlError = null;
        _emitNotice('远程输入权限已就绪', level: RemoteNoticeLevel.success);
      } else {
        _controlError = '本机尚未允许远程鼠标和键盘输入';
        await _inputBridge.openInputSettings();
        _emitNotice(
          '请在系统设置中允许 CrossDesktopRemote 控制本机，然后返回应用',
          level: RemoteNoticeLevel.warning,
        );
        _startInputPermissionPolling();
      }
      _publishHostState();
      notifyListeners();
    } catch (error) {
      _controlError = '无法打开远程输入权限设置：$error';
      _emitNotice(_controlError!, level: RemoteNoticeLevel.error);
      notifyListeners();
    }
  }

  Future<void> refreshHostPermissions({bool announce = false}) async {
    if (role != RemoteRole.host ||
        !Platform.isMacOS ||
        _checkingInputPermission) {
      return;
    }
    _checkingInputPermission = true;
    try {
      final previous = _accessibilityGranted;
      _accessibilityGranted = await _inputBridge.checkInputAccess();
      _controlError = _accessibilityGranted == true ? null : '本机尚未允许远程鼠标和键盘输入';
      _publishHostState();
      notifyListeners();
      if (_accessibilityGranted == true && previous != true) {
        _inputPermissionPollTimer?.cancel();
        _emitNotice('远程输入权限已生效', level: RemoteNoticeLevel.success);
      } else if (announce && _accessibilityGranted != true) {
        _emitNotice(_controlError!, level: RemoteNoticeLevel.warning);
      }
    } catch (error) {
      if (announce) {
        _emitNotice('检查远程输入权限失败：$error', level: RemoteNoticeLevel.error);
      }
    } finally {
      _checkingInputPermission = false;
    }
  }

  void explainControlUnavailable() {
    final now = DateTime.now();
    if (_lastControlUnavailableNotice != null &&
        now.difference(_lastControlUnavailableNotice!) <
            const Duration(seconds: 3)) {
      return;
    }
    _lastControlUnavailableNotice = now;
    final message =
        _controlChannel?.state != RTCDataChannelState.RTCDataChannelOpen
        ? '远程控制通道尚未就绪'
        : _accessibilityGranted != true
        ? '被控设备尚未允许鼠标和键盘输入'
        : '当前会话暂时无法发送控制指令';
    _emitNotice(message, level: RemoteNoticeLevel.warning);
  }

  void selectQuality(RemoteQualityProfile profile) {
    if (role != RemoteRole.controller) {
      return;
    }
    if (_controlChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      _emitNotice('视频控制通道尚未就绪', level: RemoteNoticeLevel.warning);
      return;
    }
    _qualityPending = true;
    _qualityRequestTimer?.cancel();
    _qualityRequestTimer = Timer(const Duration(seconds: 8), () {
      if (!_qualityPending) return;
      _qualityPending = false;
      notifyListeners();
      _emitNotice('画质切换超时，请检查远程连接', level: RemoteNoticeLevel.warning);
    });
    notifyListeners();
    _sendControl({
      'type': 'set-quality',
      'version': 2,
      'profile': profile.name,
    });
    _emitNotice('正在切换到${profile.label}');
  }

  void refreshRemoteStatus() {
    if (role == RemoteRole.controller) {
      _sendControl({'type': 'refresh-host-status', 'version': 2});
    }
  }

  void refreshRemoteDisplays() {
    if (role == RemoteRole.controller) {
      _sendControl({'type': 'refresh-displays', 'version': 2});
    }
  }

  Future<void> _createPeerConnection() async {
    final peerConnection = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _peerConnection = peerConnection;

    peerConnection.onIceCandidate = (candidate) {
      if (candidate.candidate == null || !_signaling.isConnected) {
        return;
      }
      _signaling.send({'type': 'candidate', ...candidate.toMap()});
    };
    peerConnection.onTrack = (event) {
      if (event.track.kind != 'video' || event.streams.isEmpty) {
        return;
      }
      remoteRenderer.srcObject = event.streams.first;
      _setState(RemoteSessionState.streaming, '正在显示远程屏幕');
    };
    peerConnection.onDataChannel = _attachDataChannel;
    peerConnection.onConnectionState = (connectionState) {
      switch (connectionState) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _setState(RemoteSessionState.streaming, '远程会话已连接');
          _emitNotice('远程会话连接成功', level: RemoteNoticeLevel.success);
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _fail('WebRTC 连接失败');
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _setState(RemoteSessionState.disconnected, 'WebRTC 连接已中断');
          _emitNotice('远程会话连接已中断', level: RemoteNoticeLevel.warning);
        default:
          break;
      }
    };

    if (role == RemoteRole.host) {
      final channel = await peerConnection.createDataChannel(
        'control',
        RTCDataChannelInit()
          ..ordered = true
          ..protocol = 'crossdesktop-control-v2',
      );
      _attachControlChannel(channel);
      final motionChannel = await peerConnection.createDataChannel(
        'input-motion',
        RTCDataChannelInit()
          ..ordered = false
          ..maxRetransmitTime = 50
          ..protocol = 'crossdesktop-input-motion-v2',
      );
      _attachMotionChannel(motionChannel);
    }
  }

  void _attachDataChannel(RTCDataChannel channel) {
    if (channel.label == 'input-motion') {
      _attachMotionChannel(channel);
    } else {
      _attachControlChannel(channel);
    }
  }

  void _attachControlChannel(RTCDataChannel channel) {
    _controlChannel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (role == RemoteRole.host) {
          _publishHostState();
          _publishDisplayList();
          _publishQualityState();
        } else {
          refreshRemoteStatus();
          refreshRemoteDisplays();
          _sendControl({'type': 'refresh-quality', 'version': 2});
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        unawaited(_releaseHostPointerButtons());
      }
      notifyListeners();
    };
    channel.onMessage = (message) {
      if (message.isBinary || message.text.length > 16 * 1024) {
        return;
      }
      unawaited(_handleControlMessage(message.text));
    };
  }

  void _attachMotionChannel(RTCDataChannel channel) {
    _motionChannel = channel;
    channel.onDataChannelState = (_) => notifyListeners();
    channel.onMessage = (message) {
      if (message.isBinary || message.text.length > 16 * 1024) return;
      unawaited(_handleControlMessage(message.text));
    };
  }

  Future<void> _handleControlMessage(String payload) async {
    try {
      final message = jsonDecode(payload);
      if (message is! Map<String, dynamic> || message['version'] != 2) {
        return;
      }
      if (role == RemoteRole.host) {
        await _handleHostControlMessage(message);
      } else {
        _handleControllerControlMessage(message);
      }
    } on FormatException {
      // Malformed JSON never reaches a native boundary.
    } catch (error) {
      if (role == RemoteRole.host) {
        await _reportInputFailure(error);
      } else {
        _controlError = '控制消息处理失败：$error';
        notifyListeners();
      }
    }
  }

  Future<void> _handleHostControlMessage(Map<String, dynamic> message) async {
    if (!Platform.isMacOS) {
      return;
    }
    switch (message['type']) {
      case 'pointer':
        final phase = message['phase'] as String? ?? 'move';
        final isMotion = phase == 'move' || phase == 'scroll';
        if (!_acceptInputSequence(message, motion: isMotion)) {
          return;
        }
        await _inputBridge.sendPointer(
          phase: phase,
          x: (message['x'] as num?)?.toDouble() ?? 0,
          y: (message['y'] as num?)?.toDouble() ?? 0,
          displayId:
              message['displayId'] as String? ?? _selectedDisplayId ?? '',
          mode: message['mode'] as String? ?? 'absolute',
          button: message['button'] as String? ?? 'left',
          clickCount: (message['clickCount'] as num?)?.toInt() ?? 1,
          movementX: (message['movementX'] as num?)?.toDouble() ?? 0,
          movementY: (message['movementY'] as num?)?.toDouble() ?? 0,
          deltaX: (message['deltaX'] as num?)?.toDouble() ?? 0,
          deltaY: (message['deltaY'] as num?)?.toDouble() ?? 0,
        );
        if ((message['phase'] != 'move' && message['phase'] != 'scroll') ||
            message['latencyProbe'] == true) {
          _acknowledgeInput(message);
        }
      case 'keyboard':
        if (!_acceptInputSequence(message, motion: false)) {
          return;
        }
        if (message['inputType'] == 'text') {
          final text = message['text'] as String? ?? '';
          if (text.isNotEmpty && text.length <= 256) {
            await _inputBridge.sendText(text);
          }
        } else {
          await _inputBridge.sendKey(
            phase: message['phase'] as String? ?? 'down',
            key: message['key'] as String? ?? '',
            modifiers: (message['modifiers'] as List<dynamic>? ?? const [])
                .whereType<String>()
                .toList(growable: false),
          );
        }
        _acknowledgeInput(message);
      case 'select-display':
        await _switchHostDisplay(message['displayId'] as String? ?? '');
      case 'refresh-host-status':
        _accessibilityGranted = await _inputBridge.checkInputAccess();
        _publishHostState();
        notifyListeners();
      case 'refresh-displays':
        await _refreshHostDisplays();
      case 'set-quality':
        await _applyVideoQuality(
          RemoteQualityProfile.fromWireValue(message['profile'] as String?),
        );
      case 'refresh-quality':
        _publishQualityState();
    }
  }

  bool _acceptInputSequence(
    Map<String, dynamic> message, {
    required bool motion,
  }) {
    final sequence = (message['sequence'] as num?)?.toInt() ?? 0;
    return _inputSequenceGuard.accept(sequence, motion: motion);
  }

  void _handleControllerControlMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'host-status':
        final previousInputAccess = _accessibilityGranted;
        _screenCaptureGranted =
            message['screenCaptureGranted'] as bool? ?? false;
        _accessibilityGranted =
            message['accessibilityGranted'] as bool? ?? false;
        if (_accessibilityGranted == true) {
          _controlError = null;
        }
        notifyListeners();
        if (_accessibilityGranted == true && previousInputAccess != true) {
          _emitNotice('被控设备的远程输入权限已就绪', level: RemoteNoticeLevel.success);
        }
      case 'display-list':
        _displays = (message['displays'] as List<dynamic>? ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(RemoteDisplay.fromMessage)
            .toList(growable: false);
        final selected = message['selectedDisplayId'] as String?;
        _selectedDisplayId = _displays.any((display) => display.id == selected)
            ? selected
            : _displays.firstOrNull?.id;
        notifyListeners();
      case 'display-selected':
        final displayId = message['displayId'] as String?;
        if (_displays.any((display) => display.id == displayId)) {
          _selectedDisplayId = displayId;
          notifyListeners();
          _emitNotice('已切换远程显示器', level: RemoteNoticeLevel.success);
        }
      case 'quality-state':
        _selectedQuality = RemoteQualityProfile.fromWireValue(
          message['profile'] as String?,
        );
        _actualVideoWidth = (message['width'] as num?)?.toInt();
        _actualVideoHeight = (message['height'] as num?)?.toInt();
        final wasPending = _qualityPending;
        _qualityRequestTimer?.cancel();
        _qualityPending = false;
        notifyListeners();
        if (wasPending) {
          _emitNotice(
            '画质已切换为 $qualityStatusLabel',
            level: RemoteNoticeLevel.success,
          );
        }
      case 'quality-error':
        _qualityRequestTimer?.cancel();
        _qualityPending = false;
        final messageText = message['message'] as String? ?? '画质切换失败';
        notifyListeners();
        _emitNotice(messageText, level: RemoteNoticeLevel.error);
      case 'input-ack':
        final sentAtMicros = (message['echoedSentAtUnixMicros'] as num?)
            ?.toInt();
        if (sentAtMicros != null) {
          final elapsedMicros =
              DateTime.now().microsecondsSinceEpoch - sentAtMicros;
          if (elapsedMicros >= 0) {
            _inputRoundTripMs = elapsedMicros / 1000;
            notifyListeners();
          }
        }
        if (!_inputConfirmed) {
          _inputConfirmed = true;
          _emitNotice('远程控制输入已生效', level: RemoteNoticeLevel.success);
        }
      case 'input-error':
        _controlError = message['message'] as String? ?? '被控设备无法处理远程输入';
        if (message['code'] == 'INPUT_PERMISSION_DENIED') {
          _accessibilityGranted = false;
        }
        notifyListeners();
        _emitNotice(_controlError!, level: RemoteNoticeLevel.error);
    }
  }

  void _sendControl(Map<String, dynamic> message) {
    _sendOnChannel(_controlChannel, message, reportFailure: true);
  }

  void _sendMotion(Map<String, dynamic> message) {
    final channel =
        _motionChannel?.state == RTCDataChannelState.RTCDataChannelOpen
        ? _motionChannel
        : _controlChannel;
    if ((channel?.bufferedAmount ?? 0) > 64 * 1024) {
      _droppedMotionEvents += 1;
      notifyListeners();
      return;
    }
    _sendOnChannel(channel, message, reportFailure: false);
  }

  void _sendOnChannel(
    RTCDataChannel? channel,
    Map<String, dynamic> message, {
    required bool reportFailure,
  }) {
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    unawaited(
      channel.send(RTCDataChannelMessage(jsonEncode(message))).catchError((_) {
        if (reportFailure) {
          _controlError = '控制通道发送失败';
          notifyListeners();
        }
      }),
    );
  }

  void _publishHostState() {
    _sendControl({
      'type': 'host-status',
      'version': 2,
      'screenCaptureGranted': _screenCaptureGranted,
      'accessibilityGranted': _accessibilityGranted == true,
      'inputReady': _accessibilityGranted == true,
    });
  }

  void _publishDisplayList() {
    _sendControl({
      'type': 'display-list',
      'version': 2,
      'selectedDisplayId': _selectedDisplayId,
      'displays': _displays.map((display) => display.toMessage()).toList(),
    });
  }

  void _acknowledgeInput(Map<String, dynamic> message) {
    _sendControl({
      'type': 'input-ack',
      'version': 2,
      'sequence': (message['sequence'] as num?)?.toInt() ?? 0,
      'inputType': message['type'],
      'echoedSentAtUnixMicros': message['sentAtUnixMicros'],
    });
  }

  Future<void> _applyVideoQuality(RemoteQualityProfile profile) async {
    try {
      final sender = _videoSender;
      if (sender == null) {
        throw StateError('视频发送器尚未就绪');
      }
      final parameters = sender.parameters;
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        throw StateError('当前视频编码器不支持动态画质切换');
      }
      final scale = profile.scaleFor(selectedDisplay);
      for (final encoding in encodings) {
        encoding
          ..maxBitrate = profile.maxBitrate
          ..maxFramerate = profile.maxFramerate
          ..scaleResolutionDownBy = scale;
      }
      final applied = await sender.setParameters(parameters);
      if (!applied) {
        throw StateError('视频编码器拒绝了新的画质参数');
      }
      _selectedQuality = profile;
      _updateExpectedVideoSize(scale);
      _publishQualityState();
      notifyListeners();
    } catch (error) {
      _sendControl({
        'type': 'quality-error',
        'version': 2,
        'message': '画质切换失败：$error',
      });
      _emitNotice('画质切换失败：$error', level: RemoteNoticeLevel.error);
    }
  }

  void _updateExpectedVideoSize(double scale) {
    final display = selectedDisplay;
    if (display == null || display.width <= 0 || display.height <= 0) {
      _actualVideoWidth = null;
      _actualVideoHeight = null;
      return;
    }
    _actualVideoWidth = math.max(1, (display.width / scale).round());
    _actualVideoHeight = math.max(1, (display.height / scale).round());
  }

  void _publishQualityState() {
    _sendControl({
      'type': 'quality-state',
      'version': 2,
      'profile': _selectedQuality.name,
      'width': _actualVideoWidth,
      'height': _actualVideoHeight,
      'maxBitrate': _selectedQuality.maxBitrate,
      'maxFramerate': _selectedQuality.maxFramerate,
    });
  }

  Future<void> _reportInputFailure(Object error) async {
    _accessibilityGranted = await _inputBridge.checkInputAccess();
    _controlError = _accessibilityGranted == true
        ? '本机输入注入失败'
        : '本机尚未允许远程鼠标和键盘输入';
    _sendControl({
      'type': 'input-error',
      'version': 2,
      'code': _accessibilityGranted == true
          ? 'INPUT_INJECTION_FAILED'
          : 'INPUT_PERMISSION_DENIED',
      'message': _controlError,
    });
    _publishHostState();
    notifyListeners();
  }

  Future<void> _handleSignalingMessage(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'ready':
        _setState(RemoteSessionState.waitingForPeer, '已进入房间，等待另一台设备');
      case 'peer-joined':
        if (role == RemoteRole.host) {
          await _authorizePeer();
        } else {
          _setState(RemoteSessionState.connecting, '连接码已验证，正在建立视频连接');
        }
      case 'approve':
        _setState(RemoteSessionState.connecting, '被控设备已允许，正在建立视频连接');
      case 'reject':
        await _closeSession(notifyPeer: false);
        _setState(RemoteSessionState.disconnected, '被控设备已拒绝本次连接');
        _emitNotice('连接被远程设备拒绝', level: RemoteNoticeLevel.warning);
      case 'offer':
        await _acceptOffer(message);
      case 'answer':
        await _acceptAnswer(message);
      case 'candidate':
        await _acceptCandidate(message);
      case 'hangup':
      case 'peer-left':
        await _closeSession(notifyPeer: false);
        _setState(RemoteSessionState.disconnected, '另一台设备已离开');
      case 'peer-unavailable':
        _setState(RemoteSessionState.waitingForPeer, '另一台设备尚未进入房间');
    }
  }

  Future<void> _acceptOffer(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || role != RemoteRole.controller) {
      return;
    }
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
    final answer = await _peerConnection!.createAnswer({});
    await _peerConnection!.setLocalDescription(answer);
    _signaling.send({'type': 'answer', 'sdp': answer.sdp});
  }

  Future<void> _acceptAnswer(Map<String, dynamic> message) async {
    final sdp = message['sdp'] as String?;
    if (sdp == null || role != RemoteRole.host) {
      return;
    }
    await _peerConnection!.setRemoteDescription(
      RTCSessionDescription(sdp, 'answer'),
    );
    _remoteDescriptionSet = true;
    await _flushPendingCandidates();
  }

  Future<void> _acceptCandidate(Map<String, dynamic> message) async {
    final candidateText = message['candidate'] as String?;
    if (candidateText == null) {
      return;
    }
    final candidate = RTCIceCandidate(
      candidateText,
      message['sdpMid'] as String?,
      message['sdpMLineIndex'] as int?,
    );
    if (!_remoteDescriptionSet) {
      _pendingCandidates.add(candidate);
      return;
    }
    await _peerConnection?.addCandidate(candidate);
  }

  Future<void> _flushPendingCandidates() async {
    for (final candidate in _pendingCandidates) {
      await _peerConnection?.addCandidate(candidate);
    }
    _pendingCandidates.clear();
  }

  Future<void> _authorizePeer() async {
    if (role != RemoteRole.host || _authorizingPeer || _localStream != null) {
      return;
    }
    _authorizingPeer = true;
    try {
      _setState(RemoteSessionState.connecting, '连接码验证成功，正在启动屏幕共享');
      await _startHostCapture();
      _signaling.send({'type': 'approve'});
      final offer = await _peerConnection!.createOffer({});
      await _peerConnection!.setLocalDescription(offer);
      _signaling.send({'type': 'offer', 'sdp': offer.sdp});
      _setState(RemoteSessionState.connecting, '已自动授权，等待控制端响应');
    } catch (error) {
      _fail('启动屏幕共享失败：$error');
    } finally {
      _authorizingPeer = false;
    }
  }

  Future<void> _startHostCapture() async {
    if (!Platform.isMacOS) {
      throw UnsupportedError('当前版本尚未实现此平台的被控能力');
    }
    _accessibilityGranted = await _inputBridge.requestInputAccess();
    _controlError = _accessibilityGranted == true ? null : '本机尚未允许远程鼠标和键盘输入';
    await _loadDisplaySources();
    if (_displaySources.isEmpty) {
      throw StateError('没有可共享的显示器，请检查屏幕录制权限');
    }

    final selectedSource =
        _sourceForId(_selectedDisplayId) ?? _displaySources.first;
    _selectedDisplayId = selectedSource.id;
    final stream = await _captureDisplay(selectedSource);
    _localStream = stream;
    _screenCaptureGranted = true;
    for (final track in stream.getVideoTracks()) {
      _videoSender = await _peerConnection!.addTrack(track, stream);
    }
    await _applyVideoQuality(_selectedQuality);
    _subscribeToDisplayChanges();
    _publishHostState();
    _publishDisplayList();
    notifyListeners();
  }

  Future<MediaStream> _captureDisplay(DesktopCapturerSource source) {
    return navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'deviceId': {'exact': source.id},
        'mandatory': {'frameRate': 30.0},
      },
    });
  }

  Future<void> _loadDisplaySources() async {
    final sources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
      thumbnailSize: ThumbnailSize(160, 100),
    );
    final nativeDisplays = await _inputBridge.listDisplays();
    final nativeById = {
      for (final display in nativeDisplays) display.id: display,
    };
    _displaySources = sources;
    _displays = sources
        .map((source) {
          final native = nativeById[source.id];
          return RemoteDisplay(
            id: source.id,
            name: native?.name ?? source.name,
            width: native?.width ?? 0,
            height: native?.height ?? 0,
            isPrimary: native?.isPrimary ?? false,
          );
        })
        .toList(growable: false);

    if (!_displays.any((display) => display.id == _selectedDisplayId)) {
      _selectedDisplayId =
          _displays.where((display) => display.isPrimary).firstOrNull?.id ??
          _displays.firstOrNull?.id;
    }
  }

  DesktopCapturerSource? _sourceForId(String? displayId) {
    for (final source in _displaySources) {
      if (source.id == displayId) {
        return source;
      }
    }
    return null;
  }

  Future<void> _switchHostDisplay(String displayId) async {
    if (role != RemoteRole.host || displayId == _selectedDisplayId) {
      return;
    }
    final source = _sourceForId(displayId);
    if (source == null) {
      _sendControl({
        'type': 'input-error',
        'version': 2,
        'code': 'DISPLAY_NOT_FOUND',
        'message': '选择的显示器已不可用',
      });
      return;
    }

    final replacementStream = await _captureDisplay(source);
    final replacementTracks = replacementStream.getVideoTracks();
    if (replacementTracks.isEmpty) {
      await replacementStream.dispose();
      throw StateError('新显示器未返回视频轨道');
    }
    final previousStream = _localStream;
    final replacementTrack = replacementTracks.first;
    if (_videoSender != null) {
      await _videoSender!.replaceTrack(replacementTrack);
    } else {
      _videoSender = await _peerConnection!.addTrack(
        replacementTrack,
        replacementStream,
      );
    }
    _localStream = replacementStream;
    _selectedDisplayId = displayId;
    for (final track in previousStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await previousStream?.dispose();
    _sendControl({
      'type': 'display-selected',
      'version': 2,
      'displayId': displayId,
    });
    await _applyVideoQuality(_selectedQuality);
    _publishDisplayList();
    notifyListeners();
  }

  Future<void> _refreshHostDisplays() async {
    final previousSelection = _selectedDisplayId;
    await _loadDisplaySources();
    if (_displaySources.isEmpty) {
      _fail('所有显示器均已断开');
      return;
    }
    if (previousSelection != null &&
        !displays.any((display) => display.id == previousSelection)) {
      final fallback = _selectedDisplayId;
      _selectedDisplayId = previousSelection;
      if (fallback != null) {
        await _switchHostDisplay(fallback);
      }
    }
    _publishDisplayList();
    notifyListeners();
  }

  void _subscribeToDisplayChanges() {
    _displayAddedSubscription ??= desktopCapturer.onAdded.stream.listen(
      (_) => _scheduleDisplayRefresh(),
    );
    _displayRemovedSubscription ??= desktopCapturer.onRemoved.stream.listen(
      (_) => _scheduleDisplayRefresh(),
    );
  }

  void _scheduleDisplayRefresh() {
    _displayRefreshTimer?.cancel();
    _displayRefreshTimer = Timer(
      const Duration(milliseconds: 300),
      () => unawaited(_refreshHostDisplays()),
    );
  }

  void _startInputPermissionPolling() {
    _inputPermissionPollTimer?.cancel();
    _inputPermissionPollAttempts = 0;
    _inputPermissionPollTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) {
      _inputPermissionPollAttempts += 1;
      unawaited(refreshHostPermissions());
      if (_accessibilityGranted == true || _inputPermissionPollAttempts >= 12) {
        timer.cancel();
      }
    });
  }

  void _handleSignalingClosed(int? code, String? reason) {
    if (!_closing) {
      final message = switch (reason) {
        'INVALID_ROOM' => '连接码不存在、尚未启用或已经过期',
        'CODE_CONSUMED' => '连接码已经使用，请让被控设备重新生成',
        'RATE_LIMITED' => '连接码尝试过多，请稍后再试',
        'ROLE_OCCUPIED' => '该设备角色已经连接',
        _ => '信令连接已断开',
      };
      _setState(RemoteSessionState.disconnected, message);
      _emitNotice(message, level: RemoteNoticeLevel.warning);
    }
  }

  Future<void> _closeSession({required bool notifyPeer}) async {
    _closing = true;
    if (notifyPeer && _signaling.isConnected) {
      try {
        _signaling.send({'type': 'hangup'});
      } catch (_) {
        // The socket may close between the state check and the send.
      }
    }
    await _signaling.close();
    await _releaseHostPointerButtons();
    await _controlChannel?.close();
    _controlChannel = null;
    await _motionChannel?.close();
    _motionChannel = null;
    _displayRefreshTimer?.cancel();
    _displayRefreshTimer = null;
    _inputPermissionPollTimer?.cancel();
    _inputPermissionPollTimer = null;
    _qualityRequestTimer?.cancel();
    _qualityRequestTimer = null;
    await _displayAddedSubscription?.cancel();
    _displayAddedSubscription = null;
    await _displayRemovedSubscription?.cancel();
    _displayRemovedSubscription = null;
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    _videoSender = null;
    await _peerConnection?.close();
    await _peerConnection?.dispose();
    _peerConnection = null;
    if (_rendererReady) {
      remoteRenderer.srcObject = null;
    }
    _remoteDescriptionSet = false;
    _pendingCandidates.clear();
    _displaySources = const [];
    _displays = const [];
    _selectedDisplayId = null;
    _screenCaptureGranted = false;
    if (role == RemoteRole.controller) {
      _accessibilityGranted = null;
    }
    _authorizingPeer = false;
    _checkingInputPermission = false;
    _inputConfirmed = false;
    _qualityPending = false;
    _inputSequence = 0;
    _inputSequenceGuard.reset();
    _inputPermissionPollAttempts = 0;
    _motionEventsSinceProbe = 0;
    _droppedMotionEvents = 0;
    _inputRoundTripMs = null;
    _actualVideoWidth = null;
    _actualVideoHeight = null;
    _closing = false;
  }

  Future<void> _releaseHostPointerButtons() async {
    if (role != RemoteRole.host || !Platform.isMacOS) return;
    try {
      await _inputBridge.releasePointerButtons();
    } catch (_) {
      // The native window may already be closing or unavailable in tests.
    }
  }

  void _setState(RemoteSessionState next, String message) {
    _state = next;
    _statusMessage = message;
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _setState(RemoteSessionState.failed, message);
    _emitNotice(message, level: RemoteNoticeLevel.error);
  }

  void _emitNotice(
    String message, {
    RemoteNoticeLevel level = RemoteNoticeLevel.info,
  }) {
    if (!_notices.isClosed) {
      _notices.add(RemoteNotice(message, level: level));
    }
  }

  @override
  void dispose() {
    unawaited(_disposeResources());
    unawaited(_notices.close());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _closeSession(notifyPeer: true);
    if (_rendererReady) {
      await remoteRenderer.dispose();
      _rendererReady = false;
    }
  }
}
