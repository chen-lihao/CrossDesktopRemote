import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cross_desktop_remote/core/clipboard/clipboard_sync_mode.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_server_profile.dart';
import 'package:cross_desktop_remote/core/privacy/host_privacy_screen.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_input_settings.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_repository.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RemoteDisplayPresentationMode {
  singleWindow,
  separateWindows;

  String get label => switch (this) {
    RemoteDisplayPresentationMode.singleWindow => '单窗口切换',
    RemoteDisplayPresentationMode.separateWindows => '每个显示器独立窗口',
  };
}

class AppSettingsController extends ChangeNotifier {
  AppSettingsController([this._repository]);

  @visibleForTesting
  static Future<AppSettingsRepository> Function()? repositoryFactoryOverride;

  static const _qualityKey = 'settings.default_quality';
  static const _videoPolicyKey = 'settings.default_video_policy.v2';
  static const _pointerModeKey = 'settings.pointer_mode';
  static const _pointerSensitivityKey = 'settings.pointer_sensitivity';
  static const _scrollSensitivityKey = 'settings.scroll_sensitivity';
  static const _keyboardModeKey = 'settings.keyboard_mode';
  static const _textInputModeKey = 'settings.text_input_mode';
  static const _clipboardSyncModeKey = 'settings.clipboard_sync_mode';
  static const _signalingServerUrlKey = 'settings.signaling_server_url';
  static const _lanDiscoveryKey = 'settings.lan_discovery';
  static const _historyEnabledKey = 'settings.session_history_enabled';
  static const _historyLimitKey = 'settings.session_history_limit';
  static const _advancedNetworkKey = 'settings.show_advanced_network';
  static const _incomingAccessKey = 'settings.incoming_access_enabled';
  static const _systemAudioSharingKey = 'settings.system_audio_sharing_enabled';
  static const _hostPrivacyModeKey = 'settings.host_privacy_mode';
  static const _displayPresentationKey = 'settings.remote_display_presentation';

  SharedPreferencesAsync? _preferences;
  AppSettingsRepository? _repository;
  Future<void> _writeQueue = Future<void>.value();
  Object? persistenceError;

  SharedPreferencesAsync? get _store {
    if (_preferences != null) return _preferences;
    try {
      return _preferences = SharedPreferencesAsync();
    } on StateError {
      // Tests and previews may intentionally run without platform plugins.
      return null;
    }
  }

  RemoteQualityProfile defaultQuality = RemoteQualityProfile.automatic;
  RemoteVideoPolicy defaultVideoPolicy = const RemoteVideoPolicy();
  RemotePointerMode pointerMode = RemotePointerMode.touchpad;
  double pointerSensitivity = 1.25;
  double scrollSensitivity = 2;
  RemoteKeyboardMode keyboardMode = RemoteKeyboardMode.system;
  RemoteTextInputMode textInputMode = RemoteTextInputMode.localIme;
  ClipboardSyncMode clipboardSyncMode = ClipboardSyncMode.bidirectional;
  String signalingServerUrl = Platform.isIOS
      ? ''
      : SignalingServerProfile.localDevelopment.url;
  bool lanDiscoveryEnabled = true;
  bool sessionHistoryEnabled = true;
  int sessionHistoryLimit = 50;
  bool showAdvancedNetwork = false;
  bool incomingAccessEnabled = true;
  bool systemAudioSharingEnabled = false;
  HostPrivacyMode hostPrivacyMode = HostPrivacyMode.disabled;
  RemoteDisplayPresentationMode displayPresentationMode =
      RemoteDisplayPresentationMode.singleWindow;
  bool loaded = false;

  SignalingServerProfile? get signalingServerProfile {
    if (signalingServerUrl.isEmpty) return null;
    try {
      return SignalingServerProfile.forUrl(signalingServerUrl);
    } on FormatException {
      // The device-page field persists its draft while the user is typing.
      return null;
    }
  }

  RemoteInputSettings get inputSettings => RemoteInputSettings(
    pointerMode: pointerMode,
    pointerSensitivity: pointerSensitivity,
    scrollSensitivity: scrollSensitivity,
    keyboardMode: keyboardMode,
    textInputMode: textInputMode,
  );

  Future<void> load() async {
    try {
      _repository ??=
          await (repositoryFactoryOverride?.call() ??
              SqliteAppSettingsRepository.open());
      final persisted = await _repository!.read();
      if (persisted != null) {
        _applySnapshot(persisted);
      } else {
        await _loadLegacyPreferences();
        await _repository!.write(_snapshot());
      }
      persistenceError = null;
    } catch (error) {
      // Tests and previews may intentionally run without native assets. The
      // in-memory fallback keeps the UI usable, while production surfaces the
      // error instead of pretending that a durable write succeeded.
      persistenceError = error;
      _repository?.close();
      _repository = MemoryAppSettingsRepository();
      try {
        await _loadLegacyPreferences();
      } catch (_) {
        // Platform persistence is intentionally absent in widget tests and
        // previews; the documented defaults remain available.
      }
    }
    loaded = true;
    notifyListeners();
  }

  Future<void> _loadLegacyPreferences() async {
    final store = _store;
    if (store == null) return;
    defaultQuality = RemoteQualityProfile.fromWireValue(
      await store.getString(_qualityKey),
    );
    final storedVideoPolicy = await store.getString(_videoPolicyKey);
    if (storedVideoPolicy != null) {
      try {
        defaultVideoPolicy = RemoteVideoPolicy.fromMessage(
          (jsonDecode(storedVideoPolicy) as Map).cast<String, dynamic>(),
        );
        defaultQuality = defaultVideoPolicy.legacyProfile;
      } catch (_) {
        defaultVideoPolicy = RemoteVideoPolicy.fromLegacy(defaultQuality);
      }
    } else {
      defaultVideoPolicy = RemoteVideoPolicy.fromLegacy(defaultQuality);
    }
    final storedPointerMode = await store.getString(_pointerModeKey);
    pointerMode = RemotePointerMode.values.firstWhere(
      (value) => value.name == (storedPointerMode ?? pointerMode.name),
      orElse: () => RemotePointerMode.touchpad,
    );
    pointerSensitivity = await store.getDouble(_pointerSensitivityKey) ?? 1.25;
    scrollSensitivity = await store.getDouble(_scrollSensitivityKey) ?? 2;
    final storedKeyboardMode = await store.getString(_keyboardModeKey);
    keyboardMode = RemoteKeyboardMode.values.firstWhere(
      (value) => value.name == (storedKeyboardMode ?? keyboardMode.name),
      orElse: () => RemoteKeyboardMode.system,
    );
    final storedTextInputMode = await store.getString(_textInputModeKey);
    textInputMode = RemoteTextInputMode.values.firstWhere(
      (value) => value.name == (storedTextInputMode ?? textInputMode.name),
      orElse: () => RemoteTextInputMode.localIme,
    );
    final storedClipboardMode = await store.getString(_clipboardSyncModeKey);
    clipboardSyncMode = ClipboardSyncMode.values.firstWhere(
      (value) => value.name == (storedClipboardMode ?? clipboardSyncMode.name),
      orElse: () => ClipboardSyncMode.bidirectional,
    );
    signalingServerUrl =
        await store.getString(_signalingServerUrlKey) ?? signalingServerUrl;
    lanDiscoveryEnabled = await store.getBool(_lanDiscoveryKey) ?? true;
    sessionHistoryEnabled = await store.getBool(_historyEnabledKey) ?? true;
    sessionHistoryLimit = (await store.getInt(_historyLimitKey) ?? 50).clamp(
      10,
      100,
    );
    showAdvancedNetwork = await store.getBool(_advancedNetworkKey) ?? false;
    incomingAccessEnabled = await store.getBool(_incomingAccessKey) ?? true;
    systemAudioSharingEnabled =
        await store.getBool(_systemAudioSharingKey) ?? false;
    final storedPrivacyMode = await store.getString(_hostPrivacyModeKey);
    hostPrivacyMode = HostPrivacyMode.values.firstWhere(
      (value) => value.name == storedPrivacyMode,
      orElse: () => HostPrivacyMode.disabled,
    );
    final storedPresentation = await store.getString(_displayPresentationKey);
    displayPresentationMode = RemoteDisplayPresentationMode.values.firstWhere(
      (value) => value.name == storedPresentation,
      orElse: () => RemoteDisplayPresentationMode.singleWindow,
    );
  }

  Future<void> setDefaultQuality(RemoteQualityProfile value) async {
    await setDefaultVideoPolicy(RemoteVideoPolicy.fromLegacy(value));
  }

  Future<void> setDefaultVideoPolicy(RemoteVideoPolicy value) async {
    if (defaultVideoPolicy == value) return;
    defaultVideoPolicy = value;
    defaultQuality = value.legacyProfile;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setPointerMode(RemotePointerMode value) async {
    if (pointerMode == value) return;
    pointerMode = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setPointerSensitivity(double value) async {
    pointerSensitivity = value.clamp(.5, 2.5);
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setScrollSensitivity(double value) async {
    scrollSensitivity = value.clamp(.5, 4);
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setKeyboardMode(RemoteKeyboardMode value) async {
    if (keyboardMode == value) return;
    keyboardMode = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setTextInputMode(RemoteTextInputMode value) async {
    if (textInputMode == value) return;
    textInputMode = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setClipboardSyncMode(ClipboardSyncMode value) async {
    if (clipboardSyncMode == value) return;
    clipboardSyncMode = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setSignalingServerUrl(String value) async {
    final normalized = value.trim();
    if (signalingServerUrl == normalized) return;
    signalingServerUrl = normalized;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setLanDiscoveryEnabled(bool value) async {
    lanDiscoveryEnabled = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setSessionHistoryEnabled(bool value) async {
    sessionHistoryEnabled = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setSessionHistoryLimit(int value) async {
    sessionHistoryLimit = value.clamp(10, 100);
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setShowAdvancedNetwork(bool value) async {
    showAdvancedNetwork = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setIncomingAccessEnabled(bool value) async {
    if (incomingAccessEnabled == value) return;
    incomingAccessEnabled = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setSystemAudioSharingEnabled(bool value) async {
    if (systemAudioSharingEnabled == value) return;
    systemAudioSharingEnabled = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setHostPrivacyMode(HostPrivacyMode value) async {
    if (hostPrivacyMode == value) return;
    hostPrivacyMode = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Future<void> setDisplayPresentationMode(
    RemoteDisplayPresentationMode value,
  ) async {
    if (displayPresentationMode == value) return;
    displayPresentationMode = value;
    notifyListeners();
    await _persistSnapshot();
  }

  Map<String, dynamic> _snapshot() => {
    _qualityKey: defaultQuality.name,
    _videoPolicyKey: defaultVideoPolicy.toMessage(),
    _pointerModeKey: pointerMode.name,
    _pointerSensitivityKey: pointerSensitivity,
    _scrollSensitivityKey: scrollSensitivity,
    _keyboardModeKey: keyboardMode.name,
    _textInputModeKey: textInputMode.name,
    _clipboardSyncModeKey: clipboardSyncMode.name,
    _signalingServerUrlKey: signalingServerUrl,
    _lanDiscoveryKey: lanDiscoveryEnabled,
    _historyEnabledKey: sessionHistoryEnabled,
    _historyLimitKey: sessionHistoryLimit,
    _advancedNetworkKey: showAdvancedNetwork,
    _incomingAccessKey: incomingAccessEnabled,
    _systemAudioSharingKey: systemAudioSharingEnabled,
    _hostPrivacyModeKey: hostPrivacyMode.name,
    _displayPresentationKey: displayPresentationMode.name,
  };

  void _applySnapshot(Map<String, dynamic> value) {
    defaultQuality = RemoteQualityProfile.fromWireValue(
      value[_qualityKey] as String?,
    );
    final rawPolicy = value[_videoPolicyKey];
    if (rawPolicy is Map) {
      try {
        defaultVideoPolicy = RemoteVideoPolicy.fromMessage(
          rawPolicy.cast<String, dynamic>(),
        );
        defaultQuality = defaultVideoPolicy.legacyProfile;
      } catch (_) {
        defaultVideoPolicy = RemoteVideoPolicy.fromLegacy(defaultQuality);
      }
    } else {
      defaultVideoPolicy = RemoteVideoPolicy.fromLegacy(defaultQuality);
    }
    pointerMode = RemotePointerMode.values.firstWhere(
      (item) => item.name == value[_pointerModeKey],
      orElse: () => RemotePointerMode.touchpad,
    );
    pointerSensitivity =
        (value[_pointerSensitivityKey] as num?)?.toDouble().clamp(.5, 2.5) ??
        1.25;
    scrollSensitivity =
        (value[_scrollSensitivityKey] as num?)?.toDouble().clamp(.5, 4) ?? 2;
    keyboardMode = RemoteKeyboardMode.values.firstWhere(
      (item) => item.name == value[_keyboardModeKey],
      orElse: () => RemoteKeyboardMode.system,
    );
    textInputMode = RemoteTextInputMode.values.firstWhere(
      (item) => item.name == value[_textInputModeKey],
      orElse: () => RemoteTextInputMode.localIme,
    );
    clipboardSyncMode = ClipboardSyncMode.values.firstWhere(
      (item) => item.name == value[_clipboardSyncModeKey],
      orElse: () => ClipboardSyncMode.bidirectional,
    );
    signalingServerUrl =
        value[_signalingServerUrlKey] as String? ?? signalingServerUrl;
    lanDiscoveryEnabled = value[_lanDiscoveryKey] as bool? ?? true;
    sessionHistoryEnabled = value[_historyEnabledKey] as bool? ?? true;
    sessionHistoryLimit = ((value[_historyLimitKey] as num?)?.toInt() ?? 50)
        .clamp(10, 100);
    showAdvancedNetwork = value[_advancedNetworkKey] as bool? ?? false;
    incomingAccessEnabled = value[_incomingAccessKey] as bool? ?? true;
    systemAudioSharingEnabled = value[_systemAudioSharingKey] as bool? ?? false;
    hostPrivacyMode = HostPrivacyMode.values.firstWhere(
      (item) => item.name == value[_hostPrivacyModeKey],
      orElse: () => HostPrivacyMode.disabled,
    );
    displayPresentationMode = RemoteDisplayPresentationMode.values.firstWhere(
      (item) => item.name == value[_displayPresentationKey],
      orElse: () => RemoteDisplayPresentationMode.singleWindow,
    );
  }

  Future<void> _persistSnapshot() {
    final value = _snapshot();
    final repository = _repository;
    if (repository == null) return Future<void>.value();
    final completion = Completer<void>();
    _writeQueue = _writeQueue
        .catchError((_) {})
        .then((_) => repository.write(value))
        .then((_) {
          persistenceError = null;
          completion.complete();
        })
        .catchError((Object error, StackTrace stackTrace) {
          persistenceError = error;
          notifyListeners();
          if (!completion.isCompleted) {
            completion.completeError(error, stackTrace);
          }
        });
    return completion.future;
  }

  @override
  void dispose() {
    final repository = _repository;
    _repository = null;
    unawaited(_writeQueue.whenComplete(() => repository?.close()));
    super.dispose();
  }
}
