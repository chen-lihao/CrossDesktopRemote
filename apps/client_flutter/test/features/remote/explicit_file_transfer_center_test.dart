import 'dart:async';

import 'package:cross_desktop_remote/core/clipboard/clipboard_platform_adapter.dart';
import 'package:cross_desktop_remote/core/input/unsupported_host_platform_adapter.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/presentation/explicit_file_transfer_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('host can open the shared transfer center', (tester) async {
    final session = _FakeFileTransferSession(tasks: [_incomingTask()]);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HostFileTransferSection(session: session)),
      ),
    );

    expect(find.text('收到 1 个待确认的文件传输请求'), findsOneWidget);
    expect(find.text('选择保存位置并接收'), findsOneWidget);
    expect(find.text('拒绝'), findsOneWidget);

    await tester.tap(find.text('打开传输中心'));
    await tester.pumpAndSettle();

    expect(find.text('发送文件'), findsOneWidget);
    expect(find.text('发送目录'), findsOneWidget);
    expect(find.text('选择保存位置并接收'), findsNWidgets(2));
  });

  testWidgets('host can reject an incoming transfer from its status page', (
    tester,
  ) async {
    final session = _FakeFileTransferSession(tasks: [_incomingTask()]);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HostFileTransferSection(session: session)),
      ),
    );

    await tester.tap(find.text('拒绝'));
    await tester.pump();

    expect(session.rejectedTransferId, 'incoming-1');
  });

  testWidgets('host selects a destination before accepting the transfer', (
    tester,
  ) async {
    final session = _FakeFileTransferSession(tasks: [_incomingTask()]);
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HostFileTransferSection(
            session: session,
            destinationPicker: () async => '/receive/files',
          ),
        ),
      ),
    );

    await tester.tap(find.text('选择保存位置并接收'));
    await tester.pump();

    expect(session.acceptedTransferId, 'incoming-1');
    expect(session.acceptedDestination, '/receive/files');
  });

  testWidgets('iPad accepts into managed storage without a directory picker', (
    tester,
  ) async {
    final session = _FakeFileTransferSession(
      tasks: [_incomingTask()],
      managedReceiveStorage: true,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HostFileTransferSection(session: session)),
      ),
    );

    expect(find.text('接收到应用暂存区'), findsOneWidget);
    await tester.tap(find.text('接收到应用暂存区'));
    await tester.pump();

    expect(session.managedAcceptedTransferId, 'incoming-1');
  });

  testWidgets('iPad completed receive exposes export and share actions', (
    tester,
  ) async {
    final session = _FakeFileTransferSession(
      tasks: [_completedIncomingTask()],
      managedReceiveStorage: true,
    );
    addTearDown(session.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: HostFileTransferSection(session: session)),
      ),
    );

    await tester.tap(find.text('打开传输中心'));
    await tester.pumpAndSettle();
    expect(find.text('导出到“文件”'), findsOneWidget);
    expect(find.text('分享…'), findsOneWidget);

    await tester.tap(find.text('导出到“文件”'));
    await tester.pump();
    expect(session.exportedTransferId, 'incoming-completed');

    await tester.tap(find.text('分享…'));
    await tester.pump();
    expect(session.sharedTransferId, 'incoming-completed');
  });
}

ExplicitFileTransferTaskSnapshot _incomingTask() {
  return ExplicitFileTransferTaskSnapshot(
    id: 'incoming-1',
    direction: ExplicitFileTransferDirection.incoming,
    state: ExplicitFileTransferState.awaitingAcceptance,
    entries: const [
      ExplicitFileTransferEntry(
        index: 0,
        relativePath: '资料/project.zip',
        kind: ExplicitFileEntryKind.file,
        sizeBytes: 4096,
        modifiedAtUnixMs: 0,
        sha256Hex:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ),
    ],
    transferredBytes: 0,
    totalBytes: 4096,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    message: '请选择接收目录并确认',
  );
}

ExplicitFileTransferTaskSnapshot _completedIncomingTask() {
  return ExplicitFileTransferTaskSnapshot(
    id: 'incoming-completed',
    direction: ExplicitFileTransferDirection.incoming,
    state: ExplicitFileTransferState.completed,
    entries: const [
      ExplicitFileTransferEntry(
        index: 0,
        relativePath: 'report.pdf',
        kind: ExplicitFileEntryKind.file,
        sizeBytes: 4096,
        modifiedAtUnixMs: 0,
        sha256Hex:
            '0000000000000000000000000000000000000000000000000000000000000000',
      ),
    ],
    transferredBytes: 4096,
    totalBytes: 4096,
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
    destinationRoot: '/managed/incoming/incoming-completed',
  );
}

class _FakeFileTransferSession extends RemoteSessionController {
  _FakeFileTransferSession({
    required this.tasks,
    this.managedReceiveStorage = false,
  }) : super(
         role: RemoteRole.host,
         hostPlatformAdapter: const UnsupportedHostPlatformAdapter(),
         clipboardPlatformAdapter: const UnsupportedClipboardPlatformAdapter(),
         hostWindowLifecycleEvents: const Stream.empty(),
       );

  final List<ExplicitFileTransferTaskSnapshot> tasks;
  final bool managedReceiveStorage;
  String? rejectedTransferId;
  String? acceptedTransferId;
  String? acceptedDestination;
  String? managedAcceptedTransferId;
  String? exportedTransferId;
  String? sharedTransferId;

  @override
  bool get localExplicitFileTransferSupported => true;

  @override
  bool get remoteSupportsExplicitFileTransferV1 => true;

  @override
  bool get explicitFileTransferReady => true;

  @override
  bool get explicitFileTransferDirectorySelectionSupported =>
      !managedReceiveStorage;

  @override
  bool get explicitFileTransferUsesManagedReceiveStorage =>
      managedReceiveStorage;

  @override
  bool get explicitFileTransferReceivedExportSupported => managedReceiveStorage;

  @override
  List<ExplicitFileTransferTaskSnapshot> get fileTransferTasks => tasks;

  @override
  int get pendingIncomingFileTransferCount =>
      tasks.where((task) => task.awaitsAcceptance).length;

  @override
  Future<void> rejectExplicitFileTransfer(String transferId) async {
    rejectedTransferId = transferId;
  }

  @override
  Future<void> acceptExplicitFileTransfer(
    String transferId,
    String destinationRoot,
  ) async {
    acceptedTransferId = transferId;
    acceptedDestination = destinationRoot;
  }

  @override
  Future<void> acceptExplicitFileTransferToManagedStorage(
    String transferId,
  ) async {
    managedAcceptedTransferId = transferId;
  }

  @override
  Future<void> exportExplicitFileTransfer(String transferId) async {
    exportedTransferId = transferId;
  }

  @override
  Future<void> shareExplicitFileTransfer(String transferId) async {
    sharedTransferId = transferId;
  }
}
