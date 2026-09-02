import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/core/clipboard/clipboard_sync_mode.dart';
import 'package:cross_desktop_remote/core/files/explicit_file_transfer_platform_adapter.dart';
import 'package:cross_desktop_remote/core/files/file_paste_target_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/host_platform_adapter_factory.dart';
import 'package:cross_desktop_remote/core/input/remote_input_reset.dart';
import 'package:cross_desktop_remote/core/input/remote_shortcut_policy.dart';
import 'package:cross_desktop_remote/core/protocol/wire_value_parsers.dart';
import 'package:cross_desktop_remote/core/input/remote_text_chunks.dart';
import 'package:cross_desktop_remote/core/platform/desktop_window_mode.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_client.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/core/signaling/remote_capabilities.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_display_switch_coordinator.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_display_switch_protocol.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_frame_geometry_coordinator.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_input_sequence_guard.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_input_state_coordinator.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_media_stats.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_quality_adaptation.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_kernel.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_engine.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';
import 'package:cross_desktop_remote/features/remote/application/file_clipboard_sync_engine.dart';
import 'package:cross_desktop_remote/features/remote/application/text_clipboard_sync_engine.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum RemoteSessionState {
  idle,
  initializing,
  waitingForPeer,
  awaitingApproval,
  connecting,
  streaming,
  reconnecting,
  disconnected,
  failed,
}

enum HostInvitationState { unavailable, active, consumed, expired, rotating }

ClipboardSyncMode _platformClipboardMode(
  ClipboardSyncMode requested,
  RemoteRole role,
) {
  if (!Platform.isIOS || requested == ClipboardSyncMode.disabled) {
    return requested;
  }
  return role == RemoteRole.controller
      ? ClipboardSyncMode.controllerToHost
      : ClipboardSyncMode.hostToController;
}

bool _isModifierWireKey(String key) => const {
  'ControlLeft',
  'ControlRight',
  'MetaLeft',
  'MetaRight',
  'AltLeft',
  'AltRight',
  'ShiftLeft',
  'ShiftRight',
}.contains(key);

class _RtcVideoProgress {
  const _RtcVideoProgress({
    required this.size,
    required this.frames,
    required this.keyFrames,
  });

  final RemoteVideoFrameSize size;
  final int? frames;
  final int? keyFrames;
}

class _HostDisplaySwitchTransaction {
  _HostDisplaySwitchTransaction({
    required this.generation,
    required this.previousDisplayId,
    required this.targetDisplayId,
    required this.previousStream,
    required this.targetStream,
    required this.switchedInPlace,
    required this.trackId,
    required this.captureGeneration,
  });

  final int generation;
  final String? previousDisplayId;
  final String targetDisplayId;
  final MediaStream previousStream;
  final MediaStream targetStream;
  final bool switchedInPlace;
  final String? trackId;
  final int captureGeneration;
  Timer? timeout;
}

class _DisplaySwitchFailure implements Exception {
  const _DisplaySwitchFailure({
    required this.code,
    required this.stage,
    required this.message,
  });

  final String code;
  final String stage;
  final String message;

  @override
  String toString() => message;
}

class _CaptureFrameWaitResult {
  const _CaptureFrameWaitResult({required this.ready, this.lastState});

  final bool ready;
  final HostCaptureFrameState? lastState;

  String get diagnosticSuffix {
    final state = lastState;
    if (state == null || state.rejectionReason.isEmpty) return '';
    return '（采集门禁：${state.gateDiagnosticSummary}）';
  }
}

class RemoteSessionController extends ChangeNotifier {
  static const int _appleSessionCaptureLongEdge = 1920;
  static const int _windowsSessionCaptureLongEdge = 2560;
  static const int _sessionCaptureFrameRate = 60;

  RemoteSessionController({
    required this.role,
    String localDeviceId = '',
    SignalingClient? signalingClient,
    HostPlatformAdapter? hostPlatformAdapter,
    ClipboardPlatformAdapter? clipboardPlatformAdapter,
    ExplicitFileTransferPlatformAdapter? fileTransferPlatformAdapter,
    FilePasteTargetPlatformAdapter? filePasteTargetPlatformAdapter,
    Stream<DesktopWindowLifecycleEvent>? hostWindowLifecycleEvents,
    RemoteQualityProfile initialQuality = RemoteQualityProfile.automatic,
    RemoteVideoPolicy? initialVideoPolicy,
    ClipboardSyncMode initialClipboardMode = ClipboardSyncMode.bidirectional,
  }) : _localDeviceId = localDeviceId.trim().toLowerCase(),
       _signaling = signalingClient ?? SignalingClient(),
       _hostPlatform = hostPlatformAdapter ?? createHostPlatformAdapter(),
       _clipboardPlatform =
           clipboardPlatformAdapter ?? createClipboardPlatformAdapter(),
       _hostWindowLifecycleEvents =
           hostWindowLifecycleEvents ??
           PlatformDesktopWindowModeController.lifecycleEvents,
       _fileTransferPlatform =
           fileTransferPlatformAdapter ??
           createExplicitFileTransferPlatformAdapter(),
       _filePasteTargetPlatform =
           filePasteTargetPlatformAdapter ??
           createFilePasteTargetPlatformAdapter(),
       _selectedQuality = initialQuality,
       _selectedVideoPolicy =
           initialVideoPolicy ?? RemoteVideoPolicy.fromLegacy(initialQuality),
       _clipboardMode = _platformClipboardMode(initialClipboardMode, role),
       _clipboardSync = TextClipboardSyncEngine(
         localIsController: role == RemoteRole.controller,
         initialMode: _platformClipboardMode(initialClipboardMode, role),
       ) {
    _fileCopyPaste = FileCopyPasteCoordinator(
      publisher: (paths, destinationLeaseId) => _fileTransfer.sendFiles(
        paths,
        purpose: ExplicitFileTransferPurpose.clipboard,
        destinationLeaseId: destinationLeaseId,
      ),
      canceller: _cancelSupersededFileClipboardTransfer,
    );
    _fileTransfer.addListener(_handleFileTransferChanged);
    _fileTransferNoticeSubscription = _fileTransfer.notices.listen(_emitNotice);
    unawaited(
      _fileTransferPlatform.cleanupOrphanedClipboardReceiveDirectories(),
    );
  }

  final RemoteRole role;
  late final RemoteSessionKernel _kernel = RemoteSessionKernel(role: role.name);
  String _localDeviceId;
  final SignalingClient _signaling;
  final HostPlatformAdapter _hostPlatform;
  final ClipboardPlatformAdapter _clipboardPlatform;
  final ExplicitFileTransferPlatformAdapter _fileTransferPlatform;
  final FilePasteTargetPlatformAdapter _filePasteTargetPlatform;
  final TextClipboardSyncEngine _clipboardSync;
  final ClipboardApplyGate _clipboardApplyGate = ClipboardApplyGate();
  final ExplicitFileTransferEngine _fileTransfer = ExplicitFileTransferEngine();
  late final FileCopyPasteCoordinator _fileCopyPaste;
  final Map<String, FilePasteDestinationLease> _filePasteLeaseByTransferId = {};
  final Map<String, List<String>> _stagedOutgoingFiles = {};
  final Set<String> _acceptingFileClipboardTransfers = {};
  final Set<String> _appliedFileClipboardTransfers = {};
  final Set<String> _retiredFileClipboardTransfers = {};
  final Stream<DesktopWindowLifecycleEvent> _hostWindowLifecycleEvents;

  FileClipboardOfferBroker get _fileClipboardOffers => _fileCopyPaste.offers;
  FilePasteIntentGate get _filePasteIntentGate => _fileCopyPaste.intents;
  FilePasteDestinationLeaseRegistry get _filePasteDestinationLeases =>
      _fileCopyPaste.destinations;
  FilePasteCommitGate get _filePasteCommitGate => _fileCopyPaste.commits;
  Map<String, RemotePasteTransferBinding> get _remotePasteTransferByIntent =>
      _fileCopyPaste.remoteTransfersByIntent;
  Set<String> get _trackedRemotePasteIntents =>
      _fileCopyPaste.trackedRemotePasteIntents;

  /// Apple keeps the physically verified fixed 1080p ScreenCaptureKit canvas.
  /// Windows can capture a 2K source without entering the Apple display-switch
  /// transaction, so its first performance prototype receives a higher cap.
  int get _sessionCaptureLongEdge => math.max(
    _hostPlatform.type == HostPlatformType.windows
        ? _windowsSessionCaptureLongEdge
        : _appleSessionCaptureLongEdge,
    (_selectedVideoPolicy.targetLongEdge ?? 0).clamp(0, 3840),
  );
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();
  final StreamController<RemoteNotice> _notices =
      StreamController<RemoteNotice>.broadcast(sync: true);
  final RemoteInputSequenceGuard _inputSequenceGuard =
      RemoteInputSequenceGuard();
  final RemoteInputStateCoordinator _hostInputState =
      RemoteInputStateCoordinator();
  final RemoteMediaStatsAccumulator _mediaStatsAccumulator =
      RemoteMediaStatsAccumulator();
  final RemoteQualityAdaptationController _qualityAdaptation =
      RemoteQualityAdaptationController();
  final RemoteDisplaySwitchCoordinator _displaySwitch =
      RemoteDisplaySwitchCoordinator();
  final RemoteFrameGeometryCoordinator _frameGeometry =
      RemoteFrameGeometryCoordinator();

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _controlChannel;
  RTCDataChannel? _motionChannel;
  RTCDataChannel? _clipboardChannel;
  RTCDataChannel? _fileTransferControlChannel;
  RTCDataChannel? _fileTransferDataChannel;
  MediaStream? _localStream;
  RTCRtpSender? _videoSender;
  RTCRtpReceiver? _videoReceiver;
  List<DesktopCapturerSource> _displaySources = const [];
  List<RemoteDisplay> _displays = const [];
  StreamSubscription<DesktopCapturerSource>? _displayAddedSubscription;
  StreamSubscription<DesktopCapturerSource>? _displayRemovedSubscription;
  StreamSubscription<DesktopWindowLifecycleEvent>?
  _hostWindowLifecycleSubscription;
  StreamSubscription<ClipboardSnapshot>? _clipboardSubscription;
  StreamSubscription<String>? _filePasteIntentSubscription;
  StreamSubscription<String>? _fileTransferNoticeSubscription;
  Timer? _displayRefreshTimer;
  Timer? _inputPermissionPollTimer;
  Timer? _qualityRequestTimer;
  Timer? _displaySwitchRequestTimer;
  Timer? _connectionRecoveryTimer;
  Timer? _mediaStatsTimer;
  Timer? _windowsCaptureRecoveryTimer;
  final List<RTCIceCandidate> _pendingCandidates = [];
  bool _remoteDescriptionSet = false;
  bool _rendererReady = false;
  bool _closing = false;
  bool _connectionEstablished = false;
  bool _authorizingPeer = false;
  bool _checkingInputPermission = false;
  bool _inputConfirmed = false;
  bool _qualityPending = false;
  bool _sessionRepairPending = false;
  bool _hostDisplaySwitchInProgress = false;
  bool _samplingMediaStats = false;
  bool _adaptiveQualityUpdateInProgress = false;
  bool _windowsCaptureRecoveryInProgress = false;
  int _windowsCaptureRecoveryGeneration = 0;
  Completer<void>? _adaptiveQualityUpdateCompleter;
  bool _screenCaptureGranted = false;
  bool? _accessibilityGranted;
  int _inputSequence = 0;
  int _remoteInputEpoch = 0;
  int _inputPermissionPollAttempts = 0;
  int _motionEventsSinceProbe = 0;
  int _droppedMotionEvents = 0;
  int _geometryObservationToken = 0;
  double? _inputRoundTripMs;
  String? _selectedDisplayId;
  String? _renderedDisplayId;
  String? _remoteDeviceId;
  String? _remoteHostPlatform;
  String? _localNetworkAddress;
  String? _remoteNetworkAddress;
  String? _signalingServerUrl;
  bool _remoteSupportsPhysicalKeyboard = false;
  String? _controlError;
  String? _error;
  DateTime? _lastControlUnavailableNotice;
  DateTime? _automaticQualitySuppressedUntil;
  DateTime? _hostInvitationExpiresAt;
  String? _hostInvitationCode;
  String? _hostInvitationLeaseId;
  int _hostInvitationGeneration = 0;
  HostInvitationState _hostInvitationState = HostInvitationState.unavailable;
  bool _supportsInvitationRotation = false;
  bool _supportsServerInvitationPush = false;
  bool _remoteSupportsVideoPolicyV2 = false;
  bool _remoteSupportsMultiDisplayStreamV1 = false;
  bool _remoteSupportsActiveContentGeometry = false;
  int _remoteActiveContentGeometryVersion = 0;
  bool _remoteSupportsTextClipboardV1 = false;
  bool _remoteSupportsExplicitFileTransferV1 = false;
  bool _remoteSupportsDestinationLeasedFilePasteV1 = false;
  bool _remoteSupportsAtomicShortcutV1 = false;
  bool _remoteSupportsScopedInputResetV1 = false;
  bool _remoteClipboardSupportsApplied = false;
  bool _explicitFileTransferTransportAttached = false;
  Completer<void>? _invitationRotationCompleter;
  Completer<Map<String, dynamic>>? _sessionRepairCompleter;
  String? _sessionRepairRequestId;
  RemoteQualityProfile _selectedQuality;
  RemoteVideoPolicy _selectedVideoPolicy;
  ClipboardSyncMode _clipboardMode;
  ClipboardSyncMode? _remoteClipboardMode;
  ClipboardOffer? _queuedClipboardOffer;
  late final String _filePasteOwnerId =
      '${role.name}:${identityHashCode(this)}';
  String? _fileClipboardPasteTransferId;
  bool _fileClipboardPastePreparing = false;
  bool _synchronizingFileClipboardTransfers = false;
  bool _fileClipboardSynchronizationRequested = false;
  ClipboardSyncStatus _clipboardStatus = ClipboardSyncStatus.unavailable;
  String _clipboardStatusMessage = '当前平台不支持';
  RemoteQualityProfile? _queuedQualityProfile;
  RemoteVideoPolicy? _queuedVideoPolicy;
  int? _actualVideoWidth;
  int? _actualVideoHeight;
  RemoteVideoFrameSize? _expectedVideoFrameSize;
  RemoteVideoFrameSize? _outboundVideoFrameSize;
  RemoteVideoFrameSize? _inboundVideoFrameSize;
  HostCaptureFrameState? _lastHostCaptureFrameState;

  RemoteFileClipboardOffer? get _remoteFileClipboardOffer =>
      _fileCopyPaste.remoteOffer;
  set _remoteFileClipboardOffer(RemoteFileClipboardOffer? value) =>
      _fileCopyPaste.remoteOffer = value;
  FileClipboardOfferIdentity? get _announcedLocalFileOffer =>
      _fileCopyPaste.announcedLocalOffer;
  set _announcedLocalFileOffer(FileClipboardOfferIdentity? value) =>
      _fileCopyPaste.announcedLocalOffer = value;
  String get _filePasteSessionId => _fileCopyPaste.localSessionId;
  String? get _remoteFilePasteSessionId => _fileCopyPaste.remoteSessionId;
  set _remoteFilePasteSessionId(String? value) =>
      _fileCopyPaste.remoteSessionId = value;
  RemoteVideoGeometryState _videoGeometryState =
      RemoteVideoGeometryState.stable;
  RemoteColorDiagnostics? _colorDiagnostics;
  RemoteFrameColorDiagnostics? _decoderOutputColorDiagnostics;
  RemoteFrameColorDiagnostics? _renderOutputColorDiagnostics;
  String? _receiverColorConversion;
  RemoteMediaDiagnostics? _mediaDiagnostics;
  int? _captureTargetLongEdge;
  String? _captureTargetSourceId;
  String _statusMessage = '尚未连接';
  RemoteSessionState _state = RemoteSessionState.idle;
  _HostDisplaySwitchTransaction? _hostDisplaySwitchTransaction;

  bool get _displaySwitchPending => _displaySwitch.pending;
  int get _displaySwitchGeneration => _displaySwitch.generation;
  int? get _displaySwitchInboundFramesBaseline =>
      _displaySwitch.inboundFramesBaseline;
  String? get _pendingDisplayId => _displaySwitch.targetDisplayId;

  RemoteSessionState get state => _state;
  String? get sessionId => _kernel.sessionId;
  String get localDeviceId => _localDeviceId;
  Stream<RemoteSessionDomainEvent> get domainEvents => _kernel.events;
  Stream<RemoteNotice> get notices => _notices.stream;
  String get statusMessage => _statusMessage;
  String? get error => _error;
  String? get controlError => _controlError;
  DateTime? get hostInvitationExpiresAt => _hostInvitationExpiresAt;
  String? get hostInvitationCode => _hostInvitationCode;
  int get hostInvitationGeneration => _hostInvitationGeneration;
  HostInvitationState get hostInvitationState => _hostInvitationState;
  bool get supportsInvitationRotation => _supportsInvitationRotation;
  bool get supportsServerInvitationPush => _supportsServerInvitationPush;
  bool get remoteSupportsMultiDisplayStreamV1 =>
      _remoteSupportsMultiDisplayStreamV1;
  bool get screenCaptureGranted => _screenCaptureGranted;
  bool? get accessibilityGranted => _accessibilityGranted;
  RemoteQualityProfile get selectedQuality => _selectedQuality;
  RemoteVideoPolicy get selectedVideoPolicy => _selectedVideoPolicy;
  ClipboardSyncMode get clipboardMode => _clipboardMode;
  ClipboardSyncMode? get remoteClipboardMode => _remoteClipboardMode;
  ClipboardSyncStatus get clipboardStatus => _clipboardStatus;
  String get clipboardStatusMessage => _clipboardStatusMessage;
  bool get clipboardSupported => _clipboardPlatform.supported;
  bool get fileClipboardSupported =>
      _clipboardPlatform.fileClipboardSupported &&
      localExplicitFileTransferSupported;
  bool get localExplicitFileTransferSupported =>
      _fileTransferPlatform.supported;
  bool get explicitFileTransferDirectorySelectionSupported =>
      _fileTransferPlatform.supportsDirectorySelection;
  bool get explicitFileTransferUsesManagedReceiveStorage =>
      _fileTransferPlatform.usesManagedReceiveStorage;
  bool get explicitFileTransferReceivedExportSupported =>
      _fileTransferPlatform.supportsReceivedExport;
  bool get remoteSupportsExplicitFileTransferV1 =>
      _remoteSupportsExplicitFileTransferV1;
  bool get remoteSupportsDestinationLeasedFilePasteV1 =>
      _remoteSupportsDestinationLeasedFilePasteV1;
  bool get fileClipboardReady =>
      fileClipboardSupported &&
      _remoteSupportsDestinationLeasedFilePasteV1 &&
      _filePasteTargetPlatform.supported &&
      explicitFileTransferReady &&
      _clipboardChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
  bool get explicitFileTransferReady =>
      localExplicitFileTransferSupported &&
      _remoteSupportsExplicitFileTransferV1 &&
      _fileTransfer.transportReady;
  List<ExplicitFileTransferTaskSnapshot> get fileTransferTasks =>
      _fileTransfer.tasks;
  ExplicitFileTransferTaskSnapshot? get fileClipboardPasteTask {
    final transferId = _fileClipboardPasteTransferId;
    if (transferId == null) return null;
    return _fileTransfer.tasks
        .where((task) => task.id == transferId)
        .firstOrNull;
  }

  bool get fileClipboardPastePending =>
      _fileClipboardPastePreparing || _fileClipboardPasteTransferId != null;
  bool get fileClipboardOfferPending => _fileClipboardOffers.hasOffer;
  String get fileClipboardPasteStatus {
    if (_fileClipboardPastePreparing) return '正在锁定远程目标目录';
    final task = fileClipboardPasteTask;
    if (task == null) return '';
    final progress = task.progress;
    final progressLabel = progress == null
        ? ''
        : ' ${(progress * 100).toStringAsFixed(0)}%';
    return '正在传输到锁定目录$progressLabel · ${task.state.label}';
  }

  Future<void> cancelFileClipboardOffer() async {
    if (!_fileClipboardOffers.hasOffer || fileClipboardPastePending) return;
    _revokeAnnouncedLocalFileClipboardOffer();
    await _fileClipboardOffers.invalidate();
    _setClipboardStatus(ClipboardSyncStatus.ready, '已取消待粘贴文件');
    notifyListeners();
  }

  int get pendingIncomingFileTransferCount =>
      _fileTransfer.pendingIncomingCount;
  String get remotePrimaryShortcutModifier =>
      RemoteShortcutPolicy.remotePrimaryModifier(
        remoteHostPlatform: _remoteHostPlatform,
        controllerPlatform: currentRemoteControllerPlatform(),
      );
  String get remotePrimaryShortcutLabel =>
      RemoteShortcutPolicy.primaryLabel(remotePrimaryShortcutModifier);
  bool get qualityPending => _qualityPending;
  bool get displaySwitchPending => _displaySwitchPending;
  bool get sessionRepairPending => _sessionRepairPending;
  String? get pendingDisplayId => _pendingDisplayId;
  RemoteVideoFrameSize? get expectedVideoFrameSize => _expectedVideoFrameSize;
  RemoteVideoFrameSize? get outboundVideoFrameSize => _outboundVideoFrameSize;
  RemoteVideoFrameSize? get inboundVideoFrameSize => _inboundVideoFrameSize;
  RemoteFrameGeometry? get committedFrameGeometry => _frameGeometry.current;
  RemoteVideoGeometryState get videoGeometryState => _videoGeometryState;
  double? get inputRoundTripMs => _inputRoundTripMs;
  int get droppedMotionEvents => _droppedMotionEvents;
  RemoteVideoTarget get activeVideoTarget => RemoteVideoTarget.forPolicy(
    _selectedVideoPolicy,
    automaticTier: _qualityAdaptation.tier,
  );
  String get qualityStatusLabel {
    final qualityLabel = activeVideoTarget.label;
    final expected = _expectedVideoFrameSize;
    final actual = role == RemoteRole.host
        ? _outboundVideoFrameSize
        : _inboundVideoFrameSize ?? _outboundVideoFrameSize;
    if (_videoGeometryState == RemoteVideoGeometryState.adapting) {
      final actualLabel = actual?.isValid == true ? actual!.label : '检测中';
      final targetLabel = expected?.isValid == true ? expected!.label : '自动';
      return '$qualityLabel · $actualLabel → $targetLabel · 适配中';
    }
    if (_videoGeometryState == RemoteVideoGeometryState.constrained &&
        actual?.isValid == true) {
      return '$qualityLabel · ${actual!.label} · 自适应';
    }
    if (actual?.isValid == true) {
      return '$qualityLabel · ${actual!.label}';
    }
    final width = _actualVideoWidth;
    final height = _actualVideoHeight;
    if (width != null && height != null && width > 0 && height > 0) {
      return '$qualityLabel · $width×$height';
    }
    return qualityLabel;
  }

  List<RemoteDisplay> get displays => _displays;
  String? get selectedDisplayId => _selectedDisplayId;
  String? get renderedDisplayId => _renderedDisplayId;
  String? get remoteDeviceId => _remoteDeviceId;
  String? get localNetworkAddress => _localNetworkAddress;
  String? get remoteNetworkAddress => _remoteNetworkAddress;
  String? get signalingServerUrl => _signalingServerUrl;
  String? get remoteHostPlatform => _remoteHostPlatform;
  bool get remoteSupportsPhysicalKeyboard => _remoteSupportsPhysicalKeyboard;
  RemoteColorDiagnostics? get colorDiagnostics => _colorDiagnostics;
  RemoteFrameColorDiagnostics? get decoderOutputColorDiagnostics =>
      _decoderOutputColorDiagnostics;
  RemoteFrameColorDiagnostics? get renderOutputColorDiagnostics =>
      _renderOutputColorDiagnostics;
  String? get receiverColorConversion => _receiverColorConversion;
  RemoteMediaDiagnostics? get mediaDiagnostics => _mediaDiagnostics;
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
      !_displaySwitchPending &&
      _controlChannel?.state == RTCDataChannelState.RTCDataChannelOpen &&
      _accessibilityGranted == true;

  Future<void> initialize() async {
    if (_rendererReady) {
      return;
    }
    _setState(RemoteSessionState.initializing, '正在初始化视频渲染器');
    try {
      remoteRenderer.onColorDiagnostics = _handleRendererColorDiagnostics;
      await remoteRenderer.initialize();
      _rendererReady = true;
      if (role == RemoteRole.host &&
          _hostPlatform.capabilities.canHostDesktop) {
        if (_hostPlatform.type == HostPlatformType.windows) {
          _hostWindowLifecycleSubscription ??= _hostWindowLifecycleEvents
              .listen(_handleHostWindowLifecycleEvent);
        }
        try {
          final permission = await _hostPlatform.checkPermissions();
          _applyHostPermissionState(permission);
        } catch (_) {
          // Native channels are unavailable in widget tests and early startup.
        }
      }
      await _initializeClipboardMonitoring();
      _setState(RemoteSessionState.idle, '尚未连接');
    } catch (error) {
      _fail('视频渲染器初始化失败：$error');
    }
  }

  void setLocalDeviceId(String value) {
    final normalized = value.trim().toLowerCase();
    if (normalized.isEmpty || normalized == _localDeviceId) return;
    if (!{
      RemoteSessionState.idle,
      RemoteSessionState.disconnected,
      RemoteSessionState.failed,
    }.contains(state)) {
      throw StateError('远程会话活动期间不能更换设备身份');
    }
    _localDeviceId = normalized;
  }

  void _handleRendererColorDiagnostics(Map<String, dynamic> diagnostics) {
    _decoderOutputColorDiagnostics = _frameColorDiagnostics(
      diagnostics['decoderOutput'],
    );
    _renderOutputColorDiagnostics = _frameColorDiagnostics(
      diagnostics['renderOutput'],
    );
    _receiverColorConversion = diagnostics['conversion'] as String?;
    notifyListeners();
  }

  Future<void> _initializeClipboardMonitoring() async {
    if (_filePasteTargetPlatform.supported &&
        _filePasteIntentSubscription == null) {
      _filePasteIntentSubscription = _filePasteTargetPlatform.pasteIntents
          .listen((ownerId) {
            if (ownerId == _filePasteOwnerId) {
              unawaited(_handleLocalRemoteFilePasteIntent());
            }
          });
    }
    if (!_clipboardPlatform.supported || _clipboardSubscription != null) {
      _updateClipboardStatus();
      return;
    }
    if (!_clipboardPlatform.automaticMonitoringSupported) {
      _updateClipboardStatus();
      return;
    }
    try {
      _clipboardSync.observeBaseline(await _clipboardPlatform.readSnapshot());
      _clipboardSubscription = _clipboardPlatform.changes.listen(
        _handleLocalClipboardChange,
        onError: (Object error) {
          _setClipboardStatus(ClipboardSyncStatus.error, '无法监听系统剪贴板：$error');
        },
      );
      _updateClipboardStatus();
    } catch (error) {
      _setClipboardStatus(ClipboardSyncStatus.error, '剪贴板初始化失败：$error');
    }
  }

  void setClipboardMode(ClipboardSyncMode value) {
    final effectiveMode = _platformClipboardMode(value, role);
    if (_clipboardMode == effectiveMode) return;
    _clipboardMode = effectiveMode;
    _clipboardSync.setMode(effectiveMode);
    _sendClipboard({
      'type': 'hello',
      'version': clipboardWireVersion,
      'mode': effectiveMode.name,
      'supportsApplied': true,
      'supportsFileClipboard': false,
      'supportsDestinationLeasedFilePaste': fileClipboardSupported,
      'filePasteSessionId': _filePasteSessionId,
    });
    _updateClipboardStatus();
    notifyListeners();
  }

  void _handleLocalClipboardChange(ClipboardSnapshot snapshot) {
    _clearRemoteFileClipboardOffer();
    if (snapshot.hasFiles) {
      _fileClipboardOffers.arm(snapshot);
      _announceLocalFileClipboardOffer(snapshot);
      _setClipboardStatus(ClipboardSyncStatus.ready, '已记录文件，远程粘贴时开始传输');
      notifyListeners();
      return;
    }
    _revokeAnnouncedLocalFileClipboardOffer();
    unawaited(_fileClipboardOffers.invalidate());
    final offer = _clipboardSync.observeLocalChange(snapshot);
    if (snapshot.tooLarge) {
      _setClipboardStatus(ClipboardSyncStatus.error, '文本超过 256 KiB，未同步');
      return;
    }
    if (offer == null) {
      _updateClipboardStatus();
      notifyListeners();
      return;
    }
    if (!_remoteAllowsClipboardInbound) {
      if (_remoteClipboardMode == null &&
          _clipboardChannel?.state == RTCDataChannelState.RTCDataChannelOpen) {
        _queuedClipboardOffer = offer;
      }
      _updateClipboardStatus();
      notifyListeners();
      return;
    }
    _setClipboardStatus(ClipboardSyncStatus.sending, '正在发送剪贴板文本');
    _sendClipboard(offer.toMessage());
    _updateClipboardStatus();
  }

  void _announceLocalFileClipboardOffer(ClipboardSnapshot snapshot) {
    final sessionId = _activeFilePasteSessionId;
    final offerId = _fileClipboardOffers.currentOfferId;
    final generation = _fileClipboardOffers.currentGeneration;
    if (sessionId == null ||
        offerId == null ||
        generation == null ||
        !_remoteSupportsDestinationLeasedFilePasteV1 ||
        !_remoteAllowsClipboardInbound ||
        _clipboardChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    final identity = FileClipboardOfferIdentity(
      sessionId: sessionId,
      offerId: offerId,
      generation: generation,
      revision: snapshot.revision,
    );
    _announcedLocalFileOffer = identity;
    _sendClipboard(
      remoteFileOfferMessage(
        sessionId: identity.sessionId,
        offerId: offerId,
        generation: generation,
        revision: snapshot.revision,
        names: snapshot.filePaths.map(_fileName).toList(growable: false),
      ),
    );
  }

  void _revokeAnnouncedLocalFileClipboardOffer() {
    final offer = _announcedLocalFileOffer;
    _announcedLocalFileOffer = null;
    if (offer != null) {
      _sendClipboard(
        remoteFileOfferRevokeMessage(
          sessionId: offer.sessionId,
          offerId: offer.offerId,
          generation: offer.generation,
        ),
      );
    }
  }

  void _clearRemoteFileClipboardOffer() {
    if (_remoteFileClipboardOffer == null) return;
    _remoteFileClipboardOffer = null;
    unawaited(
      _filePasteTargetPlatform.setRemoteOfferAvailable(
        ownerId: _filePasteOwnerId,
        available: false,
      ),
    );
  }

  Future<void> _announceCurrentFileClipboardOffer() async {
    if (!_clipboardPlatform.supported ||
        !_remoteSupportsDestinationLeasedFilePasteV1) {
      return;
    }
    try {
      final snapshot = await _clipboardPlatform.readSnapshot();
      if (!snapshot.hasFiles) return;
      _fileClipboardOffers.arm(snapshot);
      _announceLocalFileClipboardOffer(snapshot);
    } catch (_) {
      // Clipboard ownership may change while the data channel opens.
    }
  }

  Future<void> _handleLocalRemoteFilePasteIntent() async {
    final offer = _remoteFileClipboardOffer;
    if (offer == null ||
        !_remoteSupportsDestinationLeasedFilePasteV1 ||
        !explicitFileTransferReady) {
      return;
    }
    final ticket = _filePasteIntentGate.begin(
      sessionId: offer.sessionId,
      offerId: offer.id,
      generation: offer.generation,
    );
    FilePasteDestinationLease? lease;
    try {
      final target = await _filePasteTargetPlatform.captureActiveTarget();
      if (!target.writable) {
        throw StateError('${target.application} 当前目录不可写');
      }
      lease = _filePasteDestinationLeases.create(
        transaction: ticket.transaction,
        target: target,
      );
      await _filePasteTargetPlatform.setRemoteOfferAvailable(
        ownerId: _filePasteOwnerId,
        available: false,
      );
      _remoteFileClipboardOffer = null;
      _sendClipboard(
        remoteFilePasteRequestMessage(
          transaction: ticket.transaction,
          destinationLeaseId: lease.id,
        ),
      );
      final acceptedLeaseId = await ticket.ready.timeout(
        const Duration(seconds: 12),
        onTimeout: () => null,
      );
      if (acceptedLeaseId != lease.id) {
        _filePasteDestinationLeases.revoke(lease.id);
        _emitNotice('远端文件 Offer 已失效，本次未传输', level: RemoteNoticeLevel.warning);
        return;
      }
      _remoteFileClipboardOffer = null;
      _emitNotice('已锁定本机 ${target.application} · ${target.displayName}，等待远端文件');
    } catch (error) {
      if (lease != null) _filePasteDestinationLeases.revoke(lease.id);
      _emitNotice('无法启动远端文件粘贴：$error', level: RemoteNoticeLevel.error);
    } finally {
      _filePasteIntentGate.cancel(ticket.transaction.pasteIntentId);
    }
  }

  static String _fileName(String path) {
    final normalized = path
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    return normalized.split('/').last;
  }

  String? get _activeFilePasteSessionId =>
      role == RemoteRole.host ? _filePasteSessionId : _remoteFilePasteSessionId;

  Future<String?> _publishLocalFileClipboard(
    ClipboardSnapshot snapshot, {
    required String destinationLeaseId,
  }) async {
    if (!snapshot.hasFiles ||
        !_clipboardMode.allowsOutbound(
          localIsController: role == RemoteRole.controller,
        )) {
      return null;
    }
    if (!fileClipboardReady || !_remoteAllowsClipboardInbound) {
      _emitNotice('远程设备尚未就绪或不支持活动目录文件粘贴', level: RemoteNoticeLevel.warning);
      return null;
    }
    _setClipboardStatus(ClipboardSyncStatus.sending, '远程粘贴已触发，正在传输文件');
    try {
      _fileClipboardOffers.arm(snapshot);
      final transferId = await _fileClipboardOffers.materialize(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      );
      notifyListeners();
      return transferId;
    } catch (error) {
      _setClipboardStatus(ClipboardSyncStatus.error, '文件剪贴板同步失败：$error');
      return null;
    }
  }

  Future<void> _cancelSupersededFileClipboardTransfer(String transferId) async {
    final task = _fileTransfer.tasks
        .where((candidate) => candidate.id == transferId)
        .firstOrNull;
    if (task?.canCancel == true) await _fileTransfer.cancel(transferId);
  }

  bool get _remoteAllowsClipboardInbound {
    final remoteMode = _remoteClipboardMode;
    return remoteMode != null &&
        remoteMode.allowsInbound(
          localIsController: role != RemoteRole.controller,
        );
  }

  void _setClipboardStatus(ClipboardSyncStatus status, String message) {
    _clipboardStatus = status;
    _clipboardStatusMessage = message;
    notifyListeners();
  }

  void _updateClipboardStatus() {
    if (!_clipboardPlatform.supported) {
      _clipboardStatus = ClipboardSyncStatus.unavailable;
      _clipboardStatusMessage = _clipboardStatus.label;
    } else if (_clipboardMode == ClipboardSyncMode.disabled) {
      _clipboardStatus = ClipboardSyncStatus.disabled;
      _clipboardStatusMessage = _clipboardStatus.label;
    } else if ((!_remoteSupportsTextClipboardV1 &&
            !_remoteSupportsDestinationLeasedFilePasteV1) ||
        _clipboardChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      _clipboardStatus = ClipboardSyncStatus.waitingForPeer;
      _clipboardStatusMessage = _clipboardStatus.label;
    } else if (_remoteClipboardMode == ClipboardSyncMode.disabled) {
      _clipboardStatus = ClipboardSyncStatus.ready;
      _clipboardStatusMessage = '远程设备已关闭剪贴板同步';
    } else {
      _clipboardStatus = ClipboardSyncStatus.ready;
      _clipboardStatusMessage = _clipboardPlatform.automaticMonitoringSupported
          ? '剪贴板同步已就绪 · ${_clipboardMode.label}'
                '${fileClipboardReady ? ' · 支持文件' : ''}'
          : '点击远程粘贴时读取 iPad 剪贴板';
    }
  }

  Future<void> connect({
    required String serverUrl,
    required String roomCode,
    bool announceLifecycle = true,
  }) async {
    if (!_rendererReady) {
      await initialize();
    }
    if (!_rendererReady) {
      return;
    }

    await _closeSession(notifyPeer: false);
    _closing = false;
    final sessionId = _kernel.begin(localDeviceId: _localDeviceId);
    _fileCopyPaste.beginSession(sessionId: sessionId);
    _error = null;
    _hostInvitationExpiresAt = null;
    _hostInvitationCode = null;
    _hostInvitationLeaseId = null;
    _hostInvitationGeneration = 0;
    _hostInvitationState = HostInvitationState.unavailable;
    _supportsInvitationRotation = false;
    if (role == RemoteRole.controller) {
      _controlError = null;
    }
    _inputConfirmed = false;
    if (announceLifecycle) _emitNotice('正在连接远程设备');

    try {
      final clientCapabilities = buildRemoteClientCapabilities(
        role: role,
        platform: Platform.operatingSystem,
        clipboardSupported: _clipboardPlatform.supported,
        explicitFileTransferSupported: localExplicitFileTransferSupported,
        fileClipboardSupported: fileClipboardSupported,
      );
      final endpoint = buildSignalingUri(
        serverUrl: serverUrl,
        roomCode: roomCode,
        role: role,
        deviceId: _localDeviceId,
        clientPlatform: Platform.operatingSystem,
        clientCapabilities: clientCapabilities,
      );
      _signalingServerUrl = serverUrl;
      await _createPeerConnection();
      _setState(RemoteSessionState.connecting, '正在连接信令服务');
      await _signaling.connect(
        uri: endpoint,
        onMessage: (message) async {
          try {
            await _handleSignalingMessage(message);
          } catch (error) {
            _fail('信令处理失败：$error', announce: announceLifecycle);
          }
        },
        onDone: _handleSignalingClosed,
      );
    } catch (error) {
      await _closeSession(notifyPeer: false);
      _fail('连接失败：$error', announce: announceLifecycle);
    }
  }

  Future<void> approve() async {
    if (role != RemoteRole.host) {
      return;
    }
    await _authorizePeer();
  }

  Future<void> rotateHostInvitation() async {
    if (role != RemoteRole.host ||
        state != RemoteSessionState.waitingForPeer ||
        !_signaling.isConnected) {
      throw StateError('当前无法刷新连接码');
    }
    if (!_supportsInvitationRotation) {
      throw UnsupportedError('信令服务版本过旧，请重新构建并启动 Java 服务');
    }
    if (_invitationRotationCompleter != null) return;
    final completer = Completer<void>();
    _invitationRotationCompleter = completer;
    _hostInvitationState = HostInvitationState.rotating;
    notifyListeners();
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    _signaling.send({
      'type': 'rotate-invitation',
      'requestId': requestId,
      if (_hostInvitationLeaseId != null) 'leaseId': _hostInvitationLeaseId,
      'generation': _hostInvitationGeneration,
    });
    try {
      await completer.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      _hostInvitationState = _hostInvitationCode == null
          ? HostInvitationState.unavailable
          : HostInvitationState.expired;
      notifyListeners();
      rethrow;
    } finally {
      if (identical(_invitationRotationCompleter, completer)) {
        _invitationRotationCompleter = null;
      }
    }
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
    final message = role == RemoteRole.host ? '已停止接收远程连接' : '远程会话已断开';
    _setState(RemoteSessionState.disconnected, message);
    _emitNotice(message);
  }

  void clearConnectionAttemptFeedback() {
    if (role != RemoteRole.controller ||
        state != RemoteSessionState.disconnected) {
      return;
    }
    _error = null;
    _setState(RemoteSessionState.idle, '请输入新的连接码');
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
    List<String> modifiers = const [],
  }) {
    // Input must follow the frame the controller has actually rendered. During
    // a display-switch transaction `_selectedDisplayId` may describe the UI
    // target before media for that display is ready.
    final displayId = _renderedDisplayId ?? _selectedDisplayId;
    if (!canSendControl || displayId == null) {
      if (phase == 'down') {
        explainControlUnavailable();
      }
      return;
    }
    if (phase == 'down' || phase == 'scroll') {
      _remoteInputEpoch += 1;
    }
    // Only pointer position is allowed on the unordered motion channel.
    // Scroll and button transitions are stateful and remain FIFO with keys.
    final isMotion = phase == 'move';
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
      if (!isMotion) 'modifiers': modifiers,
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
    int? physicalHidUsage,
    bool repeat = false,
  }) {
    if (!canSendControl) {
      explainControlUnavailable();
      return;
    }
    if (phase == 'down' && !_isModifierWireKey(key)) {
      _remoteInputEpoch += 1;
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
      'physicalHidUsage': ?physicalHidUsage,
      if (repeat) 'repeat': true,
    });
  }

  /// Resets one input ownership domain on the host. Focus transitions use the
  /// keyboard scope; pointer cancellation uses pointer; only session teardown
  /// may use all. This remains available during a display switch.
  void resetRemoteInput(RemoteInputResetScope scope, {required String reason}) {
    final channel = _controlChannel;
    if (role != RemoteRole.controller ||
        channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    if (!_remoteSupportsScopedInputResetV1) {
      // A legacy peer only understands a destructive full reset. Preserve it
      // for true session teardown, but never turn focus loss into pointer-up.
      if (scope != RemoteInputResetScope.all) return;
      _sendControl({
        'type': 'release-input',
        'version': 2,
        'sequence': ++_inputSequence,
        'sentAtUnixMicros': DateTime.now().microsecondsSinceEpoch,
      });
      return;
    }
    _sendControl({
      'type': 'input-reset',
      'version': 2,
      'sequence': ++_inputSequence,
      'sentAtUnixMicros': DateTime.now().microsecondsSinceEpoch,
      'scope': scope.wireValue,
      'reason': reason,
    });
  }

  void sendText(String text) {
    if (!canSendControl || text.isEmpty) {
      if (text.isNotEmpty) {
        explainControlUnavailable();
      }
      return;
    }
    _remoteInputEpoch += 1;
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

  Future<void> sendPrimaryShortcut(String key) async {
    if (!RemoteShortcutPolicy.commonWireKeys.contains(key)) return;
    if (!canSendControl) {
      explainControlUnavailable();
      return;
    }
    if (key == 'KeyV' && fileClipboardPastePending) {
      _emitNotice('文件仍在同步，完成后会自动继续粘贴');
      return;
    }
    final inputEpoch = ++_remoteInputEpoch;
    if (key == 'KeyV' &&
        !await _prepareRemoteClipboardPaste(inputEpoch: inputEpoch)) {
      return;
    }
    if (!canSendControl) return;
    final modifiers = [remotePrimaryShortcutModifier];
    if (_remoteSupportsAtomicShortcutV1) {
      _sendControl({
        'type': 'shortcut',
        'version': 2,
        'sequence': ++_inputSequence,
        'sentAtUnixMicros': DateTime.now().microsecondsSinceEpoch,
        'key': key,
        'modifiers': modifiers,
      });
    } else {
      // Preserve interoperability with peers released before atomic shortcut
      // capability negotiation was introduced.
      sendKey(phase: 'down', key: key, modifiers: modifiers);
      sendKey(phase: 'up', key: key, modifiers: modifiers);
    }
  }

  Future<bool> _prepareRemoteClipboardPaste({required int inputEpoch}) async {
    final channel = _clipboardChannel;
    if (!_clipboardPlatform.supported ||
        channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return true;
    }
    try {
      final snapshot = await _clipboardPlatform.readSnapshot();
      if (snapshot.hasFiles) {
        if (!_remoteAllowsClipboardInbound) {
          _emitNotice('远程设备当前不允许接收剪贴板', level: RemoteNoticeLevel.warning);
          return false;
        }
        return await _prepareRemoteFileClipboardPaste(
          snapshot,
          inputEpoch: inputEpoch,
        );
      }
      await _fileClipboardOffers.invalidate();
      if (!_remoteSupportsTextClipboardV1 || !_remoteAllowsClipboardInbound) {
        return true;
      }
      if (snapshot.tooLarge) {
        _setClipboardStatus(ClipboardSyncStatus.error, '文本超过 256 KiB，无法远程粘贴');
        return false;
      }
      final offer = _clipboardSync.prepareExplicitOutbound(snapshot);
      if (offer == null) return true;
      _setClipboardStatus(ClipboardSyncStatus.sending, '正在准备远程粘贴');
      _sendClipboard(offer.toMessage());
      if (_remoteClipboardSupportsApplied) {
        await _clipboardApplyGate.waitFor(offer);
      }
      _updateClipboardStatus();
      notifyListeners();
      return true;
    } catch (error) {
      _setClipboardStatus(ClipboardSyncStatus.error, '远程粘贴准备失败：$error');
      return false;
    }
  }

  Future<bool> _prepareRemoteFileClipboardPaste(
    ClipboardSnapshot snapshot, {
    required int inputEpoch,
  }) async {
    if (!fileClipboardReady) {
      _emitNotice(
        '远程设备不支持活动目录文件粘贴，请使用“文件传输”',
        level: RemoteNoticeLevel.warning,
      );
      return false;
    }
    _fileClipboardPastePreparing = true;
    notifyListeners();
    String? preparedTransferId;
    FilePasteIntentTicket? ticket;
    String? destinationLeaseId;
    var committedToDestination = false;
    try {
      _fileClipboardOffers.arm(snapshot);
      final sessionId = _activeFilePasteSessionId;
      final offerId = _fileClipboardOffers.currentOfferId;
      final generation = _fileClipboardOffers.currentGeneration;
      if (sessionId == null || offerId == null || generation == null) {
        _emitNotice('本机文件 Offer 已失效，请重新复制文件', level: RemoteNoticeLevel.warning);
        return false;
      }
      ticket = _filePasteIntentGate.begin(
        sessionId: sessionId,
        offerId: offerId,
        generation: generation,
      );
      _sendClipboard(
        filePastePrepareMessage(
          transaction: ticket.transaction,
          revision: snapshot.revision,
        ),
      );
      destinationLeaseId = await ticket.ready.timeout(
        const Duration(seconds: 12),
        onTimeout: () => null,
      );
      if (destinationLeaseId == null) {
        _emitNotice(
          '未能锁定远程 Finder/文件资源管理器目录，本次未传输',
          level: RemoteNoticeLevel.warning,
        );
        return false;
      }
      if (_remoteInputEpoch != inputEpoch) {
        _emitNotice('检测到其他输入，本次文件粘贴已取消');
        return false;
      }
      final transferId = await _publishLocalFileClipboard(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      );
      if (transferId == null) return false;
      preparedTransferId = transferId;
      _fileClipboardPasteTransferId = transferId;
      _fileClipboardPastePreparing = false;
      _emitNotice('已锁定远程目标目录，正在传输文件');
      notifyListeners();
      final applied = await _filePasteCommitGate.waitFor(
        transferId,
        transaction: ticket.transaction,
        destinationLeaseId: destinationLeaseId,
      );
      if (!applied) {
        _emitNotice('文件未能提交到锁定的远程目录', level: RemoteNoticeLevel.error);
        return false;
      }
      committedToDestination = true;
      _emitNotice('文件已保存到按下粘贴时锁定的远程目录', level: RemoteNoticeLevel.success);
      // The explicit transfer has already committed the files. Never inject a
      // second OS Paste shortcut, which would duplicate or redirect them.
      return false;
    } finally {
      if (ticket != null) {
        _filePasteIntentGate.cancel(ticket.transaction.pasteIntentId);
      }
      if (preparedTransferId != null) {
        if (committedToDestination) {
          _fileClipboardOffers.releaseTransfer(preparedTransferId);
        } else {
          unawaited(
            _fileClipboardOffers.invalidateTransfer(preparedTransferId),
          );
        }
      }
      if (!committedToDestination &&
          ticket != null &&
          destinationLeaseId != null) {
        _sendClipboard(
          filePasteCancelMessage(
            transaction: ticket.transaction,
            destinationLeaseId: destinationLeaseId,
          ),
        );
      }
      _fileClipboardPastePreparing = false;
      _fileClipboardPasteTransferId = null;
      _updateClipboardStatus();
      notifyListeners();
    }
  }

  Future<String> sendExplicitFiles(List<String> paths) =>
      _fileTransfer.sendFiles(paths);

  Future<String?> pickAndSendExplicitFiles() async {
    final paths = await _fileTransferPlatform.pickOutgoingFiles();
    if (paths.isEmpty) return null;
    try {
      final transferId = await _fileTransfer.sendFiles(paths);
      _stagedOutgoingFiles[transferId] = List.unmodifiable(paths);
      _handleFileTransferChanged();
      return transferId;
    } catch (_) {
      await _fileTransferPlatform.cleanupOutgoingFiles(paths);
      rethrow;
    }
  }

  Future<String> sendExplicitDirectory(String path) =>
      _fileTransferPlatform.supportsDirectorySelection
      ? _fileTransfer.sendDirectory(path)
      : throw UnsupportedError('iPad 暂不支持直接发送目录');

  Future<void> acceptExplicitFileTransfer(
    String transferId,
    String destinationRoot,
  ) => _fileTransfer.accept(transferId, destinationRoot);

  Future<void> acceptExplicitFileTransferToManagedStorage(
    String transferId,
  ) async {
    final destination = await _fileTransferPlatform.createReceiveDirectory(
      transferId,
    );
    await _fileTransfer.accept(transferId, destination);
  }

  Future<void> exportExplicitFileTransfer(String transferId) async {
    await _fileTransferPlatform.exportReceivedFiles(
      await _completedIncomingTransferPaths(transferId),
    );
  }

  Future<void> shareExplicitFileTransfer(String transferId) async {
    await _fileTransferPlatform.shareReceivedFiles(
      await _completedIncomingTransferPaths(transferId),
    );
  }

  Future<List<String>> _completedIncomingTransferPaths(
    String transferId,
  ) async {
    final task = _fileTransfer.tasks
        .where((item) => item.id == transferId)
        .firstOrNull;
    if (task == null ||
        !task.isIncoming ||
        task.state != ExplicitFileTransferState.completed ||
        task.destinationRoot == null) {
      throw StateError('文件尚未接收完成');
    }
    final paths = await Directory(task.destinationRoot!).list().map((entity) {
      return entity.path;
    }).toList();
    if (paths.isEmpty) throw StateError('接收目录中没有可导出的文件');
    return paths;
  }

  Future<void> rejectExplicitFileTransfer(String transferId) =>
      _fileTransfer.reject(transferId);

  Future<void> pauseExplicitFileTransfer(String transferId) =>
      _fileTransfer.pause(transferId);

  Future<void> resumeExplicitFileTransfer(String transferId) =>
      _fileTransfer.resume(transferId);

  Future<void> cancelExplicitFileTransfer(String transferId) =>
      _fileTransfer.cancel(transferId);

  void _handleFileTransferChanged() {
    for (final task in _fileTransfer.tasks) {
      _kernel.recordTransfer(
        transferId: task.id,
        direction: task.direction.name,
        state: task.state.name,
        transferredBytes: task.transferredBytes,
        totalBytes: task.totalBytes,
        destinationRoot: task.destinationRoot,
        items: task.entries
            .map(
              (entry) => RemoteTransferItemMetadata(
                relativePath: entry.relativePath,
                sizeBytes: entry.sizeBytes,
                kind: entry.kind.name,
                sourcePath: entry.sourcePath,
              ),
            )
            .toList(growable: false),
      );
    }
    for (final entry in _stagedOutgoingFiles.entries.toList(growable: false)) {
      final task = _fileTransfer.tasks
          .where((item) => item.id == entry.key)
          .firstOrNull;
      if (task == null || !task.canCancel) {
        _stagedOutgoingFiles.remove(entry.key);
        unawaited(_fileTransferPlatform.cleanupOutgoingFiles(entry.value));
      }
    }
    unawaited(_synchronizeFileClipboardTransfers());
    notifyListeners();
  }

  Future<void> _synchronizeFileClipboardTransfers() async {
    if (_synchronizingFileClipboardTransfers) {
      _fileClipboardSynchronizationRequested = true;
      return;
    }
    _synchronizingFileClipboardTransfers = true;
    try {
      do {
        _fileClipboardSynchronizationRequested = false;
        await _synchronizeFileClipboardTransferPass();
      } while (_fileClipboardSynchronizationRequested);
    } finally {
      _synchronizingFileClipboardTransfers = false;
      notifyListeners();
    }
  }

  Future<void> _synchronizeFileClipboardTransferPass() async {
    final tasks = _fileTransfer.tasks
        .where(
          (task) =>
              task.isClipboard &&
              !_retiredFileClipboardTransfers.contains(task.id),
        )
        .toList(growable: false);
    for (final task in tasks) {
      if (task.isIncoming) {
        if (task.awaitsAcceptance) {
          if (!_remoteSupportsDestinationLeasedFilePasteV1 ||
              !_clipboardPlatform.fileClipboardSupported ||
              task.destinationLeaseId == null) {
            await _fileTransfer.reject(task.id);
            continue;
          }
          if (!_acceptingFileClipboardTransfers.add(task.id)) continue;
          try {
            final lease = _filePasteDestinationLeases.take(
              task.destinationLeaseId!,
            );
            if (lease == null) {
              await _fileTransfer.reject(task.id);
              _emitNotice(
                '粘贴目标租约已失效，本次未写入任何文件',
                level: RemoteNoticeLevel.warning,
              );
              continue;
            }
            if (!await _filePasteTargetPlatform.validateTarget(lease.target)) {
              await _fileTransfer.reject(task.id);
              _emitNotice(
                '粘贴目标已被替换、删除或失去写入权限，本次未写入任何文件',
                level: RemoteNoticeLevel.warning,
              );
              continue;
            }
            await _fileTransfer.accept(task.id, lease.target.path);
            _filePasteLeaseByTransferId[task.id] = lease;
            _setClipboardStatus(
              ClipboardSyncStatus.receiving,
              '正在传输到 ${lease.target.application} · ${lease.target.displayName}',
            );
          } catch (error) {
            if (task.awaitsAcceptance) {
              await _fileTransfer.reject(task.id);
            }
            _emitNotice('活动目录文件接收失败：$error', level: RemoteNoticeLevel.error);
          } finally {
            _acceptingFileClipboardTransfers.remove(task.id);
          }
          continue;
        }
        if (task.state == ExplicitFileTransferState.completed &&
            _appliedFileClipboardTransfers.add(task.id)) {
          final lease = _filePasteLeaseByTransferId.remove(task.id);
          if (lease == null) {
            _emitNotice('文件已接收，但粘贴事务身份已丢失', level: RemoteNoticeLevel.error);
            continue;
          }
          _sendClipboard(
            filePasteCommittedMessage(
              transaction: lease.transaction,
              destinationLeaseId: lease.id,
              transferId: task.id,
            ),
          );
          _setClipboardStatus(ClipboardSyncStatus.ready, '远程文件已保存到锁定的活动目录');
          continue;
        }
        if ({
          ExplicitFileTransferState.failed,
          ExplicitFileTransferState.rejected,
          ExplicitFileTransferState.cancelled,
        }.contains(task.state)) {
          _filePasteLeaseByTransferId.remove(task.id);
        }
      }
      if (!task.isIncoming &&
          {
            ExplicitFileTransferState.failed,
            ExplicitFileTransferState.rejected,
            ExplicitFileTransferState.cancelled,
          }.contains(task.state)) {
        _filePasteCommitGate.fail(task.id);
      }
    }
  }

  void selectDisplay(String displayId) {
    if (role != RemoteRole.controller ||
        !displays.any((display) => display.id == displayId)) {
      return;
    }
    if (_displaySwitchPending) {
      _emitNotice('正在切换显示器，请稍候', level: RemoteNoticeLevel.warning);
      return;
    }
    if (displayId == _selectedDisplayId) return;
    final generation = _displaySwitch.beginLocalRequest(displayId);
    _displaySwitchRequestTimer?.cancel();
    _displaySwitchRequestTimer = Timer(const Duration(seconds: 15), () {
      if (!_displaySwitchPending || generation != _displaySwitchGeneration) {
        return;
      }
      _displaySwitch.fail(
        generation: generation,
        code: 'CONTROLLER_REQUEST_TIMEOUT',
      );
      notifyListeners();
      _emitNotice('显示器切换超时，请重试', level: RemoteNoticeLevel.warning);
      _flushQueuedQualityRequest();
    });
    notifyListeners();
    _sendControl(
      remoteDisplaySwitchMessage(
        type: 'select-display',
        displayId: displayId,
        generation: generation,
      ),
    );
    _emitNotice('正在切换远程显示器');
  }

  Future<void> requestHostInputPermission() async {
    if (role != RemoteRole.host || !_hostPlatform.capabilities.canHostDesktop) {
      return;
    }
    try {
      final permission = await _hostPlatform.requestPermissions();
      _applyHostPermissionState(permission);
      if (_accessibilityGranted == true) {
        _controlError = null;
        _emitNotice('远程输入权限已就绪', level: RemoteNoticeLevel.success);
        final limitation = permission.limitation;
        if (limitation != null) {
          _emitNotice(limitation, level: RemoteNoticeLevel.warning);
        }
      } else {
        _controlError = permission.limitation ?? '本机尚未允许远程鼠标和键盘输入';
        if (_hostPlatform.capabilities.permissionSettings) {
          await _hostPlatform.openPermissionSettings();
        }
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

  Future<void> requestHostScreenCapturePermission() async {
    if (role != RemoteRole.host || !_hostPlatform.capabilities.canHostDesktop) {
      return;
    }
    try {
      final permission = await _hostPlatform.requestScreenCapturePermission();
      _applyHostPermissionState(permission);
      if (_screenCaptureGranted) {
        _emitNotice('屏幕录制权限已就绪', level: RemoteNoticeLevel.success);
      } else {
        if (_hostPlatform.capabilities.capturePermissionSettings) {
          await _hostPlatform.openScreenCapturePermissionSettings();
        }
        _emitNotice(
          permission.screenCaptureLimitation ??
              '请在系统设置中允许 CrossDesktopRemote 录制屏幕，然后返回应用',
          level: RemoteNoticeLevel.warning,
        );
      }
      _publishHostState();
      notifyListeners();
    } catch (error) {
      _emitNotice('无法打开屏幕录制权限设置：$error', level: RemoteNoticeLevel.error);
    }
  }

  Future<void> refreshHostPermissions({bool announce = false}) async {
    if (role != RemoteRole.host ||
        !_hostPlatform.capabilities.canHostDesktop ||
        _checkingInputPermission) {
      return;
    }
    _checkingInputPermission = true;
    try {
      final previous = _accessibilityGranted;
      final previousCapture = _screenCaptureGranted;
      final permission = await _hostPlatform.checkPermissions();
      _applyHostPermissionState(permission);
      _publishHostState();
      notifyListeners();
      if (_accessibilityGranted == true && previous != true) {
        _inputPermissionPollTimer?.cancel();
        _emitNotice('远程输入权限已生效', level: RemoteNoticeLevel.success);
      } else if (announce && _accessibilityGranted != true) {
        _emitNotice(_controlError!, level: RemoteNoticeLevel.warning);
      }
      if (_screenCaptureGranted && !previousCapture) {
        _emitNotice('屏幕录制权限已生效', level: RemoteNoticeLevel.success);
      } else if (announce && !_screenCaptureGranted) {
        _emitNotice(
          permission.screenCaptureLimitation ?? '本机尚未允许屏幕录制',
          level: RemoteNoticeLevel.warning,
        );
      }
    } catch (error) {
      if (announce) {
        _emitNotice('检查远程输入权限失败：$error', level: RemoteNoticeLevel.error);
      }
    } finally {
      _checkingInputPermission = false;
    }
  }

  void _applyHostPermissionState(HostPermissionState permission) {
    _accessibilityGranted = permission.inputGranted;
    _screenCaptureGranted = permission.screenCaptureGranted;
    _controlError = permission.inputGranted
        ? null
        : permission.limitation ?? '本机尚未允许远程鼠标和键盘输入';
  }

  void explainControlUnavailable() {
    final now = DateTime.now();
    if (_lastControlUnavailableNotice != null &&
        now.difference(_lastControlUnavailableNotice!) <
            const Duration(seconds: 3)) {
      return;
    }
    _lastControlUnavailableNotice = now;
    final message = _displaySwitchPending
        ? '正在切换显示器，远程输入已暂时暂停'
        : _controlChannel?.state != RTCDataChannelState.RTCDataChannelOpen
        ? '远程控制通道尚未就绪'
        : _accessibilityGranted != true
        ? '被控设备尚未允许鼠标和键盘输入'
        : '当前会话暂时无法发送控制指令';
    _emitNotice(message, level: RemoteNoticeLevel.warning);
  }

  void setIdleQuality(RemoteQualityProfile profile) {
    setIdleVideoPolicy(RemoteVideoPolicy.fromLegacy(profile));
  }

  void setIdleVideoPolicy(RemoteVideoPolicy policy) {
    if (!{
      RemoteSessionState.idle,
      RemoteSessionState.initializing,
      RemoteSessionState.disconnected,
      RemoteSessionState.failed,
    }.contains(_state)) {
      return;
    }
    if (_selectedVideoPolicy == policy) return;
    if (policy.fullyAutomatic) {
      _qualityAdaptation.reset();
    }
    _selectedVideoPolicy = policy;
    _selectedQuality = policy.legacyProfile;
    notifyListeners();
  }

  void selectQuality(RemoteQualityProfile profile) {
    selectVideoPolicy(RemoteVideoPolicy.fromLegacy(profile));
  }

  void selectVideoPolicy(RemoteVideoPolicy policy) {
    if (role != RemoteRole.controller) {
      return;
    }
    if (_controlChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      _emitNotice('视频控制通道尚未就绪', level: RemoteNoticeLevel.warning);
      return;
    }
    if (_displaySwitchPending) {
      _queuedVideoPolicy = policy;
      _emitNotice('已记录清晰度调整，将在显示器切换后应用');
      return;
    }
    if (_remoteSupportsVideoPolicyV2) {
      _requestVideoPolicy(policy);
    } else {
      _requestQuality(policy.legacyProfile);
    }
  }

  void _requestVideoPolicy(RemoteVideoPolicy policy) {
    _startQualityRequestTimeout();
    _sendControl({
      'type': 'set-video-policy',
      'version': 2,
      'policy': policy.toMessage(),
    });
    _emitNotice('正在应用 ${policy.label}');
  }

  void _requestQuality(RemoteQualityProfile profile) {
    _startQualityRequestTimeout();
    _sendControl({
      'type': 'set-quality',
      'version': 2,
      'profile': profile.name,
    });
    _emitNotice('正在切换到${profile.label}');
  }

  void _startQualityRequestTimeout() {
    _qualityPending = true;
    _qualityRequestTimer?.cancel();
    _qualityRequestTimer = Timer(const Duration(seconds: 8), () {
      if (!_qualityPending) return;
      _qualityPending = false;
      notifyListeners();
      _emitNotice('画质切换超时，请检查远程连接', level: RemoteNoticeLevel.warning);
    });
    notifyListeners();
  }

  void _flushQueuedQualityRequest() {
    if (role != RemoteRole.controller || _displaySwitchPending) return;
    final policy = _queuedVideoPolicy;
    if (policy != null) {
      _queuedVideoPolicy = null;
      if (_remoteSupportsVideoPolicyV2) {
        _requestVideoPolicy(policy);
      } else {
        _requestQuality(policy.legacyProfile);
      }
      return;
    }
    final profile = _queuedQualityProfile;
    if (profile == null) return;
    _queuedQualityProfile = null;
    _requestQuality(profile);
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

  /// Repairs presentation and input state without rebuilding the signaling or
  /// PeerConnection. The host requests a fresh key frame and republishes its
  /// authoritative state; desktop controllers then rebind the native texture.
  Future<void> repairRemoteSession() async {
    if (role != RemoteRole.controller || _sessionRepairPending) return;
    if (_controlChannel?.state != RTCDataChannelState.RTCDataChannelOpen) {
      _emitNotice('控制通道尚未就绪，无法修复当前画面', level: RemoteNoticeLevel.warning);
      return;
    }
    if (_displaySwitchPending) {
      _emitNotice('显示器切换完成后才能修复当前画面', level: RemoteNoticeLevel.warning);
      return;
    }

    _sessionRepairPending = true;
    _controlError = null;
    final requestId = DateTime.now().microsecondsSinceEpoch.toString();
    _sessionRepairRequestId = requestId;
    final completion = Completer<Map<String, dynamic>>();
    _sessionRepairCompleter = completion;
    int? baselineFrames;
    try {
      baselineFrames = (await _readRtcVideoProgress('inbound-rtp'))?.frames;
    } catch (_) {
      // Stats are best-effort; the host acknowledgement remains authoritative.
    }
    notifyListeners();
    _sendControl({
      'type': 'repair-session',
      'version': 2,
      'requestId': requestId,
    });
    _emitNotice('正在修复当前画面和控制状态');

    try {
      final response = await completion.future.timeout(
        _remoteHostPlatform == HostPlatformType.windows.name
            ? const Duration(seconds: 6)
            : const Duration(seconds: 3),
      );
      if (response['ok'] != true) {
        throw StateError(response['message'] as String? ?? '被控端无法执行修复');
      }
      // Reattach the existing stream before waiting for the fresh key frame.
      // This rebuilds only the desktop texture sink and preserves signaling,
      // the PeerConnection, sender and DataChannels.
      if (Platform.isWindows || Platform.isMacOS) {
        await _rebindRemoteRenderer();
      }
      final progress = await _waitForInboundVideoProgress(
        afterFrames: baselineFrames,
        attempts: 20,
      );
      _inputConfirmed = false;
      if (progress == null) {
        _emitNotice(
          '状态已重新同步，但暂未确认新视频帧；桌面静止时可先移动窗口检查',
          level: RemoteNoticeLevel.warning,
        );
      } else {
        _emitNotice('当前画面和控制状态已修复', level: RemoteNoticeLevel.success);
      }
    } on TimeoutException catch (error) {
      _emitNotice(
        '修复超时：${error.message ?? '请检查网络后重试'}',
        level: RemoteNoticeLevel.warning,
      );
    } catch (error) {
      _emitNotice('修复当前画面失败：$error', level: RemoteNoticeLevel.error);
    } finally {
      if (identical(_sessionRepairCompleter, completion)) {
        _sessionRepairCompleter = null;
        _sessionRepairRequestId = null;
      }
      _sessionRepairPending = false;
      notifyListeners();
    }
  }

  Future<void> _rebindRemoteRenderer() async {
    final stream = remoteRenderer.srcObject;
    if (stream == null) return;
    await remoteRenderer.setSrcObject(stream: null);
    await Future<void>.delayed(Duration.zero);
    await remoteRenderer.setSrcObject(stream: stream);
  }

  void refreshColorDiagnostics() {
    if (role == RemoteRole.controller) {
      _sendControl({'type': 'refresh-color-diagnostics', 'version': 2});
    }
  }

  void showRemoteGrayscaleTestPattern() {
    if (role == RemoteRole.controller) {
      _sendControl({'type': 'show-grayscale-test', 'version': 2});
      _emitNotice('已要求被控 Mac 显示 SDR 灰阶图');
    }
  }

  void openRemoteDisplaySettings() {
    if (role == RemoteRole.controller) {
      _sendControl({'type': 'open-display-settings', 'version': 2});
      _emitNotice('已要求被控 Mac 打开显示器设置');
    }
  }

  Future<void> _createPeerConnection() async {
    final peerConnection = await createPeerConnection({
      'iceServers': <Map<String, dynamic>>[],
      'sdpSemantics': 'unified-plan',
    });
    _peerConnection = peerConnection;

    bool isCurrentPeerConnection() {
      return !_closing && identical(_peerConnection, peerConnection);
    }

    peerConnection.onIceCandidate = (candidate) {
      if (!isCurrentPeerConnection() ||
          candidate.candidate == null ||
          !_signaling.isConnected) {
        return;
      }
      _signaling.send({'type': 'candidate', ...candidate.toMap()});
    };
    peerConnection.onTrack = (event) {
      if (!isCurrentPeerConnection() ||
          event.track.kind != 'video' ||
          event.streams.isEmpty) {
        return;
      }
      _videoReceiver = event.receiver;
      remoteRenderer.srcObject = event.streams.first;
      if (_state != RemoteSessionState.reconnecting) {
        _setState(RemoteSessionState.streaming, '正在显示远程屏幕');
      }
    };
    peerConnection.onDataChannel = (channel) {
      if (isCurrentPeerConnection()) {
        _attachDataChannel(channel);
      }
    };
    peerConnection.onConnectionState = (connectionState) {
      if (!isCurrentPeerConnection()) return;
      switch (connectionState) {
        case RTCPeerConnectionState.RTCPeerConnectionStateConnected:
          _markPeerConnectionConnected();
        case RTCPeerConnectionState.RTCPeerConnectionStateFailed:
          _cancelConnectionRecovery();
          _fail('WebRTC 连接失败');
        case RTCPeerConnectionState.RTCPeerConnectionStateDisconnected:
          _startConnectionRecovery(peerConnection);
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

  Future<void> _ensureClipboardDataChannel() async {
    if (role != RemoteRole.host ||
        !_clipboardPlatform.supported ||
        (!_remoteSupportsTextClipboardV1 &&
            !_remoteSupportsDestinationLeasedFilePasteV1) ||
        _clipboardChannel != null ||
        _peerConnection == null) {
      return;
    }
    final channel = await _peerConnection!.createDataChannel(
      'clipboard',
      RTCDataChannelInit()
        ..ordered = true
        ..protocol = 'crossdesktop-text-clipboard-v1',
    );
    _attachClipboardChannel(channel);
  }

  Future<void> _ensureExplicitFileTransferDataChannels() async {
    if (role != RemoteRole.host ||
        !localExplicitFileTransferSupported ||
        !_remoteSupportsExplicitFileTransferV1 ||
        _peerConnection == null) {
      return;
    }
    if (_fileTransferControlChannel == null) {
      final control = await _peerConnection!.createDataChannel(
        'file-transfer-control',
        RTCDataChannelInit()
          ..ordered = true
          ..protocol = 'crossdesktop-explicit-file-transfer-control-v1',
      );
      _attachFileTransferControlChannel(control);
    }
    if (_fileTransferDataChannel == null) {
      final data = await _peerConnection!.createDataChannel(
        'file-transfer-data',
        RTCDataChannelInit()
          ..ordered = true
          ..protocol = 'crossdesktop-explicit-file-transfer-data-v1',
      );
      _attachFileTransferDataChannel(data);
    }
  }

  void _markPeerConnectionConnected() {
    final recovered =
        _connectionEstablished &&
        (_state == RemoteSessionState.reconnecting ||
            _connectionRecoveryTimer?.isActive == true);
    _cancelConnectionRecovery();
    _connectionEstablished = true;
    _startMediaStatsSampling();
    _setState(RemoteSessionState.streaming, recovered ? '远程会话已恢复' : '远程会话已连接');
    _emitNotice(
      recovered ? '远程会话连接已恢复' : '远程会话连接成功',
      level: RemoteNoticeLevel.success,
    );
  }

  void _startConnectionRecovery(RTCPeerConnection peerConnection) {
    if (_connectionRecoveryTimer?.isActive == true) return;
    _setState(RemoteSessionState.reconnecting, '连接暂时中断，正在自动恢复');
    _emitNotice('网络连接出现波动，正在自动恢复', level: RemoteNoticeLevel.warning);
    _connectionRecoveryTimer = Timer(const Duration(seconds: 8), () {
      if (_closing ||
          !identical(_peerConnection, peerConnection) ||
          _state != RemoteSessionState.reconnecting) {
        return;
      }
      unawaited(_finishConnectionRecoveryTimeout());
    });
  }

  void _cancelConnectionRecovery() {
    _connectionRecoveryTimer?.cancel();
    _connectionRecoveryTimer = null;
  }

  void _startMediaStatsSampling() {
    _mediaStatsTimer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_sampleMediaDiagnostics());
    });
    unawaited(_sampleMediaDiagnostics());
  }

  Future<void> _sampleMediaDiagnostics() async {
    final peerConnection = _peerConnection;
    if (_closing || peerConnection == null || _samplingMediaStats) return;
    _samplingMediaStats = true;
    try {
      final reports = await peerConnection.getStats();
      final snapshot = RemoteMediaStatsSnapshot.fromReports(
        reports.map(
          (report) => <dynamic, dynamic>{
            ...report.values,
            'id': report.id,
            'type': report.type,
          },
        ),
      );
      final diagnostics = _mediaStatsAccumulator.update(snapshot);
      if (_closing || !identical(peerConnection, _peerConnection)) return;
      _mediaDiagnostics = diagnostics;
      notifyListeners();
      if (role == RemoteRole.host &&
          _selectedVideoPolicy.fullyAutomatic &&
          !_hostDisplaySwitchInProgress &&
          !_adaptiveQualityUpdateInProgress &&
          !_automaticQualityIsSuppressed) {
        final next = _qualityAdaptation.observe(diagnostics);
        if (next != null) {
          unawaited(_applyAdaptiveVideoTarget(next));
        }
      }
    } catch (_) {
      // WebRTC stats are best-effort diagnostics and never affect the session.
    } finally {
      _samplingMediaStats = false;
    }
  }

  Future<void> _applyAdaptiveVideoTarget(RemoteAdaptiveVideoTier tier) async {
    if (_adaptiveQualityUpdateInProgress ||
        _closing ||
        !_selectedVideoPolicy.fullyAutomatic) {
      return;
    }
    _adaptiveQualityUpdateInProgress = true;
    final completion = Completer<void>();
    _adaptiveQualityUpdateCompleter = completion;
    try {
      await _applyVideoQuality(
        RemoteQualityProfile.automatic,
        reportFailure: false,
      );
      _qualityAdaptation.confirmLastChange();
      _emitNotice('网络质量变化，已自动调整为 ${tier.label}');
    } catch (error) {
      _qualityAdaptation.rollbackLastChange();
      _emitNotice('自动画质调整暂未生效：$error', level: RemoteNoticeLevel.warning);
    } finally {
      _adaptiveQualityUpdateInProgress = false;
      if (!completion.isCompleted) completion.complete();
      if (identical(_adaptiveQualityUpdateCompleter, completion)) {
        _adaptiveQualityUpdateCompleter = null;
      }
    }
  }

  bool get _automaticQualityIsSuppressed {
    final until = _automaticQualitySuppressedUntil;
    return until != null && DateTime.now().isBefore(until);
  }

  Future<void> _waitForCaptureMutationsToSettle() async {
    final pending = <Future<void>>[];
    final adaptiveUpdate = _adaptiveQualityUpdateCompleter;
    if (adaptiveUpdate != null) pending.add(adaptiveUpdate.future);
    if (pending.isEmpty) return;
    await Future.wait(pending).timeout(const Duration(seconds: 8));
  }

  void _completeDisplaySwitchCoordination() {
    _hostDisplaySwitchInProgress = false;
    _automaticQualitySuppressedUntil = DateTime.now().add(
      const Duration(seconds: 5),
    );
    _mediaStatsAccumulator.reset();
  }

  Future<void> _finishConnectionRecoveryTimeout() async {
    if (_closing || _state != RemoteSessionState.reconnecting) return;
    await _closeSession(notifyPeer: true);
    _setState(RemoteSessionState.disconnected, 'WebRTC 连接恢复超时');
    _emitNotice('远程会话连接恢复超时', level: RemoteNoticeLevel.warning);
  }

  void _attachDataChannel(RTCDataChannel channel) {
    switch (channel.label) {
      case 'control':
        _attachControlChannel(channel);
      case 'input-motion':
        _attachMotionChannel(channel);
      case 'clipboard':
        if (_clipboardPlatform.supported &&
            (_remoteSupportsTextClipboardV1 ||
                _remoteSupportsDestinationLeasedFilePasteV1)) {
          _attachClipboardChannel(channel);
        } else {
          unawaited(channel.close());
        }
      case 'file-transfer-control':
        if (localExplicitFileTransferSupported &&
            _remoteSupportsExplicitFileTransferV1) {
          _attachFileTransferControlChannel(channel);
        } else {
          unawaited(channel.close());
        }
      case 'file-transfer-data':
        if (localExplicitFileTransferSupported &&
            _remoteSupportsExplicitFileTransferV1) {
          _attachFileTransferDataChannel(channel);
        } else {
          unawaited(channel.close());
        }
      default:
        // Unknown channels must never replace the reliable control channel.
        unawaited(channel.close());
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
          unawaited(_publishColorDiagnostics());
        } else {
          refreshRemoteStatus();
          refreshRemoteDisplays();
          _sendControl({'type': 'refresh-quality', 'version': 2});
          refreshColorDiagnostics();
        }
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        unawaited(_releaseHostInputState());
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

  void _attachClipboardChannel(RTCDataChannel channel) {
    _clipboardChannel = channel;
    channel.onDataChannelState = (state) {
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _sendClipboard({
          'type': 'hello',
          'version': clipboardWireVersion,
          'mode': _clipboardMode.name,
          'supportsApplied': true,
          'supportsFileClipboard': false,
          'supportsDestinationLeasedFilePaste': fileClipboardSupported,
          'filePasteSessionId': _filePasteSessionId,
        });
      } else if (state == RTCDataChannelState.RTCDataChannelClosed) {
        _remoteClipboardMode = null;
        _remoteClipboardSupportsApplied = false;
        _clipboardApplyGate.reset();
        _filePasteCommitGate.reset();
        _clearRemoteFileClipboardOffer();
      }
      _updateClipboardStatus();
      notifyListeners();
    };
    channel.onMessage = (message) {
      if (message.isBinary || message.text.length > 16 * 1024) return;
      unawaited(_handleClipboardMessage(message.text));
    };
  }

  void _attachFileTransferControlChannel(RTCDataChannel channel) {
    _fileTransferControlChannel = channel;
    channel.onDataChannelState = (_) {
      _tryAttachExplicitFileTransferTransport();
      notifyListeners();
    };
    channel.onMessage = (message) {
      if (message.isBinary || message.text.length > 16 * 1024) return;
      _fileTransfer.handleControlMessage(message.text);
    };
    _tryAttachExplicitFileTransferTransport();
  }

  void _attachFileTransferDataChannel(RTCDataChannel channel) {
    _fileTransferDataChannel = channel;
    channel.bufferedAmountLowThreshold = 4 * 16 * 1024;
    channel.onDataChannelState = (_) {
      _tryAttachExplicitFileTransferTransport();
      notifyListeners();
    };
    channel.onMessage = (message) {
      if (!message.isBinary || message.binary.length > 16 * 1024) return;
      _fileTransfer.handleBinaryMessage(message.binary);
    };
    _tryAttachExplicitFileTransferTransport();
  }

  void _tryAttachExplicitFileTransferTransport() {
    final control = _fileTransferControlChannel;
    final data = _fileTransferDataChannel;
    final open =
        control?.state == RTCDataChannelState.RTCDataChannelOpen &&
        data?.state == RTCDataChannelState.RTCDataChannelOpen;
    if (!open) {
      if (_explicitFileTransferTransportAttached) {
        _explicitFileTransferTransportAttached = false;
        _fileTransfer.detachTransport();
      }
      return;
    }
    if (_explicitFileTransferTransportAttached) return;
    _explicitFileTransferTransportAttached = true;
    _fileTransfer.attachTransport(
      sendControl: (message) =>
          control!.send(RTCDataChannelMessage(jsonEncode(message))),
      sendBinary: (bytes) =>
          data!.send(RTCDataChannelMessage.fromBinary(bytes)),
      bufferedAmount: () => data!.getBufferedAmount(),
      pacingDelay: () => (_inputRoundTripMs ?? 0) > 60
          ? const Duration(milliseconds: 12)
          : Duration.zero,
    );
  }

  Future<void> _handleClipboardMessage(String payload) async {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != clipboardWireVersion) {
        return;
      }
      switch (decoded['type']) {
        case 'hello':
          final modeName = decoded['mode'];
          _remoteClipboardMode = ClipboardSyncMode.values.firstWhere(
            (mode) => mode.name == modeName,
            orElse: () => ClipboardSyncMode.disabled,
          );
          _remoteClipboardSupportsApplied = decoded['supportsApplied'] == true;
          final remoteFilePasteSessionId = decoded['filePasteSessionId'];
          if (remoteFilePasteSessionId is String &&
              RegExp(r'^[0-9a-f]{32}$').hasMatch(remoteFilePasteSessionId)) {
            _remoteFilePasteSessionId = remoteFilePasteSessionId;
          }
          _updateClipboardStatus();
          notifyListeners();
          final queuedOffer = _queuedClipboardOffer;
          _queuedClipboardOffer = null;
          if (queuedOffer != null && _remoteAllowsClipboardInbound) {
            _sendClipboard(queuedOffer.toMessage());
          }
          unawaited(_announceCurrentFileClipboardOffer());
        case 'offer':
          final request = _clipboardSync.acceptOffer(
            ClipboardOffer.fromMessage(decoded),
          );
          if (request != null) {
            _setClipboardStatus(ClipboardSyncStatus.receiving, '正在接收剪贴板文本');
            _sendClipboard(request);
          }
        case 'request':
          _setClipboardStatus(ClipboardSyncStatus.sending, '正在发送剪贴板文本');
          for (final chunk in _clipboardSync.chunksForRequest(decoded)) {
            await _sendClipboardMessage(chunk);
          }
          _updateClipboardStatus();
        case 'data':
          final completed = _clipboardSync.acceptData(decoded);
          if (completed == null) return;
          _clipboardSync.expectNativeEcho(completed.text);
          await _clipboardPlatform.writeText(completed.text);
          _sendClipboard(clipboardAppliedMessage(completed.offer));
          _setClipboardStatus(ClipboardSyncStatus.ready, '已接收远程剪贴板文本');
        case 'applied':
          if (_clipboardApplyGate.accept(decoded)) {
            _setClipboardStatus(ClipboardSyncStatus.ready, '远程剪贴板已写入');
          }
        case 'file-paste-committed':
          if (_filePasteCommitGate.accept(decoded)) {
            _setClipboardStatus(ClipboardSyncStatus.ready, '远程文件已提交到目标目录');
          }
        case 'file-paste-ready':
        case 'file-paste-rejected':
          _filePasteIntentGate.accept(decoded);
        case 'file-paste-prepare':
          await _handleFilePastePrepare(decoded);
        case 'file-paste-cancel':
          final leaseId = decoded['destinationLeaseId'];
          if (leaseId is String) {
            final transaction = FilePasteTransactionIdentity.fromMessage(
              decoded,
            );
            _filePasteDestinationLeases.revoke(
              leaseId,
              transaction: transaction,
            );
          }
        case 'file-offer':
          final offer = RemoteFileClipboardOffer.fromMessage(decoded);
          if (offer.sessionId != _activeFilePasteSessionId) {
            throw const FormatException('远端文件 Offer 不属于当前会话');
          }
          _remoteFileClipboardOffer = offer;
          try {
            await _filePasteTargetPlatform.setRemoteOfferAvailable(
              ownerId: _filePasteOwnerId,
              available: true,
            );
            _emitNotice(
              '远端已复制 ${offer.itemCount} 项文件；在本机 Finder/文件资源管理器按粘贴即可接收',
            );
          } catch (error) {
            _emitNotice(
              '无法监听本机文件粘贴快捷键：$error',
              level: RemoteNoticeLevel.warning,
            );
          }
        case 'file-offer-revoke':
          final sessionId = decoded['sessionId'];
          final offerId = decoded['offerId'];
          final generation = decoded['generation'];
          final currentOffer = _remoteFileClipboardOffer;
          if (sessionId is String &&
              offerId is String &&
              generation is num &&
              currentOffer?.sessionId == sessionId &&
              currentOffer?.id == offerId &&
              currentOffer?.generation == generation.toInt()) {
            _clearRemoteFileClipboardOffer();
          }
        case 'file-paste-request':
          await _handleRemoteFilePasteRequest(decoded);
      }
    } on FormatException catch (error) {
      _setClipboardStatus(
        ClipboardSyncStatus.error,
        '剪贴板数据校验失败：${error.message}',
      );
    } catch (error) {
      _setClipboardStatus(ClipboardSyncStatus.error, '剪贴板同步失败：$error');
    }
  }

  Future<void> _handleFilePastePrepare(Map<String, dynamic> message) async {
    final transaction = FilePasteTransactionIdentity.fromMessage(message);
    final remoteOffer = _remoteFileClipboardOffer;
    if (!_remoteSupportsDestinationLeasedFilePasteV1 ||
        !_filePasteTargetPlatform.supported ||
        transaction.sessionId != _filePasteSessionId ||
        remoteOffer == null ||
        remoteOffer.sessionId != transaction.sessionId ||
        remoteOffer.id != transaction.offerId ||
        remoteOffer.generation != transaction.generation) {
      _sendClipboard(
        filePasteRejectedMessage(
          transaction: transaction,
          reason: '文件 Offer 或会话已失效',
        ),
      );
      return;
    }
    try {
      final target = await _filePasteTargetPlatform.captureActiveTarget();
      if (!target.writable) {
        throw StateError('${target.application} 当前目录不可写');
      }
      final lease = _filePasteDestinationLeases.create(
        transaction: transaction,
        target: target,
      );
      _sendClipboard(
        filePasteReadyMessage(
          transaction: transaction,
          destinationLeaseId: lease.id,
        ),
      );
      _clearRemoteFileClipboardOffer();
      _setClipboardStatus(
        ClipboardSyncStatus.receiving,
        '已锁定 ${target.application} · ${target.displayName}',
      );
    } catch (error) {
      _sendClipboard(
        filePasteRejectedMessage(transaction: transaction, reason: '$error'),
      );
      _emitNotice('无法确定粘贴目标：$error', level: RemoteNoticeLevel.warning);
    }
  }

  Future<void> _handleRemoteFilePasteRequest(
    Map<String, dynamic> message,
  ) async {
    final transaction = FilePasteTransactionIdentity.fromMessage(message);
    final destinationLeaseId = message['destinationLeaseId'];
    final validLeaseId =
        destinationLeaseId is String &&
        RegExp(r'^[0-9a-f]{32}$').hasMatch(destinationLeaseId);
    final validOffer =
        transaction.sessionId == _activeFilePasteSessionId &&
        _fileClipboardOffers.currentOfferId == transaction.offerId &&
        _fileClipboardOffers.currentGeneration == transaction.generation;
    if (!validLeaseId || !validOffer) {
      _sendClipboard(
        filePasteRejectedMessage(
          transaction: transaction,
          reason: '文件 Offer 或会话已失效',
        ),
      );
      return;
    }
    final existingTransfer =
        _remotePasteTransferByIntent[transaction.pasteIntentId];
    if (existingTransfer != null) {
      if (existingTransfer.transaction != transaction ||
          existingTransfer.destinationLeaseId != destinationLeaseId) {
        _sendClipboard(
          filePasteRejectedMessage(
            transaction: transaction,
            reason: '粘贴事务已绑定到其他目标目录',
          ),
        );
        return;
      }
      _sendClipboard(
        filePasteReadyMessage(
          transaction: transaction,
          destinationLeaseId: destinationLeaseId,
        ),
      );
      return;
    }
    try {
      final snapshot = await _clipboardPlatform.readSnapshot();
      if (!snapshot.hasFiles ||
          _fileClipboardOffers.currentOfferId != transaction.offerId ||
          _fileClipboardOffers.currentGeneration != transaction.generation) {
        _sendClipboard(
          filePasteRejectedMessage(
            transaction: transaction,
            reason: '本机剪贴板已变化',
          ),
        );
        return;
      }
      final transferId = await _publishLocalFileClipboard(
        snapshot,
        destinationLeaseId: destinationLeaseId,
      );
      if (transferId == null) {
        _sendClipboard(
          filePasteRejectedMessage(transaction: transaction, reason: '文件传输未就绪'),
        );
        return;
      }
      final binding = (
        transferId: transferId,
        destinationLeaseId: destinationLeaseId,
        transaction: transaction,
      );
      final winner = _remotePasteTransferByIntent.putIfAbsent(
        transaction.pasteIntentId,
        () => binding,
      );
      if (winner != binding) {
        if (winner.transaction != transaction ||
            winner.destinationLeaseId != destinationLeaseId) {
          _sendClipboard(
            filePasteRejectedMessage(
              transaction: transaction,
              reason: '粘贴事务已绑定到其他目标目录',
            ),
          );
          return;
        }
        _sendClipboard(
          filePasteReadyMessage(
            transaction: transaction,
            destinationLeaseId: destinationLeaseId,
          ),
        );
        return;
      }
      _sendClipboard(
        filePasteReadyMessage(
          transaction: transaction,
          destinationLeaseId: destinationLeaseId,
        ),
      );
      _announcedLocalFileOffer = null;
      _fileClipboardPasteTransferId = transferId;
      notifyListeners();
      if (_trackedRemotePasteIntents.add(transaction.pasteIntentId)) {
        unawaited(
          _trackRemoteInitiatedFilePaste(
            transferId: transferId,
            transaction: transaction,
            destinationLeaseId: destinationLeaseId,
          ),
        );
      }
    } catch (error) {
      _sendClipboard(
        filePasteRejectedMessage(transaction: transaction, reason: '$error'),
      );
      _emitNotice('远端文件粘贴准备失败：$error', level: RemoteNoticeLevel.error);
    }
  }

  Future<void> _trackRemoteInitiatedFilePaste({
    required String transferId,
    required FilePasteTransactionIdentity transaction,
    required String destinationLeaseId,
  }) async {
    final committed = await _filePasteCommitGate.waitFor(
      transferId,
      transaction: transaction,
      destinationLeaseId: destinationLeaseId,
    );
    if (committed) {
      _fileClipboardOffers.releaseTransfer(transferId);
      _emitNotice('远端文件已保存到控制端锁定的活动目录', level: RemoteNoticeLevel.success);
    } else {
      await _fileClipboardOffers.invalidateTransfer(transferId);
      _emitNotice('远端文件未能提交到控制端目录', level: RemoteNoticeLevel.error);
    }
    if (_fileClipboardPasteTransferId == transferId) {
      _fileClipboardPasteTransferId = null;
    }
    _remotePasteTransferByIntent.remove(transaction.pasteIntentId);
    _trackedRemotePasteIntents.remove(transaction.pasteIntentId);
    _updateClipboardStatus();
    notifyListeners();
  }

  Future<void> _handleControlMessage(String payload) async {
    try {
      final message = jsonDecode(payload);
      if (message is! Map<String, dynamic> ||
          message['version'] != remoteDisplaySwitchWireVersion) {
        return;
      }
      if (role == RemoteRole.host) {
        await _handleHostControlMessage(message);
      } else {
        await _handleControllerControlMessage(message);
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

  Future<void> _handleHostControlMessage(Map<String, dynamic> message) {
    if (!_hostPlatform.capabilities.canHostDesktop) {
      return Future<void>.value();
    }
    if (_isReliableHostInputMessage(message)) {
      return _hostInputState.enqueue(() => _applyHostControlMessage(message));
    }
    return _applyHostControlMessage(message);
  }

  bool _isReliableHostInputMessage(Map<String, dynamic> message) {
    switch (message['type']) {
      case 'keyboard':
      case 'shortcut':
      case 'release-input':
      case 'input-reset':
        return true;
      case 'pointer':
        return message['phase'] != 'move';
      default:
        return false;
    }
  }

  Future<void> _applyHostControlMessage(Map<String, dynamic> message) async {
    switch (message['type']) {
      case 'pointer':
        final phase = message['phase'] as String? ?? 'move';
        final isMotion = phase == 'move';
        if (!_acceptInputSequence(message, motion: isMotion)) {
          return;
        }
        await _hostPlatform.sendPointer(
          HostPointerEvent(
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
            modifiers: message.containsKey('modifiers')
                ? (message['modifiers'] as List<dynamic>? ?? const [])
                      .whereType<String>()
                      .toList(growable: false)
                : null,
          ),
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
            await _hostPlatform.sendText(text);
          }
        } else {
          await _hostPlatform.sendKey(
            HostKeyEvent(
              phase: message['phase'] as String? ?? 'down',
              key: message['key'] as String? ?? '',
              modifiers: (message['modifiers'] as List<dynamic>? ?? const [])
                  .whereType<String>()
                  .toList(growable: false),
              physicalHidUsage: (message['physicalHidUsage'] as num?)?.toInt(),
              repeat: wireBool(message['repeat']),
            ),
          );
        }
        _acknowledgeInput(message);
      case 'shortcut':
        if (!_acceptInputSequence(message, motion: false)) {
          return;
        }
        final key = message['key'] as String? ?? '';
        if (!RemoteShortcutPolicy.commonWireKeys.contains(key)) {
          return;
        }
        await _hostPlatform.invokeShortcut(
          key: key,
          modifiers: (message['modifiers'] as List<dynamic>? ?? const [])
              .whereType<String>()
              .toList(growable: false),
        );
        _acknowledgeInput(message);
      case 'release-input':
        if (!_acceptInputSequence(message, motion: false)) {
          return;
        }
        await _hostPlatform.releaseAllInput();
        _acknowledgeInput(message);
      case 'input-reset':
        if (!_acceptInputSequence(message, motion: false)) {
          return;
        }
        switch (parseRemoteInputResetScope(message['scope'])) {
          case RemoteInputResetScope.keyboard:
            await _hostPlatform.releaseKeyboardState();
          case RemoteInputResetScope.pointer:
            await _hostPlatform.releasePointerButtons();
          case RemoteInputResetScope.all:
            await _hostPlatform.releaseAllInput();
          case null:
            return;
        }
        _acknowledgeInput(message);
      case 'select-display':
        await _switchHostDisplay(
          message['displayId'] as String? ?? '',
          generation: (message['generation'] as num?)?.toInt() ?? 0,
        );
      case 'display-switch-committed':
        await _commitHostDisplaySwitch(
          displayId: message['displayId'] as String? ?? '',
          generation: (message['generation'] as num?)?.toInt() ?? 0,
        );
      case 'display-switch-rejected':
        await _rollbackHostDisplaySwitch(
          generation: (message['generation'] as num?)?.toInt() ?? 0,
          message: message['message'] as String? ?? '控制端未能渲染目标显示器',
          notifyController: true,
        );
      case 'refresh-host-status':
        final permission = await _hostPlatform.checkPermissions();
        _applyHostPermissionState(permission);
        _publishHostState();
        notifyListeners();
      case 'refresh-displays':
        await _refreshHostDisplays();
      case 'repair-session':
        await _repairHostSession(message);
      case 'set-quality':
        if (_hostDisplaySwitchInProgress) {
          _sendControl({
            'type': 'quality-error',
            'version': 2,
            'message': '显示器切换期间暂不调整清晰度',
          });
          return;
        }
        await _applyVideoQuality(
          RemoteQualityProfile.fromWireValue(message['profile'] as String?),
        );
      case 'set-video-policy':
        if (_hostDisplaySwitchInProgress) {
          _sendControl({
            'type': 'quality-error',
            'version': 2,
            'message': '显示器切换期间暂不调整视频策略',
          });
          return;
        }
        final rawPolicy = message['policy'];
        if (rawPolicy is! Map) {
          _sendControl({
            'type': 'quality-error',
            'version': 2,
            'message': '视频策略格式无效',
          });
          return;
        }
        await _applyVideoPolicy(
          RemoteVideoPolicy.fromMessage(rawPolicy.cast<String, dynamic>()),
        );
      case 'refresh-quality':
        _publishQualityState();
      case 'refresh-color-diagnostics':
        await _publishColorDiagnostics();
      case 'show-grayscale-test':
        if (_hostPlatform.capabilities.colorDiagnostics) {
          await _hostPlatform.showGrayscaleTestPattern();
        }
      case 'open-display-settings':
        if (_hostPlatform.capabilities.colorDiagnostics) {
          await _hostPlatform.openDisplaySettings();
        }
    }
  }

  bool _acceptInputSequence(
    Map<String, dynamic> message, {
    required bool motion,
  }) {
    final sequence = (message['sequence'] as num?)?.toInt() ?? 0;
    return _inputSequenceGuard.accept(sequence, motion: motion);
  }

  Future<void> _handleControllerControlMessage(
    Map<String, dynamic> message,
  ) async {
    switch (message['type']) {
      case 'host-status':
        final previousInputAccess = _accessibilityGranted;
        _remoteDeviceId = message['deviceId'] as String?;
        _kernel.updatePeer(_remoteDeviceId);
        _remoteHostPlatform = message['hostPlatform'] as String?;
        _remoteSupportsPhysicalKeyboard = wireBool(
          message['supportsPhysicalKeyboard'],
        );
        _screenCaptureGranted = wireBool(message['screenCaptureGranted']);
        _accessibilityGranted = wireBool(message['accessibilityGranted']);
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
        if (!_displaySwitchPending || selected == _selectedDisplayId) {
          _selectedDisplayId =
              _displays.any((display) => display.id == selected)
              ? selected
              : _displays.firstOrNull?.id;
          _renderedDisplayId ??= _selectedDisplayId;
        }
        notifyListeners();
      case 'display-switching':
        final generation = (message['generation'] as num?)?.toInt() ?? 0;
        final displayId = message['displayId'] as String? ?? '';
        if (_displaySwitch.markPreparing(
          displayId: displayId,
          generation: generation,
        )) {
          _outboundVideoFrameSize = null;
          _inboundVideoFrameSize = null;
          _videoGeometryState = RemoteVideoGeometryState.adapting;
          int? baselineFrames;
          try {
            final baseline = await _readRtcVideoProgress('inbound-rtp');
            baselineFrames = baseline?.frames;
          } catch (_) {
            baselineFrames = null;
          }
          _displaySwitch.updateInboundFramesBaseline(
            generation: generation,
            frames: baselineFrames,
          );
          notifyListeners();
        }
      case 'display-selected':
        await _confirmRemoteDisplaySelection(message);
      case 'display-switch-error':
        final generation = (message['generation'] as num?)?.toInt() ?? 0;
        if (generation == 0 || generation >= _displaySwitchGeneration) {
          _displaySwitchRequestTimer?.cancel();
          _displaySwitch.fail(
            generation: generation == 0 ? _displaySwitchGeneration : generation,
            code: message['code'] as String?,
          );
          _videoGeometryState = RemoteVideoGeometryState.stable;
          notifyListeners();
          final stage = message['stage'] as String?;
          final stageLabel = switch (stage) {
            'captureConfigured' => '配置采集画面',
            'sourceFramesStable' => '等待采集画面',
            'encoderGeometryReady' => '初始化编码器',
            'targetKeyFrameEncoded' => '校准编码尺寸',
            'encoderMediaReady' => '等待编码画面',
            'targetKeyFrameDecoded' => '等待目标关键帧',
            'decoderMediaReady' => '等待接收画面',
            'rendererGeometryStable' => '校准显示尺寸',
            _ => null,
          };
          _emitNotice(
            stageLabel == null
                ? message['message'] as String? ?? '远程显示器切换失败'
                : '$stageLabel失败：${message['message'] as String? ?? '请重试'}',
            level: RemoteNoticeLevel.error,
          );
          _flushQueuedQualityRequest();
        }
      case 'quality-state':
        final rawPolicy = message['videoPolicy'];
        if (rawPolicy is Map) {
          _selectedVideoPolicy = RemoteVideoPolicy.fromMessage(
            rawPolicy.cast<String, dynamic>(),
          );
          _selectedQuality = _selectedVideoPolicy.legacyProfile;
        } else {
          _selectedQuality = RemoteQualityProfile.fromWireValue(
            message['profile'] as String?,
          );
          _selectedVideoPolicy = RemoteVideoPolicy.fromLegacy(_selectedQuality);
        }
        if (_selectedQuality == RemoteQualityProfile.automatic) {
          _qualityAdaptation.adopt(
            RemoteAdaptiveVideoTier.fromWireValue(
              message['adaptiveTier'] as String?,
            ),
          );
        }
        _actualVideoWidth = (message['width'] as num?)?.toInt();
        _actualVideoHeight = (message['height'] as num?)?.toInt();
        final expected = RemoteVideoFrameSize(
          width: _actualVideoWidth ?? 0,
          height: _actualVideoHeight ?? 0,
        );
        _expectedVideoFrameSize = expected.isValid ? expected : null;
        final outbound = RemoteVideoFrameSize(
          width: (message['outboundWidth'] as num?)?.toInt() ?? 0,
          height: (message['outboundHeight'] as num?)?.toInt() ?? 0,
        );
        if (outbound.isValid) _outboundVideoFrameSize = outbound;
        final reportedGeometryState = RemoteVideoGeometryState.fromWireValue(
          message['geometryState'] as String?,
        );
        final reportedFrameGeometry = remoteFrameGeometryFromValue(
          message['frameGeometry'],
        );
        if (!_displaySwitchPending) {
          _videoGeometryState = reportedGeometryState;
          _frameGeometry.offer(
            reportedFrameGeometry,
            displayId: _renderedDisplayId ?? _selectedDisplayId,
            minimumGeneration: _displaySwitchGeneration,
          );
        }
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
      case 'color-diagnostics':
        final value = message['diagnostics'];
        if (value is Map<String, dynamic>) {
          _colorDiagnostics = RemoteColorDiagnostics.fromMessage(value);
          notifyListeners();
        }
      case 'color-diagnostics-error':
        _emitNotice(
          message['message'] as String? ?? '读取被控设备色彩诊断失败',
          level: RemoteNoticeLevel.warning,
        );
      case 'repair-session-ack':
        final requestId = message['requestId'] as String?;
        final completion = _sessionRepairCompleter;
        if (requestId == _sessionRepairRequestId &&
            completion != null &&
            !completion.isCompleted) {
          completion.complete(message);
        }
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

  Future<void> _confirmRemoteDisplaySelection(
    Map<String, dynamic> message,
  ) async {
    final displayId = message['displayId'] as String?;
    final generation = (message['generation'] as num?)?.toInt() ?? 0;
    if (displayId == null ||
        !_displays.any((display) => display.id == displayId)) {
      _rejectRemoteDisplaySelection(
        displayId: displayId ?? '',
        generation: generation,
        code: 'INVALID_DISPLAY',
        stage: 'captureConfigured',
        message: '目标显示器已经不可用',
      );
      return;
    }
    if (!_displaySwitch.isCurrent(
          displayId: displayId,
          generation: generation,
        ) &&
        !_displaySwitch.markPreparing(
          displayId: displayId,
          generation: generation,
        )) {
      _rejectRemoteDisplaySelection(
        displayId: displayId,
        generation: generation,
        code: 'STALE_SWITCH_GENERATION',
        stage: 'decoderMediaReady',
        message: '目标显示器切换事务已经过期',
      );
      return;
    }

    var announcedGeometry = remoteFrameGeometryFromValue(
      message['frameGeometry'],
    );
    if (announcedGeometry != null &&
        !announcedGeometry.belongsTo(
          displayId: displayId,
          generation: generation,
        )) {
      // Geometry can be delayed or reordered independently from reliable
      // control messages. Discard stale layout metadata without rejecting a
      // healthy target video stream.
      announcedGeometry = null;
    }
    final expected =
        announcedGeometry?.encodedSize ??
        RemoteVideoFrameSize.fromMessage(message);
    _expectedVideoFrameSize = expected.isValid ? expected : null;
    final outbound = RemoteVideoFrameSize(
      width: (message['outboundWidth'] as num?)?.toInt() ?? 0,
      height: (message['outboundHeight'] as num?)?.toInt() ?? 0,
    );
    if (outbound.isValid) _outboundVideoFrameSize = outbound;
    notifyListeners();

    final inboundProgress = await _waitForInboundVideoProgress(
      afterFrames: _displaySwitchInboundFramesBaseline,
    );
    if (!_displaySwitch.isCurrent(
      displayId: displayId,
      generation: generation,
    )) {
      return;
    }

    if (inboundProgress == null) {
      _displaySwitch.fail(
        generation: generation,
        code: 'DECODER_FRAME_TIMEOUT',
      );
      notifyListeners();
      _rejectRemoteDisplaySelection(
        displayId: displayId,
        generation: generation,
        code: 'DECODER_FRAME_TIMEOUT',
        stage: 'decoderMediaReady',
        message: '未收到目标显示器的新视频帧',
      );
      _emitNotice('目标画面尚未到达，正在恢复原画面', level: RemoteNoticeLevel.warning);
      return;
    }

    _displaySwitch.markMediaReady(displayId: displayId, generation: generation);
    _displaySwitchRequestTimer?.cancel();

    _selectedDisplayId = displayId;
    _renderedDisplayId = displayId;
    final rendererGeometry = _currentRendererFrameSize();
    final observedGeometry = inboundProgress.size.isValid
        ? inboundProgress.size
        : rendererGeometry?.isValid == true
        ? rendererGeometry!
        : expected;
    _inboundVideoFrameSize = observedGeometry;
    final presentationGeometry =
        announcedGeometry ??
        _buildFrameGeometry(
          display: _displayForId(displayId),
          generation: generation,
          encodedSize: observedGeometry,
        );
    _frameGeometry.offer(
      presentationGeometry,
      displayId: displayId,
      minimumGeneration: generation,
    );
    final senderMismatch = message['geometryMismatch'] == true;
    _videoGeometryState =
        senderMismatch ||
            !_videoGeometryApproximatelyMatches(_inboundVideoFrameSize)
        ? RemoteVideoGeometryState.adapting
        : RemoteVideoGeometryState.stable;
    _displaySwitch.commit(displayId: displayId, generation: generation);
    notifyListeners();
    _sendControl(
      remoteDisplaySwitchMessage(
        type: 'display-switch-committed',
        displayId: displayId,
        generation: generation,
      ),
    );
    if (_videoGeometryState == RemoteVideoGeometryState.adapting) {
      _emitNotice('已切换远程显示器，画质正在后台适配', level: RemoteNoticeLevel.success);
      _observeVideoGeometry(statType: 'inbound-rtp', generation: generation);
    } else {
      _emitNotice('已切换远程显示器', level: RemoteNoticeLevel.success);
    }
    _flushQueuedQualityRequest();
  }

  void _rejectRemoteDisplaySelection({
    required String displayId,
    required int generation,
    required String code,
    required String stage,
    required String message,
  }) {
    _sendControl(
      remoteDisplaySwitchMessage(
        type: 'display-switch-rejected',
        displayId: displayId,
        generation: generation,
        payload: {'code': code, 'stage': stage, 'message': message},
      ),
    );
  }

  Future<void> _repairHostSession(Map<String, dynamic> message) async {
    final requestId = message['requestId'] as String? ?? '';
    if (_hostDisplaySwitchInProgress) {
      _sendControl({
        'type': 'repair-session-ack',
        'version': 2,
        'requestId': requestId,
        'ok': false,
        'message': '显示器切换期间不能修复当前画面',
      });
      return;
    }
    try {
      await _releaseHostInputState();
      final permission = await _hostPlatform.checkPermissions();
      _applyHostPermissionState(permission);
      await _refreshHostDisplays();
      var keyFrameRequested = false;
      var captureRestarted = false;
      try {
        keyFrameRequested = await desktopCapturer.requestKeyFrame();
      } catch (_) {
        // Some platform capturers cannot explicitly request a key frame. The
        // state refresh and controller texture rebind still remain useful.
      }
      if (_hostPlatform.type == HostPlatformType.windows &&
          !keyFrameRequested) {
        captureRestarted = await _warmRestartWindowsHostCapture();
        if (!captureRestarted) {
          throw StateError('Windows 当前采集轨道未能恢复');
        }
      }
      _publishHostState();
      _publishQualityState();
      _publishDisplayList();
      _sendControl({
        'type': 'repair-session-ack',
        'version': 2,
        'requestId': requestId,
        'ok': true,
        'keyFrameRequested': keyFrameRequested,
        'captureRestarted': captureRestarted,
      });
      notifyListeners();
    } catch (error) {
      _sendControl({
        'type': 'repair-session-ack',
        'version': 2,
        'requestId': requestId,
        'ok': false,
        'message': error.toString(),
      });
    }
  }

  void _handleHostWindowLifecycleEvent(DesktopWindowLifecycleEvent event) {
    _windowsCaptureRecoveryTimer?.cancel();
    if (!_canRecoverWindowsHostCapture) return;
    unawaited(_armWindowsCaptureRecovery(event));
  }

  Future<void> _armWindowsCaptureRecovery(
    DesktopWindowLifecycleEvent event,
  ) async {
    _RtcVideoProgress? baseline;
    try {
      baseline = await _readRtcVideoProgress('outbound-rtp');
    } catch (_) {
      // Missing counters are handled conservatively by the delayed probe.
    }
    if (!_canRecoverWindowsHostCapture) return;
    _windowsCaptureRecoveryTimer = Timer(
      const Duration(milliseconds: 650),
      () => unawaited(_recoverWindowsCaptureIfStalled(baseline, event)),
    );
  }

  bool get _canRecoverWindowsHostCapture =>
      role == RemoteRole.host &&
      _hostPlatform.type == HostPlatformType.windows &&
      !_closing &&
      !_hostDisplaySwitchInProgress &&
      !_windowsCaptureRecoveryInProgress &&
      _connectionEstablished &&
      _localStream != null &&
      _videoSender != null;

  Future<void> _recoverWindowsCaptureIfStalled(
    _RtcVideoProgress? baseline,
    DesktopWindowLifecycleEvent event,
  ) async {
    if (!_canRecoverWindowsHostCapture) return;
    try {
      final current = await _readRtcVideoProgress('outbound-rtp');
      if (_videoFramesAdvanced(current, afterFrames: baseline?.frames)) return;
      final recovered = await _warmRestartWindowsHostCapture();
      if (!recovered) {
        _emitNotice(
          'Windows 窗口状态变化后画面未恢复，可使用“刷新当前画面”重试（${event.name}）',
          level: RemoteNoticeLevel.warning,
        );
      }
    } catch (_) {
      // Automatic recovery is best-effort and must never end the session.
    }
  }

  Future<bool> _warmRestartWindowsHostCapture() async {
    if (!_canRecoverWindowsHostCapture) return false;
    final source = _sourceForId(_selectedDisplayId);
    final previousStream = _localStream;
    final sender = _videoSender;
    final previousTrack = previousStream?.getVideoTracks().firstOrNull;
    if (source == null ||
        previousStream == null ||
        sender == null ||
        previousTrack == null) {
      return false;
    }

    _windowsCaptureRecoveryInProgress = true;
    final recoveryGeneration = ++_windowsCaptureRecoveryGeneration;
    MediaStream? replacementStream;
    var replacementAttached = false;
    try {
      _RtcVideoProgress? baseline;
      try {
        baseline = await _readRtcVideoProgress('outbound-rtp');
      } catch (_) {
        // replaceTrack remains the authoritative recovery operation.
      }
      replacementStream = await _captureDisplay(source);
      final replacementTrack = replacementStream.getVideoTracks().firstOrNull;
      if (replacementTrack == null) {
        throw StateError('Windows 恢复采集未返回视频轨道');
      }
      // Allow Desktop Duplication to acquire its first surface before the
      // existing sender is switched. The previous capture stays attached.
      await Future<void>.delayed(const Duration(milliseconds: 120));
      if (_closing || recoveryGeneration != _windowsCaptureRecoveryGeneration) {
        throw StateError('Windows 采集恢复已取消');
      }
      await sender.replaceTrack(replacementTrack);
      replacementAttached = true;
      _localStream = replacementStream;
      await _applyVideoPolicy(
        _selectedVideoPolicy,
        reportFailure: false,
        publishState: false,
      );
      final progress = await _waitForOutboundVideoProgress(
        afterFrames: baseline?.frames,
        allowCounterReset: true,
      );
      if (_closing || recoveryGeneration != _windowsCaptureRecoveryGeneration) {
        throw StateError('Windows 采集恢复已取消');
      }
      if (progress == null) {
        throw StateError('Windows 新采集轨道未输出视频帧');
      }
      _outboundVideoFrameSize = progress.size.isValid
          ? progress.size
          : _outboundVideoFrameSize;
      await _disposeMediaStream(previousStream);
      replacementStream = null;
      _publishQualityState();
      notifyListeners();
      return true;
    } catch (_) {
      if (replacementAttached &&
          !_closing &&
          recoveryGeneration == _windowsCaptureRecoveryGeneration) {
        try {
          await sender.replaceTrack(previousTrack);
          _localStream = previousStream;
          await _applyVideoPolicy(
            _selectedVideoPolicy,
            reportFailure: false,
            publishState: false,
          );
        } catch (_) {
          // The original session remains the safest available rollback.
        }
      }
      return false;
    } finally {
      if (replacementStream != null) {
        await _disposeMediaStream(replacementStream);
      }
      if (recoveryGeneration == _windowsCaptureRecoveryGeneration) {
        _windowsCaptureRecoveryInProgress = false;
      }
    }
  }

  Future<_RtcVideoProgress?> _waitForInboundVideoProgress({
    required int? afterFrames,
    int attempts = 30,
  }) async {
    _RtcVideoProgress? latest;
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      _RtcVideoProgress? progress;
      try {
        progress = await _readRtcVideoProgress('inbound-rtp');
        latest = progress ?? latest;
      } catch (_) {
        // Receiver stats are sampled again until the media-flow timeout.
      }
      if (latest?.size.isValid == true) {
        _inboundVideoFrameSize = latest!.size;
      }
      if (RemoteDisplaySwitchCoordinator.mediaAdvanced(
        baselineFrames: afterFrames,
        currentFrames: progress?.frames,
        hasValidFrame: progress?.size.isValid == true,
      )) {
        notifyListeners();
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    notifyListeners();
    return null;
  }

  RemoteVideoFrameSize? _currentRendererFrameSize() {
    final value = remoteRenderer.value;
    final width = value.width.round();
    final height = value.height.round();
    if (width <= 0 || height <= 0) return null;
    return RemoteVideoFrameSize(width: width, height: height);
  }

  void _sendControl(Map<String, dynamic> message) {
    _sendOnChannel(_controlChannel, message, reportFailure: true);
  }

  void _sendClipboard(Map<String, dynamic> message) {
    unawaited(_sendClipboardMessage(message));
  }

  Future<void> _sendClipboardMessage(Map<String, dynamic> message) async {
    final channel = _clipboardChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return;
    }
    try {
      await channel.send(RTCDataChannelMessage(jsonEncode(message)));
    } catch (error) {
      _setClipboardStatus(ClipboardSyncStatus.error, '剪贴板通道发送失败：$error');
    }
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
      'deviceId': _localDeviceId,
      'hostPlatform': _hostPlatform.type.name,
      'supportsUnicodeText': true,
      'supportsPhysicalKeyboard':
          _hostPlatform.type == HostPlatformType.windows,
      'screenCaptureGranted': _screenCaptureGranted,
      'accessibilityGranted': _accessibilityGranted == true,
      'inputReady': _accessibilityGranted == true,
    });
  }

  Future<void> _publishColorDiagnostics() async {
    if (role != RemoteRole.host ||
        !_hostPlatform.capabilities.colorDiagnostics) {
      return;
    }
    try {
      final diagnostics = await _hostPlatform.getColorDiagnostics();
      _sendControl({
        'type': 'color-diagnostics',
        'version': 2,
        'diagnostics': diagnostics,
      });
    } catch (error) {
      _sendControl({
        'type': 'color-diagnostics-error',
        'version': 2,
        'message': '读取 Mac 色彩诊断失败：$error',
      });
    }
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

  Future<void> _applyVideoQuality(
    RemoteQualityProfile profile, {
    bool reportFailure = true,
    bool publishState = true,
    RemoteDisplay? display,
  }) => _applyVideoPolicy(
    RemoteVideoPolicy.fromLegacy(profile),
    reportFailure: reportFailure,
    publishState: publishState,
    display: display,
  );

  Future<void> _applyVideoPolicy(
    RemoteVideoPolicy policy, {
    bool reportFailure = true,
    bool publishState = true,
    RemoteDisplay? display,
  }) async {
    try {
      final sender = _videoSender;
      if (sender == null) {
        throw StateError('视频发送器尚未就绪');
      }
      if (policy.fullyAutomatic && !_selectedVideoPolicy.fullyAutomatic) {
        _qualityAdaptation.reset();
      }
      final target = RemoteVideoTarget.forPolicy(
        policy,
        automaticTier: _qualityAdaptation.tier,
      );
      final qualityDisplay = display ?? selectedDisplay;
      final parameters = sender.parameters;
      parameters.degradationPreference = switch (policy.preference) {
        RemoteVideoPreference.balanced => RTCDegradationPreference.BALANCED,
        RemoteVideoPreference.smoothness =>
          RTCDegradationPreference.MAINTAIN_FRAMERATE,
        RemoteVideoPreference.clarity =>
          RTCDegradationPreference.MAINTAIN_RESOLUTION,
      };
      final encodings = parameters.encodings;
      if (encodings == null || encodings.isEmpty) {
        throw StateError('当前视频编码器不支持动态画质切换');
      }
      final senderScale = _senderScaleForCurrentCapture(target, qualityDisplay);
      for (final encoding in encodings) {
        encoding
          ..maxBitrate = target.maxBitrate
          ..maxFramerate = target.maxFramerate
          ..scaleResolutionDownBy = senderScale;
      }
      final applied = await sender.setParameters(parameters);
      if (!applied) {
        throw StateError('视频编码器拒绝了新的画质参数');
      }
      _selectedVideoPolicy = policy;
      _selectedQuality = policy.legacyProfile;
      _updateExpectedVideoSize(
        _effectiveScaleForCurrentCapture(target, qualityDisplay),
        display: qualityDisplay,
      );
      if (publishState) _publishQualityState();
      notifyListeners();
    } catch (error) {
      if (!reportFailure) rethrow;
      _sendControl({
        'type': 'quality-error',
        'version': 2,
        'message': '画质切换失败：$error',
      });
      _emitNotice('画质切换失败：$error', level: RemoteNoticeLevel.error);
    }
  }

  double _senderScaleForCurrentCapture(
    RemoteVideoTarget target,
    RemoteDisplay? display,
  ) {
    if (display == null) return 1;
    final sourceLongEdge = math.max(
      display.captureWidth,
      display.captureHeight,
    );
    if (sourceLongEdge <= 0) return 1;
    final configuredLongEdge = _captureTargetSourceId == display.id
        ? _captureTargetLongEdge
        : null;
    final capturedLongEdge = math.min(
      sourceLongEdge,
      configuredLongEdge ?? sourceLongEdge,
    );
    final outputLongEdge = math.min(
      capturedLongEdge,
      target.targetLongEdge ?? sourceLongEdge,
    );
    if (outputLongEdge <= 0) return 1;
    return math.max(1, capturedLongEdge / outputLongEdge).toDouble();
  }

  double _effectiveScaleForCurrentCapture(
    RemoteVideoTarget target,
    RemoteDisplay? display,
  ) {
    if (display == null) return 1;
    final sourceLongEdge = math.max(
      display.captureWidth,
      display.captureHeight,
    );
    if (sourceLongEdge <= 0) return 1;
    final configuredLongEdge = _captureTargetSourceId == display.id
        ? _captureTargetLongEdge
        : null;
    final outputLongEdge = math.min(
      math.min(sourceLongEdge, configuredLongEdge ?? sourceLongEdge),
      target.targetLongEdge ?? sourceLongEdge,
    );
    if (outputLongEdge <= 0) return 1;
    return math.max(1, sourceLongEdge / outputLongEdge).toDouble();
  }

  void _updateExpectedVideoSize(double scale, {RemoteDisplay? display}) {
    display ??= selectedDisplay;
    if (display == null ||
        display.captureWidth <= 0 ||
        display.captureHeight <= 0) {
      _actualVideoWidth = null;
      _actualVideoHeight = null;
      _expectedVideoFrameSize = null;
      return;
    }
    _actualVideoWidth = math.max(1, (display.captureWidth / scale).round());
    _actualVideoHeight = math.max(1, (display.captureHeight / scale).round());
    _expectedVideoFrameSize = RemoteVideoFrameSize(
      width: _actualVideoWidth!,
      height: _actualVideoHeight!,
    );
  }

  RemoteVideoFrameSize _sessionCaptureSizeFor(RemoteDisplay display) {
    final sourceWidth = display.captureWidth;
    final sourceHeight = display.captureHeight;
    if (sourceWidth <= 0 || sourceHeight <= 0) {
      return const RemoteVideoFrameSize(width: 0, height: 0);
    }
    final sourceLongEdge = math.max(sourceWidth, sourceHeight);
    final scale = sourceLongEdge > _sessionCaptureLongEdge
        ? _sessionCaptureLongEdge / sourceLongEdge
        : 1.0;
    int evenDimension(double value) {
      final rounded = math.max(2, value.round());
      return rounded - rounded.remainder(2);
    }

    return RemoteVideoFrameSize(
      width: evenDimension(sourceWidth * scale),
      height: evenDimension(sourceHeight * scale),
    );
  }

  RemoteFrameGeometry? _buildFrameGeometry({
    required RemoteDisplay? display,
    required int generation,
    RemoteVideoFrameSize? captureSize,
    RemoteVideoFrameSize? encodedSize,
    int? captureGeneration,
  }) {
    if (display == null) return null;
    final capture = captureSize?.isValid == true
        ? captureSize!
        : _sessionCaptureSizeFor(display);
    final encoded = encodedSize?.isValid == true
        ? encodedSize!
        : _expectedVideoFrameSize;
    if (!capture.isValid || encoded?.isValid != true) return null;
    var activeX = 0.0;
    var activeY = 0.0;
    var activeWidth = encoded!.width.toDouble();
    var activeHeight = encoded.height.toDouble();
    final nativeGeometry = _lastHostCaptureFrameState;
    if (nativeGeometry != null &&
        nativeGeometry.sourceId == display.id &&
        (captureGeneration == null ||
            captureGeneration <= 0 ||
            nativeGeometry.captureGeneration == captureGeneration) &&
        nativeGeometry.hasValidActiveContent) {
      final scaleX = encoded.width / nativeGeometry.width;
      final scaleY = encoded.height / nativeGeometry.height;
      activeX = (nativeGeometry.activeContentX * scaleX).clamp(
        0,
        encoded.width.toDouble(),
      );
      activeY = (nativeGeometry.activeContentY * scaleY).clamp(
        0,
        encoded.height.toDouble(),
      );
      activeWidth = (nativeGeometry.activeContentWidth * scaleX).clamp(
        0,
        encoded.width - activeX,
      );
      activeHeight = (nativeGeometry.activeContentHeight * scaleY).clamp(
        0,
        encoded.height - activeY,
      );
    }
    return RemoteFrameGeometry(
      displayId: display.id,
      generation: generation,
      logicalWidth: display.width,
      logicalHeight: display.height,
      captureWidth: capture.width,
      captureHeight: capture.height,
      encodedWidth: encoded.width,
      encodedHeight: encoded.height,
      activeContentX: activeX,
      activeContentY: activeY,
      activeContentWidth: activeWidth,
      activeContentHeight: activeHeight,
    );
  }

  void _publishQualityState() {
    final target = activeVideoTarget;
    final geometry = _buildFrameGeometry(
      display: selectedDisplay,
      generation: _displaySwitchGeneration,
      encodedSize: _outboundVideoFrameSize ?? _expectedVideoFrameSize,
    );
    _frameGeometry.offer(
      geometry,
      displayId: _selectedDisplayId,
      minimumGeneration: _displaySwitchGeneration,
    );
    _sendControl({
      'type': 'quality-state',
      'version': 2,
      'profile': _selectedQuality.name,
      'videoPolicy': _selectedVideoPolicy.toMessage(),
      'width': _actualVideoWidth,
      'height': _actualVideoHeight,
      'outboundWidth': _outboundVideoFrameSize?.width,
      'outboundHeight': _outboundVideoFrameSize?.height,
      'geometryState': _videoGeometryState.name,
      'adaptiveTier': _qualityAdaptation.tier.name,
      'maxBitrate': target.maxBitrate,
      'maxFramerate': target.maxFramerate,
      if (_remoteActiveContentGeometryVersion > 0)
        'activeContentGeometryVersion': _remoteActiveContentGeometryVersion,
      if (geometry != null) 'frameGeometry': geometry.toMessage(),
    });
  }

  Future<RemoteVideoFrameSize?> _readRtcVideoFrameSize(String statType) async {
    final progress = await _readRtcVideoProgress(statType);
    return progress?.size.isValid == true ? progress!.size : null;
  }

  Future<_RtcVideoProgress?> _readRtcVideoProgress(String statType) async {
    final reports = statType == 'outbound-rtp'
        ? await _videoSender?.getStats()
        : await _videoReceiver?.getStats();
    if (reports == null) return null;
    final size = RemoteVideoFrameSize.fromRtcStats(
      reports.map(
        (report) => <dynamic, dynamic>{...report.values, 'type': report.type},
      ),
      statType: statType,
    );
    int? frames;
    int? keyFrames;
    final framesKey = statType == 'outbound-rtp'
        ? 'framesEncoded'
        : 'framesDecoded';
    final keyFramesKey = statType == 'outbound-rtp'
        ? 'keyFramesEncoded'
        : 'keyFramesDecoded';
    for (final report in reports) {
      if (report.type != statType) continue;
      final mediaType = report.values['kind'] ?? report.values['mediaType'];
      if (mediaType != null && mediaType != 'video') continue;
      final candidate = (report.values[framesKey] as num?)?.toInt();
      if (candidate != null && (frames == null || candidate > frames)) {
        frames = candidate;
      }
      final keyFrameCandidate = (report.values[keyFramesKey] as num?)?.toInt();
      if (keyFrameCandidate != null &&
          (keyFrames == null || keyFrameCandidate > keyFrames)) {
        keyFrames = keyFrameCandidate;
      }
    }
    if (size == null && frames == null && keyFrames == null) return null;
    return _RtcVideoProgress(
      size: size ?? const RemoteVideoFrameSize(width: 0, height: 0),
      frames: frames,
      keyFrames: keyFrames,
    );
  }

  Future<_RtcVideoProgress?> _waitForRtcVideoProgressStats(
    String statType, {
    int attempts = 20,
  }) async {
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      try {
        final progress = await _readRtcVideoProgress(statType);
        if (progress?.frames != null || progress?.size.isValid == true) {
          return progress;
        }
      } catch (_) {
        // WebRTC stats may not expose the active RTP report immediately after
        // a track starts or changes format. Wait for the report, not a fixed
        // post-switch delay.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  Future<RemoteVideoFrameSize?> _waitForOutboundVideoFrameSize(
    RemoteVideoFrameSize? expected,
  ) async {
    RemoteVideoFrameSize? latest;
    for (var attempt = 0; attempt < 12; attempt += 1) {
      try {
        latest = await _readRtcVideoFrameSize('outbound-rtp') ?? latest;
      } catch (_) {
        // Stats are diagnostic. Failure must not tear down a working session.
      }
      if (latest != null &&
          (expected == null || latest.approximatelyMatches(expected))) {
        break;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (latest != null) {
      _outboundVideoFrameSize = latest;
      notifyListeners();
    }
    return latest;
  }

  Future<void> _reportInputFailure(Object error) async {
    final permission = await _hostPlatform.checkPermissions();
    _applyHostPermissionState(permission);
    _controlError = _accessibilityGranted == true
        ? '本机输入注入失败'
        : permission.limitation ?? '本机尚未允许远程鼠标和键盘输入';
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
        _localNetworkAddress = message['clientAddress'] as String?;
        if (role == RemoteRole.host) {
          final capabilities =
              (message['capabilities'] as List<dynamic>? ?? const [])
                  .whereType<String>()
                  .toSet();
          _supportsInvitationRotation = capabilities.contains(
            'invitation-rotation',
          );
          _supportsServerInvitationPush = capabilities.contains(
            'server-invitation-push',
          );
          _applyHostInvitationSnapshot(message, fallbackGeneration: 1);
        }
        _setState(RemoteSessionState.waitingForPeer, '已进入房间，等待另一台设备');
      case 'invitation-rotated':
        _applyHostInvitationSnapshot(
          message,
          fallbackGeneration: _hostInvitationGeneration + 1,
        );
        _invitationRotationCompleter?.complete();
        _invitationRotationCompleter = null;
        notifyListeners();
        _emitNotice('连接码已刷新', level: RemoteNoticeLevel.success);
      case 'invitation-updated':
        if (role != RemoteRole.host) return;
        final applied = _applyHostInvitationSnapshot(message);
        if (applied) {
          notifyListeners();
          _emitNotice('连接码已自动更新');
        }
      case 'invitation-rotation-error':
        _hostInvitationState = _hostInvitationCode == null
            ? HostInvitationState.unavailable
            : HostInvitationState.active;
        final error = StateError('连接码当前无法刷新');
        _invitationRotationCompleter?.completeError(error);
        _invitationRotationCompleter = null;
        _emitNotice(error.message, level: RemoteNoticeLevel.error);
      case 'invitation-consumed':
        _hostInvitationExpiresAt = null;
        _hostInvitationState = HostInvitationState.consumed;
        notifyListeners();
      case 'peer-joined':
        _remoteDeviceId = message['peerDeviceId'] as String?;
        _remoteNetworkAddress = message['peerAddress'] as String?;
        _kernel.updatePeer(_remoteDeviceId);
        _hostInvitationExpiresAt = null;
        if (role == RemoteRole.host) {
          _hostInvitationState = HostInvitationState.consumed;
        }
        final peerCapabilities =
            (message['peerCapabilities'] as List<dynamic>? ?? const [])
                .whereType<String>()
                .toSet();
        if (kDebugMode) {
          debugPrint(
            'CrossDesktopRemote peer capabilities: '
            '${peerCapabilities.toList()..sort()}',
          );
        }
        _remoteSupportsTextClipboardV1 = peerCapabilities.contains(
          'text-clipboard-v1',
        );
        _remoteSupportsExplicitFileTransferV1 = peerCapabilities.contains(
          explicitFileTransferV1Capability,
        );
        _remoteSupportsDestinationLeasedFilePasteV1 = peerCapabilities.contains(
          destinationLeasedFilePasteV1Capability,
        );
        _remoteSupportsAtomicShortcutV1 = peerCapabilities.contains(
          atomicShortcutV1Capability,
        );
        _remoteSupportsScopedInputResetV1 = peerCapabilities.contains(
          scopedInputResetV1Capability,
        );
        _remoteSupportsVideoPolicyV2 = peerCapabilities.contains(
          videoPolicyV2Capability,
        );
        _remoteSupportsMultiDisplayStreamV1 = peerCapabilities.contains(
          multiDisplayStreamV1Capability,
        );
        if (role == RemoteRole.host) {
          _remoteActiveContentGeometryVersion = activeContentGeometryVersion(
            peerCapabilities,
          );
          _remoteSupportsActiveContentGeometry =
              _remoteActiveContentGeometryVersion > 0;
          await _ensureClipboardDataChannel();
          await _ensureExplicitFileTransferDataChannels();
          await _authorizePeer();
        } else {
          _setState(RemoteSessionState.connecting, '连接码已验证，正在建立视频连接');
        }
        _updateClipboardStatus();
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

  bool _applyHostInvitationSnapshot(
    Map<String, dynamic> message, {
    int? fallbackGeneration,
  }) {
    final generation =
        (message['invitationGeneration'] as num?)?.toInt() ??
        fallbackGeneration;
    if (generation == null || generation < _hostInvitationGeneration) {
      return false;
    }
    final room = message['room'] as String?;
    final leaseId = message['invitationLeaseId'] as String?;
    if (room == null || room.isEmpty || leaseId == null || leaseId.isEmpty) {
      return false;
    }
    _hostInvitationCode = room;
    _hostInvitationLeaseId = leaseId;
    _hostInvitationGeneration = generation;
    _hostInvitationState = HostInvitationState.active;
    final rawRemaining = message['invitationExpiresInMillis'];
    final rawExpiry = message['invitationExpiresAtUnixMillis'];
    _hostInvitationExpiresAt = rawRemaining is num
        ? DateTime.now().add(
            Duration(milliseconds: rawRemaining.toInt().clamp(0, 300000)),
          )
        : rawExpiry is num
        ? DateTime.fromMillisecondsSinceEpoch(rawExpiry.toInt())
        : null;
    return true;
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
    _signaling.send({
      'type': 'answer',
      'sdp': answer.sdp,
      if (message['negotiationId'] case final String negotiationId)
        'negotiationId': negotiationId,
    });
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
    if (!_hostPlatform.capabilities.canHostDesktop) {
      throw UnsupportedError('当前版本尚未实现此平台的被控能力');
    }
    var permission = await _hostPlatform.checkPermissions();
    if (!permission.screenCaptureGranted) {
      permission = await _hostPlatform.requestScreenCapturePermission();
    }
    _applyHostPermissionState(permission);
    if (!permission.screenCaptureGranted) {
      if (_hostPlatform.capabilities.capturePermissionSettings) {
        await _hostPlatform.openScreenCapturePermissionSettings();
      }
      throw StateError(
        permission.screenCaptureLimitation ?? '没有屏幕录制权限，请在系统设置中授权',
      );
    }
    final limitation = permission.limitation;
    if (_accessibilityGranted == true && limitation != null) {
      _emitNotice(limitation, level: RemoteNoticeLevel.warning);
    }
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
    await _applyVideoPolicy(_selectedVideoPolicy);
    unawaited(_refreshOutboundVideoDiagnostics());
    _subscribeToDisplayChanges();
    _publishHostState();
    _publishDisplayList();
    unawaited(_publishColorDiagnostics());
    notifyListeners();
  }

  Future<void> _refreshOutboundVideoDiagnostics() async {
    if (_hostPlatform.capabilities.captureFrameReadiness) {
      try {
        _lastHostCaptureFrameState = await _hostPlatform.getCaptureFrameState();
      } catch (_) {
        // Frame geometry is optional on legacy host adapters.
      }
    }
    await _waitForOutboundVideoFrameSize(_expectedVideoFrameSize);
    _publishQualityState();
  }

  Future<MediaStream> _captureDisplay(DesktopCapturerSource source) async {
    final stream = await navigator.mediaDevices.getDisplayMedia({
      'audio': false,
      'video': {
        'deviceId': {'exact': source.id},
        'mandatory': {
          'frameRate': _sessionCaptureFrameRate.toDouble(),
          'targetLongEdge': _sessionCaptureLongEdge,
          if (_remoteSupportsActiveContentGeometry)
            'preserveVisibleContentGeometry': true,
        },
      },
    });
    _captureTargetLongEdge = _sessionCaptureLongEdge;
    _captureTargetSourceId = source.id;
    return stream;
  }

  Future<_CaptureFrameWaitResult> _waitForCaptureFirstFrame({
    required String sourceId,
    required int afterSequence,
    int attempts = 30,
  }) async {
    if (!_hostPlatform.capabilities.captureFrameReadiness) {
      return const _CaptureFrameWaitResult(ready: true);
    }
    HostCaptureFrameState? lastState;
    for (var attempt = 0; attempt < attempts; attempt += 1) {
      try {
        final state = await _hostPlatform.getCaptureFrameState();
        if (state == null) continue;
        lastState = state;
        if (state.isReadyAfter(
          sequence: afterSequence,
          targetSourceId: sourceId,
        )) {
          _lastHostCaptureFrameState = state;
          return _CaptureFrameWaitResult(ready: true, lastState: state);
        }
      } catch (_) {
        // A missing native readiness signal must not be mistaken for success.
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return _CaptureFrameWaitResult(ready: false, lastState: lastState);
  }

  Future<_RtcVideoProgress?> _waitForOutboundVideoProgress({
    int? afterFrames,
    bool allowCounterReset = false,
  }) async {
    _RtcVideoProgress? latest;
    for (var attempt = 0; attempt < 24; attempt += 1) {
      try {
        latest = await _readRtcVideoProgress('outbound-rtp') ?? latest;
      } catch (_) {
        // Sender statistics are sampled again until the media-flow timeout.
      }
      if (_videoFramesAdvanced(latest, afterFrames: afterFrames)) {
        return latest;
      }
      if (allowCounterReset &&
          afterFrames != null &&
          latest?.frames != null &&
          latest!.frames! > 0 &&
          latest.frames! < afterFrames) {
        // Some WebRTC builds restart the sender counter when replaceTrack()
        // installs a new capture source while preserving the same Sender.
        return latest;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  bool _videoFramesAdvanced(
    _RtcVideoProgress? progress, {
    required int? afterFrames,
  }) {
    final frames = progress?.frames;
    if (frames != null) {
      return afterFrames == null ? frames > 0 : frames > afterFrames;
    }
    // Some platform WebRTC builds omit frame counters. A valid RTP geometry is
    // a best-effort fallback only when no baseline counter was available.
    return afterFrames == null && progress?.size.isValid == true;
  }

  Future<_RtcVideoProgress?> _requestAndWaitForOutboundFrame(
    _RtcVideoProgress? baseline,
  ) async {
    try {
      // A key frame reduces decoder convergence time, but several WebRTC
      // builds cannot report or force it reliably. Treat it as best effort and
      // use actual RTP frame progress as the transaction acknowledgement.
      await desktopCapturer.requestKeyFrame();
    } catch (_) {
      // A working media stream must not be rejected for this optimization.
    }
    return _waitForOutboundVideoProgress(afterFrames: baseline?.frames);
  }

  bool _videoGeometryApproximatelyMatches(RemoteVideoFrameSize? actual) {
    final expected = _expectedVideoFrameSize;
    return expected == null ||
        (actual?.isValid == true && actual!.approximatelyMatches(expected));
  }

  void _observeVideoGeometry({
    required String statType,
    required int generation,
  }) {
    final token = ++_geometryObservationToken;
    unawaited(
      _runVideoGeometryObservation(
        statType: statType,
        generation: generation,
        token: token,
      ),
    );
  }

  Future<void> _runVideoGeometryObservation({
    required String statType,
    required int generation,
    required int token,
  }) async {
    var stableSamples = 0;
    for (var attempt = 0; attempt < 24; attempt += 1) {
      if (_closing ||
          token != _geometryObservationToken ||
          generation != _displaySwitchGeneration) {
        return;
      }
      try {
        final progress = await _readRtcVideoProgress(statType);
        if (progress?.size.isValid == true) {
          if (statType == 'outbound-rtp') {
            _outboundVideoFrameSize = progress!.size;
          } else {
            _inboundVideoFrameSize = progress!.size;
          }
          if (_videoGeometryApproximatelyMatches(progress.size)) {
            stableSamples += 1;
          } else {
            stableSamples = 0;
          }
        }
      } catch (_) {
        // Geometry is diagnostic and must never tear down working media.
      }
      if (stableSamples >= 2) {
        _videoGeometryState = RemoteVideoGeometryState.stable;
        if (role == RemoteRole.host) _publishQualityState();
        notifyListeners();
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (_closing || token != _geometryObservationToken) return;
    _videoGeometryState = RemoteVideoGeometryState.constrained;
    if (role == RemoteRole.host) _publishQualityState();
    notifyListeners();
  }

  Future<void> _loadDisplaySources() async {
    final availableSources = await desktopCapturer.getSources(
      types: [SourceType.Screen],
      thumbnailSize: ThumbnailSize(160, 100),
    );
    final nativeDisplays = await _hostPlatform.listDisplays();
    final nativeById = {
      for (final display in nativeDisplays) display.id: display,
    };
    // The Windows flutter_webrtc source id and Win32 display device id come
    // from different APIs and cannot yet be joined reliably. Keep the first
    // Windows host milestone deliberately single-screen; this preserves a
    // correct capture/input mapping instead of exposing unsafe display
    // switching. Multi-display will be enabled with the replaceTrack
    // transaction once a stable source-to-monitor identity is available.
    final sources =
        _hostPlatform.type == HostPlatformType.windows &&
            availableSources.isNotEmpty
        ? <DesktopCapturerSource>[availableSources.first]
        : availableSources;
    final singleNativeFallback =
        sources.length == 1 && nativeDisplays.isNotEmpty
        ? nativeDisplays.where((display) => display.isPrimary).firstOrNull ??
              nativeDisplays.first
        : null;
    _displaySources = sources;
    _displays = sources
        .map((source) {
          final native = nativeById[source.id] ?? singleNativeFallback;
          return RemoteDisplay(
            id: source.id,
            name: native?.name ?? source.name,
            width: native?.width ?? 0,
            height: native?.height ?? 0,
            pixelWidth: native?.pixelWidth ?? 0,
            pixelHeight: native?.pixelHeight ?? 0,
            pointPixelScale: native?.pointPixelScale ?? 1,
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

  RemoteDisplay? _displayForId(String? displayId) {
    for (final display in _displays) {
      if (display.id == displayId) return display;
    }
    return null;
  }

  Future<void> _switchHostDisplay(
    String displayId, {
    int generation = 0,
  }) async {
    if (role != RemoteRole.host) return;
    if (_hostDisplaySwitchInProgress) {
      _sendDisplaySwitchError(
        generation: generation,
        code: 'DISPLAY_SWITCH_BUSY',
        message: '被控设备正在切换显示器，请稍后重试',
      );
      return;
    }
    if (!_displaySwitch.acceptRequest(
      displayId: displayId,
      generation: generation,
    )) {
      _sendDisplaySwitchError(
        generation: generation,
        code: 'STALE_SWITCH_GENERATION',
        message: '显示器切换请求已经过期',
      );
      return;
    }
    if (displayId == _selectedDisplayId) {
      _displaySwitch.markMediaReady(
        displayId: displayId,
        generation: generation,
      );
      _displaySwitch.commit(displayId: displayId, generation: generation);
      await _publishDisplaySelected(displayId, generation: generation);
      return;
    }
    final source = _sourceForId(displayId);
    final targetDisplay = _displayForId(displayId);
    if (source == null || targetDisplay == null) {
      _displaySwitch.fail(generation: generation, code: 'DISPLAY_UNAVAILABLE');
      _sendDisplaySwitchError(generation: generation, message: '选择的显示器已不可用');
      return;
    }

    _hostDisplaySwitchInProgress = true;
    await _releaseHostInputState();
    _mediaStatsAccumulator.reset();
    _geometryObservationToken += 1;
    _videoGeometryState = RemoteVideoGeometryState.adapting;
    _sendControl(
      remoteDisplaySwitchMessage(
        type: 'display-switching',
        displayId: displayId,
        generation: generation,
      ),
    );
    notifyListeners();

    final previousStream = _localStream;
    final previousDisplayId = _selectedDisplayId;
    final previousDisplay = _displayForId(previousDisplayId);
    final previousTrack = previousStream?.getVideoTracks().firstOrNull;
    MediaStream? replacementStream;
    var replacementAttached = false;
    var switchedInPlace = false;
    DesktopCaptureConfiguration? captureConfiguration;
    try {
      try {
        await _waitForCaptureMutationsToSettle();
      } on TimeoutException {
        throw const _DisplaySwitchFailure(
          code: 'CAPTURE_TRANSACTION_BUSY',
          stage: 'targetStreamWarmup',
          message: '上一项采集配置尚未完成，请稍后重试',
        );
      }
      if (previousStream == null || previousTrack == null) {
        throw StateError('当前显示器视频轨道不可用');
      }
      final previousTrackId = previousTrack.id;
      if (previousTrackId == null || previousTrackId.isEmpty) {
        throw StateError('当前显示器视频轨道缺少标识');
      }
      final captureBaseline = await _hostPlatform.getCaptureFrameState();
      _RtcVideoProgress? outboundBaseline;
      final sender = _videoSender;
      if (sender == null || _peerConnection == null) {
        throw StateError('WebRTC 视频发送器尚未建立');
      }

      try {
        captureConfiguration = await desktopCapturer.switchSource(
          trackId: previousTrackId,
          sourceId: displayId,
          frameRate: _sessionCaptureFrameRate,
          targetLongEdge: _sessionCaptureLongEdge,
        );
        switchedInPlace = captureConfiguration.applied;
        if (switchedInPlace) {
          _captureTargetLongEdge = _sessionCaptureLongEdge;
          _captureTargetSourceId = displayId;
        }
      } catch (error) {
        if (_hostPlatform.type == HostPlatformType.macOS) {
          throw _DisplaySwitchFailure(
            code: 'CAPTURE_PREPARE_FAILED',
            stage: 'targetStreamWarmup',
            message: '目标显示器采集流预热失败：$error',
          );
        }
        _emitNotice(
          '当前平台不支持采集流热切换，正在使用兼容切换：$error',
          level: RemoteNoticeLevel.warning,
        );
      }

      if (!switchedInPlace) {
        replacementStream = await _captureDisplay(source);
        final replacementTrack = replacementStream.getVideoTracks().firstOrNull;
        if (replacementTrack == null) {
          throw StateError('新显示器未返回视频轨道');
        }
        final captureWait = await _waitForCaptureFirstFrame(
          sourceId: displayId,
          afterSequence: captureBaseline?.sequence ?? 0,
        );
        if (!captureWait.ready) {
          throw _DisplaySwitchFailure(
            code: 'CAPTURE_FRAME_TIMEOUT',
            stage: 'sourceFramesStable',
            message: '目标显示器未产生有效采集帧${captureWait.diagnosticSuffix}',
          );
        }
        outboundBaseline = await _waitForRtcVideoProgressStats('outbound-rtp');
        // Keep the negotiated transceiver, MID, SSRC and data channels stable.
        // This compatibility path replaces only the track and never rebuilds
        // the PeerConnection or renegotiates SDP.
        await sender.replaceTrack(replacementTrack);
        replacementAttached = true;
      } else {
        // A separately constructed target SCStream has produced its first
        // usable target-sized pixel buffer. The previous stream remains warm
        // until the controller acknowledges new inbound media.
        outboundBaseline = await _waitForRtcVideoProgressStats('outbound-rtp');
        final captureWait = await _waitForCaptureFirstFrame(
          sourceId: displayId,
          afterSequence: captureBaseline?.sequence ?? 0,
          attempts: 12,
        );
        if (!captureWait.ready) {
          throw _DisplaySwitchFailure(
            code: 'CAPTURE_FRAME_TIMEOUT',
            stage: 'sourceFramesStable',
            message: '目标显示器未产生有效采集帧${captureWait.diagnosticSuffix}',
          );
        }
      }
      _outboundVideoFrameSize = null;

      try {
        await _applyVideoPolicy(
          _selectedVideoPolicy,
          reportFailure: false,
          publishState: false,
          display: targetDisplay,
        );
      } catch (error) {
        _updateExpectedVideoSize(
          activeVideoTarget.scaleFor(targetDisplay),
          display: targetDisplay,
        );
        _emitNotice(
          '目标显示器画质参数将在编码器稳定后恢复：$error',
          level: RemoteNoticeLevel.warning,
        );
      }

      final configuredGeometry = captureConfiguration?.hasValidGeometry == true
          ? RemoteVideoFrameSize(
              width: captureConfiguration!.width,
              height: captureConfiguration.height,
            )
          : null;
      final targetGeometry = _expectedVideoFrameSize ?? configuredGeometry;
      if (targetGeometry == null || !targetGeometry.isValid) {
        throw const _DisplaySwitchFailure(
          code: 'CAPTURE_GEOMETRY_UNAVAILABLE',
          stage: 'captureConfigured',
          message: '目标显示器没有返回有效的采集尺寸',
        );
      }
      final outboundReady = await _requestAndWaitForOutboundFrame(
        outboundBaseline,
      );
      if (outboundReady == null) {
        throw const _DisplaySwitchFailure(
          code: 'ENCODER_FRAME_TIMEOUT',
          stage: 'encoderMediaReady',
          message: '编码器未输出目标显示器的新视频帧',
        );
      }
      _outboundVideoFrameSize = outboundReady.size.isValid
          ? outboundReady.size
          : targetGeometry;
      _videoGeometryState =
          _videoGeometryApproximatelyMatches(_outboundVideoFrameSize)
          ? RemoteVideoGeometryState.stable
          : RemoteVideoGeometryState.adapting;
      _selectedDisplayId = displayId;
      _localStream = switchedInPlace ? previousStream : replacementStream;
      if (!_displaySwitch.markMediaReady(
        displayId: displayId,
        generation: generation,
      )) {
        throw const _DisplaySwitchFailure(
          code: 'STALE_SWITCH_GENERATION',
          stage: 'encoderMediaReady',
          message: '显示器切换事务已被更新的请求取代',
        );
      }
      final transaction = _HostDisplaySwitchTransaction(
        generation: generation,
        previousDisplayId: previousDisplayId,
        targetDisplayId: displayId,
        previousStream: previousStream,
        targetStream: _localStream!,
        switchedInPlace: switchedInPlace,
        trackId: switchedInPlace ? previousTrackId : null,
        captureGeneration: switchedInPlace
            ? captureConfiguration?.captureGeneration ?? 0
            : 0,
      );
      _hostDisplaySwitchTransaction = transaction;
      if (!switchedInPlace) replacementStream = null;
      _publishQualityState();
      await _publishDisplaySelected(
        displayId,
        generation: generation,
        captureConfiguration: captureConfiguration,
      );
      _publishDisplayList();
      transaction.timeout = Timer(const Duration(seconds: 8), () {
        unawaited(
          _rollbackHostDisplaySwitch(
            generation: generation,
            message: '控制端未确认目标显示器画面',
            notifyController: true,
          ),
        );
      });
      unawaited(
        Future<void>.delayed(
          const Duration(milliseconds: 300),
          _publishColorDiagnostics,
        ),
      );
      if (_videoGeometryState == RemoteVideoGeometryState.adapting) {
        _observeVideoGeometry(statType: 'outbound-rtp', generation: generation);
      }
    } catch (error) {
      _selectedDisplayId = previousDisplayId;
      _localStream = previousStream;
      _videoGeometryState = RemoteVideoGeometryState.stable;
      Object? rollbackError;
      if (switchedInPlace &&
          previousTrack != null &&
          previousDisplayId != null &&
          captureConfiguration != null) {
        try {
          final rollbackBaseline = await _hostPlatform.getCaptureFrameState();
          try {
            // Arm VideoToolbox before the cached old frame is re-injected so
            // a completely static desktop can still recover with a key frame.
            await desktopCapturer.requestKeyFrame();
          } catch (_) {
            // The cached frame still restores capture progress on forks that
            // do not expose an explicit key-frame request.
          }
          final restored = await desktopCapturer.rollbackSourceSwitch(
            trackId: previousTrack.id!,
            captureGeneration: captureConfiguration.captureGeneration,
          );
          if (!restored.applied) {
            throw StateError('原显示器采集配置未恢复');
          }
          _captureTargetSourceId = previousDisplayId;
          _captureTargetLongEdge = _sessionCaptureLongEdge;
          final rollbackWait = await _waitForCaptureFirstFrame(
            sourceId: previousDisplayId,
            afterSequence: rollbackBaseline?.sequence ?? 0,
          );
          if (!rollbackWait.ready) {
            throw StateError('原显示器未恢复有效采集帧');
          }
          if (previousDisplay != null) {
            await _applyVideoPolicy(
              _selectedVideoPolicy,
              reportFailure: false,
              publishState: false,
              display: previousDisplay,
            );
          }
        } catch (restoreError) {
          rollbackError = restoreError;
        }
      } else if (replacementAttached && previousTrack != null) {
        try {
          await _videoSender?.replaceTrack(previousTrack);
          if (previousDisplay != null) {
            await _applyVideoPolicy(
              _selectedVideoPolicy,
              reportFailure: false,
              publishState: false,
              display: previousDisplay,
            );
          }
        } catch (restoreError) {
          rollbackError = restoreError;
        }
      }
      if (rollbackError == null) {
        try {
          await desktopCapturer.requestKeyFrame();
        } catch (_) {
          // Rollback remains usable on platforms without the fork extension.
        }
        _publishQualityState();
        _publishDisplayList();
      }
      final failure = error is _DisplaySwitchFailure ? error : null;
      _displaySwitch.fail(
        generation: generation,
        code: failure?.code ?? 'DISPLAY_SWITCH_FAILED',
      );
      _sendDisplaySwitchError(
        generation: generation,
        code: failure?.code ?? 'DISPLAY_SWITCH_FAILED',
        stage: failure?.stage ?? 'unknown',
        message: rollbackError == null
            ? '切换显示器失败：$error'
            : '切换显示器失败：$error；恢复原显示器失败：$rollbackError',
      );
    } finally {
      try {
        for (final track
            in replacementStream?.getTracks() ?? <MediaStreamTrack>[]) {
          track.stop();
        }
        await replacementStream?.dispose();
      } catch (_) {
        // A failed replacement capture is detached from the sender already.
      }
      if (_hostDisplaySwitchTransaction == null) {
        _completeDisplaySwitchCoordination();
      }
      notifyListeners();
    }
  }

  Future<void> _commitHostDisplaySwitch({
    required String displayId,
    required int generation,
  }) async {
    final transaction = _hostDisplaySwitchTransaction;
    if (transaction == null ||
        transaction.generation != generation ||
        transaction.targetDisplayId != displayId) {
      return;
    }
    transaction.timeout?.cancel();
    try {
      if (transaction.switchedInPlace) {
        final trackId = transaction.trackId;
        if (trackId == null || transaction.captureGeneration <= 0) {
          throw StateError('采集流提交信息不完整');
        }
        final committed = await desktopCapturer.commitSourceSwitch(
          trackId: trackId,
          captureGeneration: transaction.captureGeneration,
        );
        if (!committed) throw StateError('采集流提交被拒绝');
      } else {
        await _disposeMediaStream(transaction.previousStream);
      }
    } catch (error) {
      _emitNotice(
        '目标显示器已生效，但旧采集流释放失败：$error',
        level: RemoteNoticeLevel.warning,
      );
    } finally {
      _hostDisplaySwitchTransaction = null;
      _displaySwitch.commit(displayId: displayId, generation: generation);
      _completeDisplaySwitchCoordination();
      notifyListeners();
    }
  }

  Future<void> _rollbackHostDisplaySwitch({
    required int generation,
    required String message,
    required bool notifyController,
  }) async {
    final transaction = _hostDisplaySwitchTransaction;
    if (transaction == null || transaction.generation != generation) return;
    transaction.timeout?.cancel();
    _hostDisplaySwitchTransaction = null;
    try {
      final activeTrack = transaction.targetStream.getVideoTracks().firstOrNull;
      if (activeTrack == null) {
        throw StateError('当前显示器视频轨道已经不可用');
      }
      if (transaction.switchedInPlace) {
        final previousDisplayId = transaction.previousDisplayId;
        if (previousDisplayId == null) {
          throw StateError('原显示器标识已经不可用');
        }
        final captureBaseline = await _hostPlatform.getCaptureFrameState();
        try {
          await desktopCapturer.requestKeyFrame();
        } catch (_) {
          // Rollback can continue on platforms without this fork extension.
        }
        final activeTrackId = transaction.trackId ?? activeTrack.id;
        if (activeTrackId == null ||
            activeTrackId.isEmpty ||
            transaction.captureGeneration <= 0) {
          throw StateError('当前显示器视频轨道缺少标识');
        }
        final restored = await desktopCapturer.rollbackSourceSwitch(
          trackId: activeTrackId,
          captureGeneration: transaction.captureGeneration,
        );
        if (!restored.applied) {
          throw StateError('原显示器采集配置未恢复');
        }
        _captureTargetSourceId = previousDisplayId;
        _captureTargetLongEdge = _sessionCaptureLongEdge;
        final rollbackWait = await _waitForCaptureFirstFrame(
          sourceId: previousDisplayId,
          afterSequence: captureBaseline?.sequence ?? 0,
        );
        if (!rollbackWait.ready) {
          throw StateError('原显示器未恢复有效采集帧');
        }
      } else {
        final previousTrack = transaction.previousStream
            .getVideoTracks()
            .firstOrNull;
        if (previousTrack == null) {
          throw StateError('原显示器视频轨道已经不可用');
        }
        await _videoSender?.replaceTrack(previousTrack);
      }
      try {
        await desktopCapturer.requestKeyFrame();
      } catch (_) {
        // The restored stream still advances on unsupported platforms.
      }
      _selectedDisplayId = transaction.previousDisplayId;
      _localStream = transaction.switchedInPlace
          ? transaction.targetStream
          : transaction.previousStream;
      final previousDisplay = _displayForId(transaction.previousDisplayId);
      if (previousDisplay != null) {
        await _applyVideoPolicy(
          _selectedVideoPolicy,
          reportFailure: false,
          publishState: false,
          display: previousDisplay,
        );
      }
      _outboundVideoFrameSize = await _waitForOutboundVideoFrameSize(
        _expectedVideoFrameSize,
      );
      _videoGeometryState =
          _videoGeometryApproximatelyMatches(_outboundVideoFrameSize)
          ? RemoteVideoGeometryState.stable
          : RemoteVideoGeometryState.constrained;
      _publishQualityState();
      _publishDisplayList();
    } catch (error) {
      message = '$message；恢复原显示器失败：$error';
    } finally {
      if (!transaction.switchedInPlace) {
        await _disposeMediaStream(transaction.targetStream);
      }
      _displaySwitch.fail(
        generation: generation,
        code: 'DISPLAY_SWITCH_ROLLED_BACK',
      );
      _completeDisplaySwitchCoordination();
      notifyListeners();
    }
    if (notifyController) {
      _sendDisplaySwitchError(generation: generation, message: message);
    }
  }

  Future<void> _disposeMediaStream(MediaStream stream) async {
    try {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    } catch (_) {
      // Media cleanup is best-effort and must not change transaction state.
    }
  }

  Future<void> _publishDisplaySelected(
    String displayId, {
    required int generation,
    DesktopCaptureConfiguration? captureConfiguration,
  }) async {
    final expected = _expectedVideoFrameSize;
    RemoteVideoFrameSize? outbound = _outboundVideoFrameSize;
    _RtcVideoProgress? progress;
    try {
      progress = await _readRtcVideoProgress('outbound-rtp');
      outbound ??= progress?.size.isValid == true ? progress!.size : null;
    } catch (_) {
      // Sender stats are diagnostic and must not fail a working switch.
    }
    if (outbound != null) _outboundVideoFrameSize = outbound;
    final captureSize = captureConfiguration?.hasValidGeometry == true
        ? RemoteVideoFrameSize(
            width: captureConfiguration!.width,
            height: captureConfiguration.height,
          )
        : null;
    final geometry = _buildFrameGeometry(
      display: _displayForId(displayId),
      generation: generation,
      captureSize: captureSize,
      encodedSize: outbound ?? expected,
      captureGeneration: captureConfiguration?.captureGeneration,
    );
    _frameGeometry.offer(
      geometry,
      displayId: displayId,
      minimumGeneration: generation,
    );
    _sendControl(
      remoteDisplaySwitchMessage(
        type: 'display-selected',
        displayId: displayId,
        generation: generation,
        payload: {
          if (_remoteActiveContentGeometryVersion > 0)
            'activeContentGeometryVersion': _remoteActiveContentGeometryVersion,
          if (captureConfiguration != null) ...{
            'captureGeneration': captureConfiguration.captureGeneration,
            'captureWidth': captureConfiguration.width,
            'captureHeight': captureConfiguration.height,
            'captureFrameRate': captureConfiguration.frameRate,
          },
          if (expected != null) ...expected.toMessage(),
          if (outbound != null) ...{
            'outboundWidth': outbound.width,
            'outboundHeight': outbound.height,
          },
          if (progress?.keyFrames != null)
            'keyFramesEncoded': progress!.keyFrames,
          if (geometry != null) 'frameGeometry': geometry.toMessage(),
          'geometryMismatch': expected != null && outbound != null
              ? !outbound.approximatelyMatches(expected)
              : false,
          'geometryState': _videoGeometryState.name,
        },
      ),
    );
  }

  void _sendDisplaySwitchError({
    required int generation,
    required String message,
    String code = 'DISPLAY_SWITCH_FAILED',
    String stage = 'unknown',
  }) {
    _sendControl(
      remoteDisplaySwitchMessage(
        type: 'display-switch-error',
        generation: generation,
        payload: {'code': code, 'stage': stage, 'message': message},
      ),
    );
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
    final rotation = _invitationRotationCompleter;
    _invitationRotationCompleter = null;
    if (rotation != null && !rotation.isCompleted) {
      rotation.completeError(StateError('信令连接已断开'));
    }
    final repair = _sessionRepairCompleter;
    _sessionRepairCompleter = null;
    _sessionRepairRequestId = null;
    if (repair != null && !repair.isCompleted) {
      repair.completeError(StateError('信令连接已断开'));
    }
    if (!_closing) {
      final reasonParts = reason?.split(':') ?? const <String>[];
      final reasonCode = reasonParts.firstOrNull;
      final retryAfterSeconds = reasonParts.length > 1
          ? int.tryParse(reasonParts[1])
          : null;
      final retryLabel = retryAfterSeconds == null
          ? '稍后再试'
          : '$retryAfterSeconds 秒后重试';
      final message = switch (reasonCode) {
        'INVALID_ROOM' => '连接码不存在、尚未启用或已经过期',
        'CODE_CONSUMED' => '连接码已经使用，请让被控设备重新生成',
        'RATE_LIMITED_INVITATION' => '当前连接码尝试过多，请更换连接码或$retryLabel',
        'RATE_LIMITED_SOURCE' => '当前设备尝试连接过于频繁，请$retryLabel',
        'RATE_LIMITED' => '连接码尝试过多，请稍后再试',
        'ROLE_OCCUPIED' => '该设备角色已经连接',
        'Invalid room or role' when role == RemoteRole.host =>
          '信令服务版本过旧，请更新并重启 Java 控制平面',
        _ => '信令连接已断开',
      };
      _setState(RemoteSessionState.disconnected, message);
      _emitNotice(message, level: RemoteNoticeLevel.warning);
    }
  }

  Future<void> _closeSession({required bool notifyPeer}) async {
    _closing = true;
    _cancelConnectionRecovery();
    _revokeAnnouncedLocalFileClipboardOffer();
    _clearRemoteFileClipboardOffer();
    if (notifyPeer && _signaling.isConnected) {
      try {
        _signaling.send({'type': 'hangup'});
      } catch (_) {
        // The socket may close between the state check and the send.
      }
    }
    await _signaling.close();
    await _releaseHostInputState();
    await _controlChannel?.close();
    _controlChannel = null;
    await _motionChannel?.close();
    _motionChannel = null;
    await _clipboardChannel?.close();
    _clipboardChannel = null;
    await _fileClipboardOffers.invalidate();
    _retiredFileClipboardTransfers.addAll(
      await _fileTransfer.retireClipboardTasks(),
    );
    _fileTransfer.detachTransport();
    _explicitFileTransferTransportAttached = false;
    await _fileTransferControlChannel?.close();
    _fileTransferControlChannel = null;
    await _fileTransferDataChannel?.close();
    _fileTransferDataChannel = null;
    _displayRefreshTimer?.cancel();
    _displayRefreshTimer = null;
    _inputPermissionPollTimer?.cancel();
    _inputPermissionPollTimer = null;
    _qualityRequestTimer?.cancel();
    _qualityRequestTimer = null;
    _displaySwitchRequestTimer?.cancel();
    _displaySwitchRequestTimer = null;
    _mediaStatsTimer?.cancel();
    _mediaStatsTimer = null;
    _windowsCaptureRecoveryTimer?.cancel();
    _windowsCaptureRecoveryTimer = null;
    _windowsCaptureRecoveryGeneration += 1;
    await _displayAddedSubscription?.cancel();
    _displayAddedSubscription = null;
    await _displayRemovedSubscription?.cancel();
    _displayRemovedSubscription = null;
    final displayTransaction = _hostDisplaySwitchTransaction;
    displayTransaction?.timeout?.cancel();
    _hostDisplaySwitchTransaction = null;
    if (displayTransaction != null &&
        !identical(displayTransaction.previousStream, _localStream)) {
      await _disposeMediaStream(displayTransaction.previousStream);
    }
    for (final track in _localStream?.getTracks() ?? <MediaStreamTrack>[]) {
      track.stop();
    }
    await _localStream?.dispose();
    _localStream = null;
    _videoSender = null;
    _videoReceiver = null;
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
    _renderedDisplayId = null;
    _remoteDeviceId = null;
    _remoteHostPlatform = null;
    _localNetworkAddress = null;
    _remoteNetworkAddress = null;
    _remoteSupportsPhysicalKeyboard = false;
    _remoteSupportsActiveContentGeometry = false;
    _remoteActiveContentGeometryVersion = 0;
    _remoteSupportsTextClipboardV1 = false;
    _remoteSupportsExplicitFileTransferV1 = false;
    _remoteSupportsDestinationLeasedFilePasteV1 = false;
    _remoteSupportsAtomicShortcutV1 = false;
    _remoteSupportsScopedInputResetV1 = false;
    _remoteSupportsVideoPolicyV2 = false;
    _remoteSupportsMultiDisplayStreamV1 = false;
    _remoteClipboardSupportsApplied = false;
    _remoteClipboardMode = null;
    _queuedClipboardOffer = null;
    _clipboardSync.resetSession();
    _clipboardApplyGate.reset();
    _fileCopyPaste.resetSession();
    _filePasteLeaseByTransferId.clear();
    _fileClipboardPasteTransferId = null;
    _fileClipboardPastePreparing = false;
    _acceptingFileClipboardTransfers.clear();
    _appliedFileClipboardTransfers.clear();
    _lastHostCaptureFrameState = null;
    _hostInvitationExpiresAt = null;
    _hostInvitationCode = null;
    _hostInvitationLeaseId = null;
    _hostInvitationGeneration = 0;
    _hostInvitationState = HostInvitationState.unavailable;
    _supportsInvitationRotation = false;
    _supportsServerInvitationPush = false;
    _decoderOutputColorDiagnostics = null;
    _renderOutputColorDiagnostics = null;
    _receiverColorConversion = null;
    _mediaDiagnostics = null;
    _mediaStatsAccumulator.reset();
    _qualityAdaptation.reset();
    _colorDiagnostics = null;
    if (role == RemoteRole.controller) {
      _screenCaptureGranted = false;
      _accessibilityGranted = null;
    }
    _authorizingPeer = false;
    _checkingInputPermission = false;
    _inputConfirmed = false;
    _qualityPending = false;
    _queuedQualityProfile = null;
    _queuedVideoPolicy = null;
    _sessionRepairPending = false;
    _hostDisplaySwitchInProgress = false;
    _samplingMediaStats = false;
    _adaptiveQualityUpdateInProgress = false;
    _windowsCaptureRecoveryInProgress = false;
    final adaptiveCompletion = _adaptiveQualityUpdateCompleter;
    if (adaptiveCompletion != null && !adaptiveCompletion.isCompleted) {
      adaptiveCompletion.complete();
    }
    _adaptiveQualityUpdateCompleter = null;
    _automaticQualitySuppressedUntil = null;
    _connectionEstablished = false;
    _displaySwitch.reset();
    _geometryObservationToken += 1;
    _inputSequence = 0;
    _remoteInputEpoch = 0;
    _inputSequenceGuard.reset();
    _inputPermissionPollAttempts = 0;
    _motionEventsSinceProbe = 0;
    _droppedMotionEvents = 0;
    _inputRoundTripMs = null;
    _actualVideoWidth = null;
    _actualVideoHeight = null;
    _expectedVideoFrameSize = null;
    _outboundVideoFrameSize = null;
    _inboundVideoFrameSize = null;
    _frameGeometry.clear();
    _videoGeometryState = RemoteVideoGeometryState.stable;
    _captureTargetLongEdge = null;
    _captureTargetSourceId = null;
    _updateClipboardStatus();
    _closing = false;
  }

  Future<void> _releaseHostInputState() async {
    if (role != RemoteRole.host || !_hostPlatform.capabilities.canHostDesktop) {
      return;
    }
    try {
      _hostInputState.advanceGeneration();
      await _hostInputState.enqueue(_hostPlatform.releaseAllInput);
    } catch (_) {
      // The native window may already be closing or unavailable in tests.
    }
  }

  void _setState(RemoteSessionState next, String message) {
    _state = next;
    _statusMessage = message;
    _kernel.recordState(state: next.name, message: message);
    if (next == RemoteSessionState.disconnected ||
        next == RemoteSessionState.failed) {
      _kernel.end(
        outcome: next == RemoteSessionState.failed ? message : 'disconnected',
      );
    }
    notifyListeners();
  }

  void _fail(String message, {bool announce = true}) {
    _error = message;
    _setState(RemoteSessionState.failed, message);
    if (announce) _emitNotice(message, level: RemoteNoticeLevel.error);
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
    _fileTransfer.removeListener(_handleFileTransferChanged);
    unawaited(_kernel.dispose());
    for (final paths in _stagedOutgoingFiles.values) {
      unawaited(_fileTransferPlatform.cleanupOutgoingFiles(paths));
    }
    _stagedOutgoingFiles.clear();
    unawaited(_fileClipboardOffers.invalidate());
    unawaited(_disposeResources());
    unawaited(_notices.close());
    super.dispose();
  }

  Future<void> _disposeResources() async {
    await _hostWindowLifecycleSubscription?.cancel();
    _hostWindowLifecycleSubscription = null;
    await _clipboardSubscription?.cancel();
    _clipboardSubscription = null;
    await _filePasteIntentSubscription?.cancel();
    _filePasteIntentSubscription = null;
    await _fileTransferNoticeSubscription?.cancel();
    _fileTransferNoticeSubscription = null;
    await _closeSession(notifyPeer: true);
    _fileTransfer.dispose();
    if (_rendererReady) {
      await remoteRenderer.dispose();
      _rendererReady = false;
    }
  }
}

RemoteFrameColorDiagnostics? _frameColorDiagnostics(Object? value) {
  if (value is! Map) return null;
  return RemoteFrameColorDiagnostics.fromMessage(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
}
