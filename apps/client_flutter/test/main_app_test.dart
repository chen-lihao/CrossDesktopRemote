import 'package:cross_desktop_remote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('renders the mobile application shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MainApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('CrossDesktopRemote'), findsOneWidget);
    expect(find.text('控制其他设备'), findsAtLeastNWidgets(1));
    expect(
      find
              .byKey(const ValueKey('signalingServerField'))
              .evaluate()
              .isNotEmpty ||
          find.byKey(const ValueKey('hostRoomCodeField')).evaluate().isNotEmpty,
      isTrue,
    );
  });

  testWidgets('uses a navigation rail on desktop', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MainApp());

    expect(find.byType(NavigationRail), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
  });

  testWidgets('keeps device page state while switching mobile sections', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const MainApp());

    final serverFieldFinder = find.byKey(
      const ValueKey('signalingServerField'),
    );
    final initialServerController = serverFieldFinder.evaluate().isNotEmpty
        ? tester.widget<TextField>(serverFieldFinder).controller
        : null;
    final roomFieldFinder = find.byKey(const ValueKey('roomCodeField'));
    final hostCodeFinder = find.byKey(const ValueKey('hostRoomCodeText'));
    final initialRoomController = roomFieldFinder.evaluate().isNotEmpty
        ? tester.widget<TextField>(roomFieldFinder).controller
        : null;
    final initialRoomCode =
        initialRoomController?.text ??
        tester.widget<SelectableText>(hostCodeFinder).data;

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    expect(find.text('安全与权限'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.devices_outlined));
    await tester.pump();
    if (initialServerController != null) {
      final restoredServerField = tester.widget<TextField>(serverFieldFinder);
      expect(restoredServerField.controller, same(initialServerController));
    }
    if (initialRoomController != null) {
      final restoredRoomField = tester.widget<TextField>(roomFieldFinder);
      expect(restoredRoomField.controller, same(initialRoomController));
      expect(restoredRoomField.controller?.text, initialRoomCode);
    } else {
      expect(
        tester.widget<SelectableText>(hostCodeFinder).data,
        initialRoomCode,
      );
    }
  });

  testWidgets(
    'host connection code is selectable and has a working copy action',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      MethodCall? clipboardCall;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') clipboardCall = call;
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );

      await tester.pumpWidget(const MainApp());
      final codeFinder = find.byKey(const ValueKey('hostRoomCodeText'));
      if (codeFinder.evaluate().isEmpty) return;

      final fieldFinder = find.byKey(const ValueKey('hostRoomCodeField'));
      expect(fieldFinder, findsOneWidget);
      final field = tester.widget<InputDecorator>(fieldFinder);
      expect(field.decoration.labelText, '六位连接码');
      expect(field.decoration.prefixIcon, isA<Icon>());
      expect(field.decoration.suffixIcon, isA<IconButton>());

      final code = tester.widget<SelectableText>(codeFinder).data;
      expect(code, matches(RegExp(r'^\d{6}$')));
      await tester.tap(find.byKey(const ValueKey('copyRoomCodeButton')));
      await tester.pump();

      expect(clipboardCall?.method, 'Clipboard.setData');
      expect(
        (clipboardCall?.arguments as Map<Object?, Object?>?)?['text'],
        code,
      );
      expect(find.text('连接码已复制'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
    },
  );
}
