import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/features/remote/presentation/video_policy_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('cancel keeps controllers alive through the closing transition', (
    tester,
  ) async {
    RemoteVideoPolicy? selected;
    await tester.pumpWidget(
      _DialogTestApp(
        onSelected: (value) => selected = value,
        initialPolicy: const RemoteVideoPolicy(
          resolution: RemoteResolutionMode.custom,
          frameRate: RemoteFrameRateMode.custom,
        ),
      ),
    );

    for (var attempt = 0; attempt < 5; attempt += 1) {
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('videoPolicyCustomFpsField')));
      await tester.enterText(
        find.byKey(const ValueKey('videoPolicyCustomFpsField')),
        '${60 + attempt}',
      );
      await tester.tap(find.byKey(const ValueKey('videoPolicyCancelButton')));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    expect(selected, isNull);
  });

  testWidgets('apply returns independent custom video values', (tester) async {
    RemoteVideoPolicy? selected;
    await tester.pumpWidget(
      _DialogTestApp(
        onSelected: (value) => selected = value,
        initialPolicy: const RemoteVideoPolicy(
          resolution: RemoteResolutionMode.custom,
          frameRate: RemoteFrameRateMode.custom,
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyCustomLongEdgeField')),
      '2560',
    );
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyCustomFpsField')),
      '90',
    );
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyBitrateField')),
      '24',
    );
    await tester.tap(find.byKey(const ValueKey('videoPolicyApplyButton')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();

    expect(selected?.customLongEdge, 2560);
    expect(selected?.customFramesPerSecond, 90);
    expect(selected?.maxBitrateMbps, 24);
    expect(tester.takeException(), isNull);
  });

  testWidgets('invalid custom values remain in the dialog with errors', (
    tester,
  ) async {
    await tester.pumpWidget(
      const _DialogTestApp(
        initialPolicy: RemoteVideoPolicy(
          resolution: RemoteResolutionMode.custom,
          frameRate: RemoteFrameRateMode.custom,
        ),
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyCustomLongEdgeField')),
      '319',
    );
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyCustomFpsField')),
      '121',
    );
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyBitrateField')),
      '101',
    );
    await tester.tap(find.byKey(const ValueKey('videoPolicyApplyButton')));
    await tester.pump();

    expect(find.byType(VideoPolicyDialog), findsOneWidget);
    expect(find.text('分辨率长边范围为 320～7680'), findsOneWidget);
    expect(find.text('帧率范围为 5～120'), findsOneWidget);
    expect(find.text('最大码率范围为 1～100'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('custom-only editor commits custom modes and automatic bitrate', (
    tester,
  ) async {
    RemoteVideoPolicy? selected;
    await tester.pumpWidget(
      _DialogTestApp(
        onSelected: (value) => selected = value,
        customValuesOnly: true,
      ),
    );

    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('videoPolicyBitrateField')),
      '',
    );
    await tester.tap(find.byKey(const ValueKey('videoPolicyApplyButton')));
    await tester.pumpAndSettle();

    expect(selected?.resolution, RemoteResolutionMode.custom);
    expect(selected?.frameRate, RemoteFrameRateMode.custom);
    expect(selected?.maxBitrateMbps, isNull);
    expect(tester.takeException(), isNull);
  });
}

class _DialogTestApp extends StatelessWidget {
  const _DialogTestApp({
    this.initialPolicy = const RemoteVideoPolicy(),
    this.onSelected,
    this.customValuesOnly = false,
  });

  final RemoteVideoPolicy initialPolicy;
  final ValueChanged<RemoteVideoPolicy?>? onSelected;
  final bool customValuesOnly;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: FilledButton(
              onPressed: () async {
                final result = await showVideoPolicyEditor(
                  context: context,
                  initialPolicy: initialPolicy,
                  customValuesOnly: customValuesOnly,
                );
                onSelected?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
  }
}
