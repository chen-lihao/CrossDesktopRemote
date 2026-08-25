import 'dart:async';
import 'dart:typed_data';

enum SourceType { Screen, Window }

final desktopSourceTypeToString = <SourceType, String>{
  SourceType.Screen: 'screen',
  SourceType.Window: 'window',
};

final tringToDesktopSourceType = <String, SourceType>{
  'screen': SourceType.Screen,
  'window': SourceType.Window,
};

class ThumbnailSize {
  ThumbnailSize(this.width, this.height);
  factory ThumbnailSize.fromMap(Map<dynamic, dynamic> map) {
    return ThumbnailSize(map['width'], map['height']);
  }
  int width;
  int height;

  Map<String, int> toMap() => {'width': width, 'height': height};
}

class DesktopCaptureConfiguration {
  const DesktopCaptureConfiguration({
    required this.applied,
    this.sourceId,
    this.captureGeneration = 0,
    this.width = 0,
    this.height = 0,
    this.frameRate = 0,
    this.reason,
  });

  factory DesktopCaptureConfiguration.fromMap(Map<dynamic, dynamic> map) {
    return DesktopCaptureConfiguration(
      applied: map['result'] as bool? ?? false,
      sourceId: map['sourceId'] as String?,
      captureGeneration: (map['captureGeneration'] as num?)?.toInt() ?? 0,
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      frameRate: (map['frameRate'] as num?)?.toInt() ?? 0,
      reason: map['reason'] as String?,
    );
  }

  final bool applied;
  final String? sourceId;
  final int captureGeneration;
  final int width;
  final int height;
  final int frameRate;
  final String? reason;

  bool get hasValidGeometry => width > 0 && height > 0;
}

abstract class DesktopCapturerSource {
  /// The identifier of a window or screen that can be used as a
  /// chromeMediaSourceId constraint when calling
  String get id;

  /// A screen source will be named either Entire Screen or Screen index,
  /// while the name of a window source will match the window title.
  String get name;

  ///A thumbnail image of the source. jpeg encoded.
  Uint8List? get thumbnail;

  /// specified in the options passed to desktopCapturer.getSources.
  /// The actual size depends on the scale of the screen or window.
  ThumbnailSize get thumbnailSize;

  /// The type of the source.
  SourceType get type;

  StreamController<String> get onNameChanged => throw UnimplementedError();

  StreamController<Uint8List> get onThumbnailChanged =>
      throw UnimplementedError();
}

abstract class DesktopCapturer {
  StreamController<DesktopCapturerSource> get onAdded =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onRemoved =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onNameChanged =>
      throw UnimplementedError();
  StreamController<DesktopCapturerSource> get onThumbnailChanged =>
      throw UnimplementedError();

  ///Get the screen source of the specified types
  Future<List<DesktopCapturerSource>> getSources({
    required List<SourceType> types,
    ThumbnailSize? thumbnailSize,
  });

  /// Updates the list of screen sources of the specified types
  Future<bool> updateSources({required List<SourceType> types});

  /// Switches an active desktop video track to another screen without
  /// replacing the WebRTC track. Platforms that cannot update the running
  /// capturer return false so callers can use their compatibility fallback.
  Future<DesktopCaptureConfiguration> switchSource({
    required String trackId,
    required String sourceId,
    required int frameRate,
    int? targetLongEdge,
  });

  /// Permanently releases the previous warm capture stream after the
  /// controller has decoded and rendered the target display generation.
  Future<bool> commitSourceSwitch({
    required String trackId,
    required int captureGeneration,
  });

  /// Restores the untouched previous capture stream when target media is not
  /// acknowledged. This does not replace the WebRTC track or sender.
  Future<DesktopCaptureConfiguration> rollbackSourceSwitch({
    required String trackId,
    required int captureGeneration,
  });

  /// Reconfigures the running desktop capturer without replacing its track.
  Future<DesktopCaptureConfiguration> updateCaptureFormat({
    required String trackId,
    required int frameRate,
    int? targetLongEdge,
  });

  /// Requests that the next desktop video frame be encoded as a key frame.
  ///
  /// This is used after an in-place display switch so the decoder never
  /// references pixels from the previously selected screen.
  Future<bool> requestKeyFrame();
}
