import 'package:cross_desktop_remote/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('renders the mobile application shell', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const MainApp());

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('CrossDesktopRemote'), findsOneWidget);
    expect(find.text('控制其他设备'), findsAtLeastNWidgets(1));
    expect(find.byKey(const ValueKey('signalingServerField')), findsOneWidget);
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

    final serverField = tester.widget<TextField>(
      find.byKey(const ValueKey('signalingServerField')),
    );
    final roomField = tester.widget<TextField>(
      find.byKey(const ValueKey('roomCodeField')),
    );
    final initialServerController = serverField.controller;
    final initialRoomController = roomField.controller;
    final initialRoomCode = initialRoomController?.text;

    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pump();
    expect(find.text('安全与权限'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.devices_outlined));
    await tester.pump();
    final restoredServerField = tester.widget<TextField>(
      find.byKey(const ValueKey('signalingServerField')),
    );
    final restoredRoomField = tester.widget<TextField>(
      find.byKey(const ValueKey('roomCodeField')),
    );

    expect(restoredServerField.controller, same(initialServerController));
    expect(restoredRoomField.controller, same(initialRoomController));
    expect(restoredRoomField.controller?.text, initialRoomCode);
  });
}
