import 'package:cross_desktop_remote/core/input/mac_input_bridge.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a native capture first-frame state', () {
    final state = MacCaptureFrameState.fromMap(const {
      'sequence': 12,
      'sourceId': '69733382',
      'width': 1310,
      'height': 892,
      'captureGeneration': 4,
      'gateStatus': 'waiting',
      'rejectionReason': 'contentAspectMismatch',
      'staleFrameCount': 2,
      'wrongSizeCount': 1,
      'missingContentMetadataCount': 3,
      'contentAspectMismatchCount': 8,
      'normalizationFailureCount': 0,
      'bufferWidth': 1920,
      'bufferHeight': 1080,
    });

    expect(state.sequence, 12);
    expect(state.sourceId, '69733382');
    expect(state.width, 1310);
    expect(state.height, 892);
    expect(state.captureGeneration, 4);
    expect(state.gateStatus, 'waiting');
    expect(state.rejectionReason, 'contentAspectMismatch');
    expect(state.contentAspectMismatchCount, 8);
    expect(state.bufferWidth, 1920);
    expect(state.bufferHeight, 1080);
    expect(
      state.gateDiagnosticSummary,
      contains('contentAspectMismatch，Buffer 1920×1080'),
    );
  });

  test('requires a new accepted sequence from the requested display', () {
    final state = MacCaptureFrameState.fromMap(const {
      'sequence': 13,
      'sourceId': 'main-display',
      'width': 1920,
      'height': 1080,
      'gateStatus': 'ready',
    });

    expect(
      state.isReadyAfter(sequence: 12, targetSourceId: 'main-display'),
      isTrue,
    );
    expect(
      state.isReadyAfter(sequence: 13, targetSourceId: 'main-display'),
      isFalse,
      reason: 'polling the same accepted frame must not complete a new switch',
    );
    expect(
      state.isReadyAfter(sequence: 12, targetSourceId: 'sidecar-display'),
      isFalse,
    );
  });

  test('uses an empty non-ready state for missing native values', () {
    final state = MacCaptureFrameState.fromMap(const {});

    expect(state.sequence, 0);
    expect(state.sourceId, isEmpty);
    expect(state.width, 0);
    expect(state.height, 0);
  });
}
