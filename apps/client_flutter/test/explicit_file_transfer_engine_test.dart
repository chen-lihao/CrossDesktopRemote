import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_engine.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory sandbox;
  late ExplicitFileTransferEngine sender;
  late ExplicitFileTransferEngine receiver;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('cdr-transfer-test-');
    sender = ExplicitFileTransferEngine();
    receiver = ExplicitFileTransferEngine();
  });

  tearDown(() async {
    sender.dispose();
    receiver.dispose();
    await Future<void>.delayed(Duration.zero);
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('transfers a file through bounded binary frames and atomically lands it', () async {
    _connect(sender, receiver);
    await _waitFor(() => sender.transportReady && receiver.transportReady);
    final source = File('${sandbox.path}${Platform.pathSeparator}你好🚀.txt');
    final content =
        utf8.encode('文件传输\n') +
        List<int>.generate(70 * 1024, (index) => index % 251);
    await source.writeAsBytes(content);
    final destination = await Directory(
      '${sandbox.path}${Platform.pathSeparator}received',
    ).create();

    await sender.sendFiles([source.path]);
    await _waitFor(() => receiver.pendingIncomingCount == 1);
    final incoming = receiver.tasks.singleWhere((task) => task.isIncoming);
    await receiver.accept(incoming.id, destination.path);
    await _waitFor(
      () =>
          receiver.tasks.singleWhere((task) => task.id == incoming.id).state ==
          ExplicitFileTransferState.completed,
    );

    final landed = File(
      '${destination.path}${Platform.pathSeparator}${source.uri.pathSegments.last}',
    );
    expect(await landed.readAsBytes(), content);
    expect(
      destination.listSync().where(
        (entity) => entity.path.endsWith('.cdrpart'),
      ),
      isEmpty,
    );
    await _waitFor(
      () =>
          sender.tasks
              .singleWhere(
                (task) =>
                    task.direction == ExplicitFileTransferDirection.outgoing,
              )
              .state ==
          ExplicitFileTransferState.completed,
    );
  });

  test('clipboard purpose survives offer negotiation without changing v1 transport', () async {
    _connect(sender, receiver);
    await _waitFor(() => sender.transportReady && receiver.transportReady);
    final source = File('${sandbox.path}${Platform.pathSeparator}paste.txt');
    await source.writeAsString('clipboard');

    final transferId = await sender.sendFiles([
      source.path,
    ], purpose: ExplicitFileTransferPurpose.clipboard);
    await _waitFor(
      () => receiver.tasks.any(
        (task) => task.id == transferId && task.awaitsAcceptance,
      ),
    );

    final incoming = receiver.tasks.singleWhere(
      (task) => task.id == transferId,
    );
    expect(incoming.isClipboard, isTrue);
    expect(incoming.message, '正在准备文件剪贴板');
  });

  test('resumes from a .cdrpart after transport reconnects', () async {
    var dataDelay = const Duration(milliseconds: 2);
    _connect(sender, receiver, dataDelay: () => dataDelay);
    await _waitFor(() => sender.transportReady && receiver.transportReady);
    final source = File('${sandbox.path}${Platform.pathSeparator}large.bin');
    final content = List<int>.generate(2 * 1024 * 1024, (index) => index % 239);
    await source.writeAsBytes(content);
    final destination = await Directory(
      '${sandbox.path}${Platform.pathSeparator}resume',
    ).create();

    await sender.sendFiles([source.path]);
    await _waitFor(() => receiver.pendingIncomingCount == 1);
    final transferId = receiver.tasks.singleWhere((task) => task.isIncoming).id;
    await receiver.accept(transferId, destination.path);
    await _waitFor(() {
      final progress = receiver.tasks.singleWhere(
        (task) => task.id == transferId,
      );
      return progress.transferredBytes > 400 * 1024 &&
          progress.transferredBytes < progress.totalBytes;
    });

    sender.detachTransport();
    receiver.detachTransport();
    await Future<void>.delayed(const Duration(milliseconds: 40));
    final partial = destination.listSync().whereType<File>().singleWhere(
      (file) => file.path.endsWith('.cdrpart'),
    );
    expect(await partial.length(), greaterThanOrEqualTo(256 * 1024));

    dataDelay = Duration.zero;
    _connect(sender, receiver, dataDelay: () => dataDelay);
    await _waitFor(() => sender.transportReady && receiver.transportReady);
    try {
      await _waitFor(
        () =>
            receiver.tasks.singleWhere((task) => task.id == transferId).state ==
            ExplicitFileTransferState.completed,
        timeout: const Duration(seconds: 10),
      );
    } on TimeoutException {
      fail(
        'sender=${sender.tasks.map((task) => '${task.state}:${task.transferredBytes}:${task.message}').join(',')} '
        'receiver=${receiver.tasks.map((task) => '${task.state}:${task.transferredBytes}:${task.message}').join(',')}',
      );
    }

    final landed = File(
      '${destination.path}${Platform.pathSeparator}large.bin',
    );
    expect(await landed.readAsBytes(), content);
  });

  test('preserves nested directories, empty files and unicode names', () async {
    _connect(sender, receiver);
    await _waitFor(() => sender.transportReady && receiver.transportReady);
    final sourceRoot = await Directory(
      '${sandbox.path}${Platform.pathSeparator}资料📁',
    ).create();
    await Directory('${sourceRoot.path}${Platform.pathSeparator}子目录').create();
    await File(
      '${sourceRoot.path}${Platform.pathSeparator}子目录'
      '${Platform.pathSeparator}空文件.txt',
    ).create();
    await File('${sourceRoot.path}${Platform.pathSeparator}报告🚀.txt')
        .writeAsString('你好 CrossDesktopRemote');
    final destination = await Directory(
      '${sandbox.path}${Platform.pathSeparator}directory-received',
    ).create();

    await sender.sendDirectory(sourceRoot.path);
    await _waitFor(() => receiver.pendingIncomingCount == 1);
    final transferId = receiver.tasks.singleWhere((task) => task.isIncoming).id;
    await receiver.accept(transferId, destination.path);
    await _waitFor(
      () =>
          receiver.tasks.singleWhere((task) => task.id == transferId).state ==
          ExplicitFileTransferState.completed,
    );

    final landedRoot = Directory(
      '${destination.path}${Platform.pathSeparator}资料📁',
    );
    expect(await landedRoot.exists(), isTrue);
    expect(
      await File('${landedRoot.path}${Platform.pathSeparator}报告🚀.txt')
          .readAsString(),
      '你好 CrossDesktopRemote',
    );
    expect(
      await File(
        '${landedRoot.path}${Platform.pathSeparator}子目录'
        '${Platform.pathSeparator}空文件.txt',
      ).length(),
      0,
    );
  });

  test('pauses without losing progress and resumes to completion', () async {
    _connect(
      sender,
      receiver,
      dataDelay: () => const Duration(milliseconds: 2),
    );
    await _waitFor(() => sender.transportReady && receiver.transportReady);
    final source = File('${sandbox.path}${Platform.pathSeparator}pause.bin');
    await source.writeAsBytes(
      List<int>.generate(1024 * 1024, (index) => index % 227),
    );
    final destination = await Directory(
      '${sandbox.path}${Platform.pathSeparator}pause-received',
    ).create();

    final transferId = await sender.sendFiles([source.path]);
    await _waitFor(() => receiver.pendingIncomingCount == 1);
    await receiver.accept(transferId, destination.path);
    await _waitFor(
      () =>
          sender.tasks
              .singleWhere((task) => task.id == transferId)
              .transferredBytes >
          128 * 1024,
    );
    await sender.pause(transferId);
    await _waitFor(
      () =>
          receiver.tasks.singleWhere((task) => task.id == transferId).state ==
          ExplicitFileTransferState.paused,
    );
    // Ordered SCTP may deliver the fragment already in flight when the pause
    // command arrives; after that bounded fragment drains, progress must stop.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final pausedBytes = receiver.tasks
        .singleWhere((task) => task.id == transferId)
        .transferredBytes;
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(
      receiver.tasks
          .singleWhere((task) => task.id == transferId)
          .transferredBytes,
      pausedBytes,
    );

    await receiver.resume(transferId);
    await _waitFor(
      () =>
          receiver.tasks.singleWhere((task) => task.id == transferId).state ==
          ExplicitFileTransferState.completed,
    );
    expect(
      await File('${destination.path}${Platform.pathSeparator}pause.bin')
          .length(),
      1024 * 1024,
    );
  });
}

void _connect(
  ExplicitFileTransferEngine left,
  ExplicitFileTransferEngine right, {
  Duration Function()? dataDelay,
}) {
  Future<void> attachLeft() async {
    left.attachTransport(
      sendControl: (message) async {
        right.handleControlMessage(jsonEncode(message));
      },
      sendBinary: (Uint8List bytes) async {
        final delay = dataDelay?.call() ?? Duration.zero;
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        right.handleBinaryMessage(Uint8List.fromList(bytes));
      },
      bufferedAmount: () async => 0,
    );
  }

  right.attachTransport(
    sendControl: (message) async {
      left.handleControlMessage(jsonEncode(message));
    },
    sendBinary: (Uint8List bytes) async {
      left.handleBinaryMessage(Uint8List.fromList(bytes));
    },
    bufferedAmount: () async => 0,
  );
  unawaited(attachLeft());
}

Future<void> _waitFor(
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not met', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
