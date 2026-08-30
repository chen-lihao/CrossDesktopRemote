import 'dart:io';

import 'package:cross_desktop_remote/core/clipboard/clipboard_sync_mode.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/remote_input_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsController extends ChangeNotifier {
  AppSettingsController();

  static const _qualityKey = 'settings.default_quality';
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

  SharedPreferencesAsync? _preferences;

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
  RemotePointerMode pointerMode = RemotePointerMode.touchpad;
  double pointerSensitivity = 1.25;
  double scrollSensitivity = 2;
  RemoteKeyboardMode keyboardMode = RemoteKeyboardMode.system;
  RemoteTextInputMode textInputMode = RemoteTextInputMode.localIme;
  ClipboardSyncMode clipboardSyncMode = ClipboardSyncMode.bidirectional;
  String signalingServerUrl = Platform.isMacOS
      ? 'ws://127.0.0.1:8080/ws/signaling'
      : '';
  bool lanDiscoveryEnabled = true;
  bool sessionHistoryEnabled = true;
  int sessionHistoryLimit = 50;
  bool showAdvancedNetwork = false;
  bool incomingAccessEnabled = true;
  bool loaded = false;

  RemoteInputSettings get inputSettings => RemoteInputSettings(
    pointerMode: pointerMode,
    pointerSensitivity: pointerSensitivity,
    scrollSensitivity: scrollSensitivity,
    keyboardMode: keyboardMode,
    textInputMode: textInputMode,
  );

  Future<void> load() async {
    final store = _store;
    if (store == null) {
      loaded = true;
      notifyListeners();
      return;
    }
    defaultQuality = RemoteQualityProfile.fromWireValue(
      await store.getString(_qualityKey),
    );
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
    loaded = true;
    notifyListeners();
  }

  Future<void> setDefaultQuality(RemoteQualityProfile value) async {
    if (defaultQuality == value) return;
    defaultQuality = value;
    notifyListeners();
    await _persist((store) => store.setString(_qualityKey, value.name));
  }

  Future<void> setPointerMode(RemotePointerMode value) async {
    if (pointerMode == value) return;
    pointerMode = value;
    notifyListeners();
    await _persist((store) => store.setString(_pointerModeKey, value.name));
  }

  Future<void> setPointerSensitivity(double value) async {
    pointerSensitivity = value.clamp(.5, 2.5);
    notifyListeners();
    await _persist(
      (store) => store.setDouble(_pointerSensitivityKey, pointerSensitivity),
    );
  }

  Future<void> setScrollSensitivity(double value) async {
    scrollSensitivity = value.clamp(.5, 4);
    notifyListeners();
    await _persist(
      (store) => store.setDouble(_scrollSensitivityKey, scrollSensitivity),
    );
  }

  Future<void> setKeyboardMode(RemoteKeyboardMode value) async {
    if (keyboardMode == value) return;
    keyboardMode = value;
    notifyListeners();
    await _persist((store) => store.setString(_keyboardModeKey, value.name));
  }

  Future<void> setTextInputMode(RemoteTextInputMode value) async {
    if (textInputMode == value) return;
    textInputMode = value;
    notifyListeners();
    await _persist((store) => store.setString(_textInputModeKey, value.name));
  }

  Future<void> setClipboardSyncMode(ClipboardSyncMode value) async {
    if (clipboardSyncMode == value) return;
    clipboardSyncMode = value;
    notifyListeners();
    await _persist(
      (store) => store.setString(_clipboardSyncModeKey, value.name),
    );
  }

  Future<void> setSignalingServerUrl(String value) async {
    final normalized = value.trim();
    if (signalingServerUrl == normalized) return;
    signalingServerUrl = normalized;
    notifyListeners();
    await _persist(
      (store) => store.setString(_signalingServerUrlKey, normalized),
    );
  }

  Future<void> setLanDiscoveryEnabled(bool value) async {
    lanDiscoveryEnabled = value;
    notifyListeners();
    await _persist((store) => store.setBool(_lanDiscoveryKey, value));
  }

  Future<void> setSessionHistoryEnabled(bool value) async {
    sessionHistoryEnabled = value;
    notifyListeners();
    await _persist((store) => store.setBool(_historyEnabledKey, value));
  }

  Future<void> setSessionHistoryLimit(int value) async {
    sessionHistoryLimit = value.clamp(10, 100);
    notifyListeners();
    await _persist(
      (store) => store.setInt(_historyLimitKey, sessionHistoryLimit),
    );
  }

  Future<void> setShowAdvancedNetwork(bool value) async {
    showAdvancedNetwork = value;
    notifyListeners();
    await _persist((store) => store.setBool(_advancedNetworkKey, value));
  }

  Future<void> setIncomingAccessEnabled(bool value) async {
    if (incomingAccessEnabled == value) return;
    incomingAccessEnabled = value;
    notifyListeners();
    await _persist((store) => store.setBool(_incomingAccessKey, value));
  }

  Future<void> _persist(
    Future<void> Function(SharedPreferencesAsync store) action,
  ) async {
    final store = _store;
    if (store != null) await action(store);
  }
}
