import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum RemoteDisplayAdjustmentMode {
  automatic('自动'),
  standardSdr('标准 SDR'),
  softHighlights('柔和高光'),
  custom('自定义');

  const RemoteDisplayAdjustmentMode(this.label);

  final String label;
}

class RemoteDisplayAdjustment {
  const RemoteDisplayAdjustment({
    this.mode = RemoteDisplayAdjustmentMode.automatic,
    this.brightness = 0,
    this.contrast = 1,
    this.saturation = 1,
  });

  factory RemoteDisplayAdjustment.fromJson(Map<String, dynamic> json) {
    final modeName = json['mode'] as String?;
    final mode = RemoteDisplayAdjustmentMode.values.firstWhere(
      (value) => value.name == modeName,
      orElse: () => RemoteDisplayAdjustmentMode.automatic,
    );
    return RemoteDisplayAdjustment(
      mode: mode,
      brightness: ((json['brightness'] as num?)?.toDouble() ?? 0).clamp(
        -0.25,
        0.25,
      ),
      contrast: ((json['contrast'] as num?)?.toDouble() ?? 1).clamp(0.7, 1.3),
      saturation: ((json['saturation'] as num?)?.toDouble() ?? 1).clamp(0, 1.5),
    );
  }

  final RemoteDisplayAdjustmentMode mode;
  final double brightness;
  final double contrast;
  final double saturation;

  RemoteDisplayAdjustment get effective => switch (mode) {
    RemoteDisplayAdjustmentMode.automatic => const RemoteDisplayAdjustment(),
    RemoteDisplayAdjustmentMode.standardSdr => const RemoteDisplayAdjustment(
      mode: RemoteDisplayAdjustmentMode.standardSdr,
    ),
    RemoteDisplayAdjustmentMode.softHighlights => const RemoteDisplayAdjustment(
      mode: RemoteDisplayAdjustmentMode.softHighlights,
      brightness: -0.04,
      contrast: 0.9,
      saturation: 0.98,
    ),
    RemoteDisplayAdjustmentMode.custom => this,
  };

  bool get isIdentity {
    final value = effective;
    return value.brightness == 0 &&
        value.contrast == 1 &&
        value.saturation == 1;
  }

  List<double> get colorMatrix {
    final value = effective;
    final saturation = value.saturation;
    final inverseSaturation = 1 - saturation;
    final redLuma = 0.2126 * inverseSaturation;
    final greenLuma = 0.7152 * inverseSaturation;
    final blueLuma = 0.0722 * inverseSaturation;
    final contrast = value.contrast;
    final offset = 128 * (1 - contrast) + 255 * value.brightness;

    return [
      contrast * (redLuma + saturation),
      contrast * greenLuma,
      contrast * blueLuma,
      0,
      offset,
      contrast * redLuma,
      contrast * (greenLuma + saturation),
      contrast * blueLuma,
      0,
      offset,
      contrast * redLuma,
      contrast * greenLuma,
      contrast * (blueLuma + saturation),
      0,
      offset,
      0,
      0,
      0,
      1,
      0,
    ];
  }

  RemoteDisplayAdjustment copyWith({
    RemoteDisplayAdjustmentMode? mode,
    double? brightness,
    double? contrast,
    double? saturation,
  }) {
    return RemoteDisplayAdjustment(
      mode: mode ?? this.mode,
      brightness: brightness ?? this.brightness,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
    );
  }

  Map<String, dynamic> toJson() => {
    'mode': mode.name,
    'brightness': brightness,
    'contrast': contrast,
    'saturation': saturation,
  };
}

abstract interface class RemoteDisplayAdjustmentStore {
  Future<RemoteDisplayAdjustment?> load(String key);

  Future<void> save(String key, RemoteDisplayAdjustment value);

  Future<void> remove(String key);
}

class SharedPreferencesDisplayAdjustmentStore
    implements RemoteDisplayAdjustmentStore {
  SharedPreferencesDisplayAdjustmentStore({SharedPreferencesAsync? preferences})
    : _preferences = preferences ?? SharedPreferencesAsync();

  final SharedPreferencesAsync _preferences;

  @override
  Future<RemoteDisplayAdjustment?> load(String key) async {
    final encoded = await _preferences.getString(key);
    if (encoded == null) return null;
    try {
      final value = jsonDecode(encoded);
      return value is Map<String, dynamic>
          ? RemoteDisplayAdjustment.fromJson(value)
          : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> save(String key, RemoteDisplayAdjustment value) {
    return _preferences.setString(key, jsonEncode(value.toJson()));
  }

  @override
  Future<void> remove(String key) => _preferences.remove(key);
}

class RemoteDisplayAdjustmentController
    extends ValueNotifier<RemoteDisplayAdjustment> {
  RemoteDisplayAdjustmentController({RemoteDisplayAdjustmentStore? store})
    : _store = store ?? SharedPreferencesDisplayAdjustmentStore(),
      super(const RemoteDisplayAdjustment());

  final RemoteDisplayAdjustmentStore _store;
  String? _storageKey;
  int _loadGeneration = 0;

  Future<void> selectTarget({
    required String? deviceId,
    required String? displayId,
  }) async {
    final normalizedDevice = deviceId?.trim();
    final normalizedDisplay = displayId?.trim();
    if (normalizedDevice == null ||
        normalizedDevice.isEmpty ||
        normalizedDisplay == null ||
        normalizedDisplay.isEmpty) {
      _storageKey = null;
      value = const RemoteDisplayAdjustment();
      return;
    }
    final key = 'crossdesktop.display.$normalizedDevice.$normalizedDisplay';
    if (_storageKey == key) return;
    _storageKey = key;
    final generation = ++_loadGeneration;
    final loaded = await _store.load(key);
    if (generation == _loadGeneration && _storageKey == key) {
      value = loaded ?? const RemoteDisplayAdjustment();
    }
  }

  void setMode(RemoteDisplayAdjustmentMode mode) {
    final next = value.copyWith(mode: mode);
    value = next;
    _save(next);
  }

  void updateCustom({
    double? brightness,
    double? contrast,
    double? saturation,
  }) {
    final next = value.copyWith(
      mode: RemoteDisplayAdjustmentMode.custom,
      brightness: brightness,
      contrast: contrast,
      saturation: saturation,
    );
    value = next;
    _save(next);
  }

  Future<void> reset() async {
    final key = _storageKey;
    value = const RemoteDisplayAdjustment();
    if (key != null) await _store.remove(key);
  }

  void _save(RemoteDisplayAdjustment adjustment) {
    final key = _storageKey;
    if (key != null) unawaited(_store.save(key, adjustment));
  }
}
