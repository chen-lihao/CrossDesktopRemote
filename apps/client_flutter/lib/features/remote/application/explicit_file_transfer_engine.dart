import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_protocol.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';

typedef ExplicitFileTransferControlSender = Future<void> Function(
  Map<String, dynamic> message,
);
typedef ExplicitFileTransferBinarySender = Future<void> Function(
  Uint8List data,
);
typedef ExplicitFileTransferBufferedAmount = Future<int> Function();

class ExplicitFileTransferEngine extends ChangeNotifier {
  ExplicitFileTransferEngine();

  static const int _maxControlMessageBytes = 14 * 1024;
  static const int _highWaterBytes =
      explicitFileTransferWireMessageBytes *
      explicitFileTransferMaxInFlightFragments;

  final Map<String, _MutableTransferTask> _tasks = {};
  final Map<String, _IncomingManifestAssembly> _manifestAssemblies = {};
  final StreamController<String> _notices = StreamController<String>.broadcast(
    sync: true,
  );
  final Random _secureRandom = Random.secure();

  ExplicitFileTransferControlSender? _sendControlCallback;
  ExplicitFileTransferBinarySender? _sendBinaryCallback;
  ExplicitFileTransferBufferedAmount? _bufferedAmountCallback;
  Future<void> _incomingFrameTail = Future<void>.value();
  Future<void> _controlTail = Future<void>.value();
  bool _transportOpen = false;
  bool _remoteHelloReceived = false;
  bool _sendPumpRunning = false;
  bool _disposed = false;
  int _transportGeneration = 0;

  Stream<String> get notices => _notices.stream;
  bool get transportReady => _transportOpen && _remoteHelloReceived;

  List<ExplicitFileTransferTaskSnapshot> get tasks =>
      _tasks.values.map((task) => task.snapshot).toList(growable: false)
        ..sort((left, right) => right.createdAt.compareTo(left.createdAt));

  int get pendingIncomingCount => _tasks.values
      .where(
        (task) =>
            task.direction == ExplicitFileTransferDirection.incoming &&
            task.purpose == ExplicitFileTransferPurpose.explicit &&
            task.state == ExplicitFileTransferState.awaitingAcceptance,
      )
      .length;

  void attachTransport({
    required ExplicitFileTransferControlSender sendControl,
    required ExplicitFileTransferBinarySender sendBinary,
    required ExplicitFileTransferBufferedAmount bufferedAmount,
  }) {
    _sendControlCallback = sendControl;
    _sendBinaryCallback = sendBinary;
    _bufferedAmountCallback = bufferedAmount;
    _transportOpen = true;
    _remoteHelloReceived = false;
    _transportGeneration += 1;
    unawaited(_sendControl(_helloMessage));
    _notify();
  }

  void detachTransport({bool reconnecting = true}) {
    _transportOpen = false;
    _remoteHelloReceived = false;
    _sendControlCallback = null;
    _sendBinaryCallback = null;
    _bufferedAmountCallback = null;
    _transportGeneration += 1;
    for (final task in _tasks.values) {
      if (reconnecting &&
          (task.state == ExplicitFileTransferState.transferring ||
              task.state == ExplicitFileTransferState.verifying ||
              task.state == ExplicitFileTransferState.offered)) {
        task.state = ExplicitFileTransferState.reconnecting;
        task.message = '网络中断，连接恢复后将继续传输';
      }
      unawaited(_closeReceiveHandles(task));
    }
    _notify();
  }

  Future<String> sendFiles(
    List<String> paths, {
    ExplicitFileTransferPurpose purpose = ExplicitFileTransferPurpose.explicit,
  }) async {
    if (paths.isEmpty) throw ArgumentError.value(paths, 'paths', '未选择文件');
    return _prepareAndOffer(
      paths,
      includeDirectories: purpose == ExplicitFileTransferPurpose.clipboard,
      purpose: purpose,
    );
  }

  Future<String> sendDirectory(String path) async => _prepareAndOffer(
    [path],
    includeDirectories: true,
    purpose: ExplicitFileTransferPurpose.explicit,
  );

  Future<String> _prepareAndOffer(
    List<String> paths, {
    required bool includeDirectories,
    required ExplicitFileTransferPurpose purpose,
  }) async {
    if (!transportReady) {
      throw StateError('远程设备尚未就绪或不支持文件传输');
    }
    final id = _newTransferId();
    final task = _MutableTransferTask(
      id: id,
      direction: ExplicitFileTransferDirection.outgoing,
      state: ExplicitFileTransferState.preparing,
      createdAt: DateTime.now(),
      purpose: purpose,
      message: '正在读取文件信息并计算 SHA-256',
    );
    _tasks[id] = task;
    _notify();
    try {
      final entries = await _buildOutgoingEntries(
        paths,
        includeDirectories: includeDirectories,
      );
      final total = entries.fold<int>(0, (sum, entry) => sum + entry.sizeBytes);
      validateExplicitFileTransferManifest(entries, declaredTotalBytes: total);
      task
        ..entries = entries
        ..totalBytes = total
        ..state = ExplicitFileTransferState.offered
        ..message = '已发送文件清单，等待对方确认';
      await _sendOffer(task);
      _notify();
      return id;
    } catch (error) {
      task
        ..state = ExplicitFileTransferState.failed
        ..message = '准备传输失败：$error';
      _notice(task.message!);
      _notify();
      rethrow;
    }
  }

  Future<void> accept(String transferId, String destinationRoot) async {
    final task = _requireTask(transferId);
    if (task.direction != ExplicitFileTransferDirection.incoming ||
        task.state != ExplicitFileTransferState.awaitingAcceptance) {
      throw StateError('传输任务当前不能接受');
    }
    try {
      await _prepareReceiveDestination(task, destinationRoot);
      task
        ..state = ExplicitFileTransferState.transferring
        ..message = '已接受，正在等待文件数据';
      await _sendControl({
        'type': 'decision',
        'version': explicitFileTransferWireVersion,
        'transferId': task.id,
        'accepted': true,
      });
      await _sendResumeState(task);
      await _completeEmptyFiles(task);
      _notify();
    } catch (error) {
      task
        ..state = ExplicitFileTransferState.failed
        ..message = '准备接收目录失败：$error';
      await _sendTransferError(task, task.message!);
      _notify();
      rethrow;
    }
  }

  Future<void> reject(String transferId) async {
    final task = _requireTask(transferId);
    if (task.direction != ExplicitFileTransferDirection.incoming ||
        task.state != ExplicitFileTransferState.awaitingAcceptance) {
      return;
    }
    task
      ..state = ExplicitFileTransferState.rejected
      ..message = '已拒绝接收';
    await _sendControl({
      'type': 'decision',
      'version': explicitFileTransferWireVersion,
      'transferId': task.id,
      'accepted': false,
    });
    _notify();
  }

  Future<void> pause(String transferId) async {
    final task = _requireTask(transferId);
    if (task.state != ExplicitFileTransferState.transferring) return;
    task
      ..state = ExplicitFileTransferState.paused
      ..message = '已暂停';
    await _sendCommand(task.id, 'pause');
    _notify();
  }

  Future<void> resume(String transferId) async {
    final task = _requireTask(transferId);
    if (task.state != ExplicitFileTransferState.paused &&
        task.state != ExplicitFileTransferState.reconnecting) {
      return;
    }
    if (!transportReady) {
      task
        ..state = ExplicitFileTransferState.reconnecting
        ..message = '等待远程会话恢复';
      _notify();
      return;
    }
    task
      ..state = ExplicitFileTransferState.transferring
      ..message = '正在恢复传输';
    await _sendCommand(task.id, 'resume');
    if (task.direction == ExplicitFileTransferDirection.incoming) {
      await _sendResumeState(task);
    } else {
      task.resumeEntriesReceived.clear();
      task.remoteCompletedBlocks.clear();
    }
    _notify();
  }

  Future<void> cancel(String transferId) async {
    final task = _requireTask(transferId);
    if (task.snapshot.canCancel == false) return;
    task
      ..state = ExplicitFileTransferState.cancelled
      ..message = '已取消';
    await _sendCommand(task.id, 'cancel');
    await _discardReceivePartials(task);
    _notify();
  }

  void handleControlMessage(String payload) {
    _controlTail = _controlTail.then((_) => _processControlMessage(payload));
  }

  void handleBinaryMessage(Uint8List payload) {
    _incomingFrameTail = _incomingFrameTail.then(
      (_) => _processBinaryMessage(payload),
    );
  }

  Future<void> _processControlMessage(String payload) async {
    try {
      if (utf8.encode(payload).length > explicitFileTransferWireMessageBytes) {
        throw const FormatException('文件传输控制消息过大');
      }
      final decoded = jsonDecode(payload);
      if (decoded is! Map<String, dynamic> ||
          decoded['version'] != explicitFileTransferWireVersion) {
        return;
      }
      switch (decoded['type']) {
        case 'hello':
          await _handleHello(decoded);
        case 'offer-start':
          _handleOfferStart(decoded);
        case 'manifest':
          _handleManifest(decoded);
        case 'offer-end':
          await _handleOfferEnd(decoded);
        case 'decision':
          await _handleDecision(decoded);
        case 'resume':
          await _handleResume(decoded);
        case 'command':
          await _handleCommand(decoded);
        case 'completed':
          _handleCompleted(decoded);
        case 'error':
          _handleRemoteError(decoded);
      }
    } on FormatException catch (error) {
      _notice('文件传输协议数据无效：${error.message}');
    } catch (error) {
      _notice('文件传输控制处理失败：$error');
    }
  }

  Future<void> _handleHello(Map<String, dynamic> message) async {
    if (message['maxWireFragmentBytes'] !=
            explicitFileTransferWireMessageBytes ||
        message['logicalBlockBytes'] != explicitFileTransferLogicalBlockBytes ||
        message['supportsResume'] != true ||
        message['supportsSha256'] != true) {
      _remoteHelloReceived = false;
      _notice('远程文件传输能力不兼容');
      _notify();
      return;
    }
    final shouldAcknowledge = !_remoteHelloReceived;
    _remoteHelloReceived = true;
    if (shouldAcknowledge) {
      await _sendControl(_helloMessage);
    }
    for (final task in _tasks.values) {
      if (task.direction == ExplicitFileTransferDirection.outgoing &&
          (task.state == ExplicitFileTransferState.reconnecting ||
              task.state == ExplicitFileTransferState.offered ||
              task.state == ExplicitFileTransferState.transferring ||
              task.state == ExplicitFileTransferState.verifying)) {
        task
          ..state = ExplicitFileTransferState.reconnecting
          ..message = '已重连，正在协商断点';
        await _sendOffer(task);
      }
    }
    _notify();
  }

  void _handleOfferStart(Map<String, dynamic> message) {
    final id = _readTransferId(message);
    final entryCount = _readPositiveInt(
      message['entryCount'],
      allowZero: false,
    );
    final totalBytes = _readPositiveInt(message['totalBytes'], allowZero: true);
    if (entryCount > explicitFileTransferMaxEntries) {
      throw const FormatException('文件清单项数超出限制');
    }
    _manifestAssemblies[id] = _IncomingManifestAssembly(
      transferId: id,
      entryCount: entryCount,
      totalBytes: totalBytes,
      purpose: ExplicitFileTransferPurpose.fromWire(message['purpose']),
    );
  }

  void _handleManifest(Map<String, dynamic> message) {
    final id = _readTransferId(message);
    final assembly = _manifestAssemblies[id];
    if (assembly == null) throw const FormatException('未知的文件清单');
    final sequence = _readPositiveInt(message['sequence'], allowZero: true);
    if (sequence != assembly.nextSequence) {
      throw const FormatException('文件清单分段顺序无效');
    }
    final rawEntries = message['entries'];
    if (rawEntries is! List<dynamic> || rawEntries.isEmpty) {
      throw const FormatException('文件清单分段为空');
    }
    for (final value in rawEntries) {
      if (value is! Map) throw const FormatException('文件清单项无效');
      assembly.entries.add(
        ExplicitFileTransferEntry.fromMessage(
          value.map((key, item) => MapEntry(key.toString(), item)),
        ),
      );
    }
    if (assembly.entries.length > assembly.entryCount) {
      throw const FormatException('文件清单项数超出声明');
    }
    assembly.nextSequence += 1;
  }

  Future<void> _handleOfferEnd(Map<String, dynamic> message) async {
    final id = _readTransferId(message);
    final assembly = _manifestAssemblies.remove(id);
    if (assembly == null || assembly.entries.length != assembly.entryCount) {
      throw const FormatException('文件清单不完整');
    }
    validateExplicitFileTransferManifest(
      assembly.entries,
      declaredTotalBytes: assembly.totalBytes,
    );
    final existing = _tasks[id];
    if (existing != null) {
      if (existing.direction != ExplicitFileTransferDirection.incoming ||
          existing.purpose != assembly.purpose ||
          !_sameManifest(existing, assembly)) {
        await _sendTransferError(existing, '重连后文件清单发生变化');
        return;
      }
      if (existing.destinationRoot != null &&
          existing.state != ExplicitFileTransferState.cancelled &&
          existing.state != ExplicitFileTransferState.rejected) {
        existing
          ..state = ExplicitFileTransferState.transferring
          ..message = '会话已恢复，正在继续接收';
        await _sendControl({
          'type': 'decision',
          'version': explicitFileTransferWireVersion,
          'transferId': id,
          'accepted': true,
        });
        await _finalizeCompletePartials(existing);
        if (existing.state == ExplicitFileTransferState.completed) {
          await _sendCompleted(existing);
          _notify();
          return;
        }
        await _sendResumeState(existing);
      }
      _notify();
      return;
    }
    _tasks[id] = _MutableTransferTask(
      id: id,
      direction: ExplicitFileTransferDirection.incoming,
      state: ExplicitFileTransferState.awaitingAcceptance,
      createdAt: DateTime.now(),
      purpose: assembly.purpose,
      entries: List.unmodifiable(assembly.entries),
      totalBytes: assembly.totalBytes,
      message: assembly.purpose == ExplicitFileTransferPurpose.clipboard
          ? '正在准备文件剪贴板'
          : '请选择接收目录并确认',
    );
    if (assembly.purpose == ExplicitFileTransferPurpose.explicit) {
      _notice('收到文件传输请求');
    }
    _notify();
  }

  Future<void> _handleDecision(Map<String, dynamic> message) async {
    final task = _tasks[_readTransferId(message)];
    if (task == null ||
        task.direction != ExplicitFileTransferDirection.outgoing) {
      return;
    }
    if (message['accepted'] != true) {
      task
        ..state = ExplicitFileTransferState.rejected
        ..message = '对方已拒绝接收';
      _notify();
      return;
    }
    task
      ..state = ExplicitFileTransferState.transferring
      ..message = '对方已接受，正在协商断点';
    _notify();
  }

  Future<void> _handleResume(Map<String, dynamic> message) async {
    final task = _tasks[_readTransferId(message)];
    if (task == null ||
        task.direction != ExplicitFileTransferDirection.outgoing) {
      return;
    }
    final entryIndex = _readPositiveInt(message['entryIndex'], allowZero: true);
    if (entryIndex >= task.entries.length || !task.entries[entryIndex].isFile) {
      throw const FormatException('恢复位图文件索引无效');
    }
    final entry = task.entries[entryIndex];
    final blockBytes = _readPositiveInt(
      message['blockBytes'],
      allowZero: false,
    );
    if (blockBytes != explicitFileTransferLogicalBlockBytes) {
      throw const FormatException('恢复位图块大小不兼容');
    }
    final encoded = message['completedBlocks'];
    if (encoded is! String) throw const FormatException('恢复位图无效');
    final blockCount = _blockCount(entry.sizeBytes);
    task.remoteCompletedBlocks[entryIndex] = decodeResumeBitmap(
      encoded,
      blockCount,
    );
    task.resumeEntriesReceived.add(entryIndex);
    if (task.resumeEntriesReceived.length ==
        task.entries.where((entry) => entry.isFile).length) {
      task
        ..state = ExplicitFileTransferState.transferring
        ..transferredBytes = _completedBytesFromResume(task)
        ..message = '正在传输';
      _notify();
      unawaited(_pumpOutgoing());
    }
  }

  Future<void> _handleCommand(Map<String, dynamic> message) async {
    final task = _tasks[_readTransferId(message)];
    if (task == null) return;
    switch (message['command']) {
      case 'pause':
        if (task.state == ExplicitFileTransferState.transferring) {
          task
            ..state = ExplicitFileTransferState.paused
            ..message = '对方已暂停传输';
        }
      case 'resume':
        if (task.state == ExplicitFileTransferState.paused ||
            task.state == ExplicitFileTransferState.reconnecting) {
          task
            ..state = ExplicitFileTransferState.transferring
            ..message = '正在恢复传输';
          if (task.direction == ExplicitFileTransferDirection.incoming) {
            await _sendResumeState(task);
          } else {
            task.resumeEntriesReceived.clear();
            task.remoteCompletedBlocks.clear();
          }
        }
      case 'cancel':
        task
          ..state = ExplicitFileTransferState.cancelled
          ..message = '对方已取消传输';
        await _discardReceivePartials(task);
    }
    _notify();
  }

  void _handleCompleted(Map<String, dynamic> message) {
    final task = _tasks[_readTransferId(message)];
    if (task == null) return;
    task
      ..state = ExplicitFileTransferState.completed
      ..transferredBytes = task.totalBytes
      ..message = '文件传输完成';
    _notice('文件传输已完成');
    _notify();
  }

  void _handleRemoteError(Map<String, dynamic> message) {
    final task = _tasks[_readTransferId(message)];
    if (task == null) return;
    task
      ..state = ExplicitFileTransferState.failed
      ..message = message['message'] is String
          ? '远程传输失败：${message['message']}'
          : '远程传输失败';
    _notice(task.message!);
    _notify();
  }

  Future<void> _processBinaryMessage(Uint8List payload) async {
    _MutableTransferTask? activeTask;
    try {
      final frame = decodeExplicitFileTransferFrame(payload);
      final task = _tasks[frame.transferId];
      if (task == null ||
          task.direction != ExplicitFileTransferDirection.incoming ||
          task.destinationRoot == null ||
          task.state != ExplicitFileTransferState.transferring) {
        return;
      }
      activeTask = task;
      if (frame.entryIndex >= task.entries.length) {
        throw const FormatException('文件分片索引无效');
      }
      final entry = task.entries[frame.entryIndex];
      if (!entry.isFile) throw const FormatException('目录不能接收数据分片');
      final receive = task.receiveEntries[entry.index];
      if (receive == null || receive.finalized) return;
      final file = File(receive.partialPath);
      final currentLength = await file.exists() ? await file.length() : 0;
      if (frame.offset < currentLength) return;
      if (frame.offset != currentLength ||
          frame.offset + frame.payload.length > entry.sizeBytes) {
        throw const FormatException('文件分片偏移不连续');
      }
      final handle = receive.handle ??= await file.open(mode: FileMode.append);
      if (frame.payload.isNotEmpty) {
        await handle.writeFrom(frame.payload);
        task.transferredBytes += frame.payload.length;
      }
      if (frame.endOfEntry) {
        await handle.flush();
        await handle.close();
        receive.handle = null;
        if (frame.offset + frame.payload.length != entry.sizeBytes) {
          throw const FormatException('文件结束分片大小不匹配');
        }
        await _verifyAndFinalizeEntry(task, entry, receive);
      }
      _notify();
    } on FormatException catch (error) {
      await _failIncomingFrame(activeTask, error.message);
    } catch (error) {
      await _failIncomingFrame(activeTask, error.toString());
    }
  }

  Future<void> _failIncomingFrame(
    _MutableTransferTask? task,
    String message,
  ) async {
    if (task != null) {
      task
        ..state = ExplicitFileTransferState.failed
        ..message = '接收文件失败：$message';
      await _closeReceiveHandles(task);
      await _sendTransferError(task, task.message!);
    }
    _notice('接收文件分片失败：$message');
    _notify();
  }

  Future<void> _pumpOutgoing() async {
    if (_sendPumpRunning || !transportReady) return;
    _sendPumpRunning = true;
    final generation = _transportGeneration;
    try {
      while (_transportOpen && generation == _transportGeneration) {
        final task = _tasks.values.cast<_MutableTransferTask?>().firstWhere(
          (candidate) =>
              candidate?.direction == ExplicitFileTransferDirection.outgoing &&
              candidate?.state == ExplicitFileTransferState.transferring &&
              candidate!.resumeEntriesReceived.length ==
                  candidate.entries.where((entry) => entry.isFile).length,
          orElse: () => null,
        );
        if (task == null) break;
        await _sendTaskData(task, generation);
        if (task.state == ExplicitFileTransferState.transferring) {
          task
            ..state = ExplicitFileTransferState.verifying
            ..message = '已发送全部数据，等待对方校验';
          _notify();
        }
      }
    } catch (error) {
      if (_transportOpen && generation == _transportGeneration) {
        _notice('发送文件失败：$error');
      }
    } finally {
      _sendPumpRunning = false;
      if (transportReady && _hasSendableOutgoingTask) {
        unawaited(_pumpOutgoing());
      }
    }
  }

  bool get _hasSendableOutgoingTask => _tasks.values.any(
    (task) =>
        task.direction == ExplicitFileTransferDirection.outgoing &&
        task.state == ExplicitFileTransferState.transferring &&
        task.resumeEntriesReceived.length ==
            task.entries.where((entry) => entry.isFile).length,
  );

  Future<void> _sendTaskData(_MutableTransferTask task, int generation) async {
    for (final entry in task.entries.where((entry) => entry.isFile)) {
      if (!_canContinueSending(task, generation)) return;
      final sourcePath = entry.sourcePath;
      if (sourcePath == null) throw StateError('发送文件路径已丢失');
      final completed = task.remoteCompletedBlocks[entry.index] ?? <int>{};
      final resumeOffset = _contiguousCompletedBytes(
        entry.sizeBytes,
        completed,
      );
      final file = File(sourcePath);
      if (!await file.exists() || await file.length() != entry.sizeBytes) {
        await _failOutgoingTask(task, '源文件在传输前已发生变化');
        return;
      }
      final handle = await file.open();
      try {
        await handle.setPosition(resumeOffset);
        var offset = resumeOffset;
        if (entry.sizeBytes == 0) {
          await _sendDataFrame(
            ExplicitFileTransferFrame(
              transferId: task.id,
              entryIndex: entry.index,
              offset: 0,
              payload: Uint8List(0),
              endOfEntry: true,
            ),
            task,
            generation,
          );
          continue;
        }
        while (offset < entry.sizeBytes &&
            _canContinueSending(task, generation)) {
          final wanted = min(
            explicitFileTransferPayloadBytes,
            entry.sizeBytes - offset,
          );
          final bytes = await handle.read(wanted);
          if (bytes.length != wanted) {
            await _failOutgoingTask(task, '读取源文件时提前到达末尾');
            return;
          }
          final sent = await _sendDataFrame(
            ExplicitFileTransferFrame(
              transferId: task.id,
              entryIndex: entry.index,
              offset: offset,
              payload: Uint8List.fromList(bytes),
              endOfEntry: offset + bytes.length == entry.sizeBytes,
            ),
            task,
            generation,
          );
          if (!sent) return;
          offset += bytes.length;
          task.transferredBytes = min(
            task.totalBytes,
            task.transferredBytes + bytes.length,
          );
          _notify();
        }
      } finally {
        await handle.close();
      }
    }
  }

  Future<bool> _sendDataFrame(
    ExplicitFileTransferFrame frame,
    _MutableTransferTask task,
    int generation,
  ) async {
    while (_canContinueSending(task, generation)) {
      final buffered = await _bufferedAmountCallback?.call() ?? 0;
      if (buffered < _highWaterBytes) break;
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    if (!_canContinueSending(task, generation)) return false;
    final sender = _sendBinaryCallback;
    if (sender == null) throw StateError('文件数据通道已关闭');
    await sender(encodeExplicitFileTransferFrame(frame));
    return true;
  }

  bool _canContinueSending(_MutableTransferTask task, int generation) =>
      _transportOpen &&
      generation == _transportGeneration &&
      task.state == ExplicitFileTransferState.transferring;

  Future<void> _verifyAndFinalizeEntry(
    _MutableTransferTask task,
    ExplicitFileTransferEntry entry,
    _ReceiveEntry receive,
  ) async {
    task
      ..state = ExplicitFileTransferState.verifying
      ..message = '正在校验 ${entry.relativePath}';
    _notify();
    final digest = await _sha256File(File(receive.partialPath));
    if (digest != entry.sha256Hex) {
      task
        ..state = ExplicitFileTransferState.failed
        ..message = 'SHA-256 校验失败：${entry.relativePath}';
      await _sendTransferError(task, task.message!);
      _notice(task.message!);
      _notify();
      return;
    }
    final partial = File(receive.partialPath);
    final destination = File(receive.destinationPath);
    if (await destination.exists()) {
      throw StateError('目标文件在传输期间已被占用');
    }
    await partial.rename(destination.path);
    if (entry.modifiedAtUnixMs > 0) {
      await destination.setLastModified(
        DateTime.fromMillisecondsSinceEpoch(entry.modifiedAtUnixMs),
      );
    }
    receive.finalized = true;
    task
      ..state = ExplicitFileTransferState.transferring
      ..message = '正在接收';
    if (task.receiveEntries.values.every((value) => value.finalized)) {
      task
        ..state = ExplicitFileTransferState.completed
        ..transferredBytes = task.totalBytes
        ..message = '文件传输完成';
      await _sendCompleted(task);
      _notice('文件已保存到 ${task.destinationRoot}');
    }
    _notify();
  }

  Future<void> _completeEmptyFiles(_MutableTransferTask task) async {
    if (task.entries.any((entry) => entry.isFile)) return;
    task
      ..state = ExplicitFileTransferState.completed
      ..message = '空目录传输完成';
    await _sendCompleted(task);
    _notice('目录已保存到 ${task.destinationRoot}');
  }

  Future<void> _finalizeCompletePartials(_MutableTransferTask task) async {
    for (final entry in task.entries.where((entry) => entry.isFile)) {
      if (entry.sizeBytes == 0) continue;
      final receive = task.receiveEntries[entry.index];
      if (receive == null || receive.finalized) continue;
      final partial = File(receive.partialPath);
      if (await partial.exists() && await partial.length() == entry.sizeBytes) {
        await _verifyAndFinalizeEntry(task, entry, receive);
        if (task.state == ExplicitFileTransferState.failed) return;
      }
    }
  }

  Future<void> _sendCompleted(_MutableTransferTask task) => _sendControl({
    'type': 'completed',
    'version': explicitFileTransferWireVersion,
    'transferId': task.id,
  });

  Future<List<ExplicitFileTransferEntry>> _buildOutgoingEntries(
    List<String> selectedPaths, {
    required bool includeDirectories,
  }) async {
    final pending = <_PendingEntry>[];
    final topLevelNames = <String>{};
    for (final selectedPath in selectedPaths) {
      final type = await FileSystemEntity.type(
        selectedPath,
        followLinks: false,
      );
      if (type == FileSystemEntityType.link) {
        throw const FileSystemException('不允许发送符号链接');
      }
      final name = _basename(selectedPath);
      if (!topLevelNames.add(name)) {
        throw FileSystemException('选择内容包含同名顶层项', name);
      }
      if (type == FileSystemEntityType.file) {
        pending.add(_PendingEntry(path: selectedPath, relativePath: name));
      } else if (type == FileSystemEntityType.directory && includeDirectories) {
        pending.add(
          _PendingEntry(
            path: selectedPath,
            relativePath: name,
            isDirectory: true,
          ),
        );
        final root = Directory(selectedPath);
        await for (final entity in root.list(
          recursive: true,
          followLinks: false,
        )) {
          final entityType = await FileSystemEntity.type(
            entity.path,
            followLinks: false,
          );
          if (entityType == FileSystemEntityType.link) {
            throw FileSystemException('目录中包含符号链接', entity.path);
          }
          final suffix = _relativeSuffix(selectedPath, entity.path);
          pending.add(
            _PendingEntry(
              path: entity.path,
              relativePath: '$name/$suffix',
              isDirectory: entityType == FileSystemEntityType.directory,
            ),
          );
        }
      } else {
        throw FileSystemException('选择的路径不是可读文件或目录', selectedPath);
      }
    }
    pending.sort((left, right) {
      final depth = left.relativePath
          .split('/')
          .length
          .compareTo(right.relativePath.split('/').length);
      return depth != 0
          ? depth
          : left.relativePath.compareTo(right.relativePath);
    });
    if (pending.length > explicitFileTransferMaxEntries) {
      throw const FileSystemException('目录内文件数超出 10000 项限制');
    }
    final result = <ExplicitFileTransferEntry>[];
    for (final item in pending) {
      validateExplicitFileTransferRelativePath(item.relativePath);
      if (item.isDirectory) {
        result.add(
          ExplicitFileTransferEntry(
            index: result.length,
            relativePath: item.relativePath,
            kind: ExplicitFileEntryKind.directory,
            sizeBytes: 0,
            modifiedAtUnixMs: 0,
            sha256Hex: '',
            sourcePath: item.path,
          ),
        );
        continue;
      }
      final file = File(item.path);
      final stat = await file.stat();
      final digest = await _sha256File(file);
      result.add(
        ExplicitFileTransferEntry(
          index: result.length,
          relativePath: item.relativePath,
          kind: ExplicitFileEntryKind.file,
          sizeBytes: stat.size,
          modifiedAtUnixMs: stat.modified.millisecondsSinceEpoch,
          sha256Hex: digest,
          sourcePath: item.path,
        ),
      );
      _notify();
    }
    return result;
  }

  Future<void> _prepareReceiveDestination(
    _MutableTransferTask task,
    String destinationRoot,
  ) async {
    final requestedRoot = Directory(destinationRoot);
    if (!await requestedRoot.exists()) {
      throw FileSystemException('接收目录不存在', destinationRoot);
    }
    final canonicalRoot = await requestedRoot.resolveSymbolicLinks();
    final root = Directory(canonicalRoot);
    final topLevelMap = <String, String>{};
    for (final entry in task.entries) {
      final original = entry.relativePath.split('/').first;
      if (topLevelMap.containsKey(original)) continue;
      topLevelMap[original] = await _availableTopLevelName(root, original);
    }
    for (final entry in task.entries) {
      final components = entry.relativePath.split('/');
      components[0] = topLevelMap[components.first]!;
      final destination = _joinPath(canonicalRoot, components);
      await _rejectSymlinkAncestors(canonicalRoot, components);
      if (entry.kind == ExplicitFileEntryKind.directory) {
        await Directory(destination).create(recursive: true);
        continue;
      }
      await Directory(_dirname(destination)).create(recursive: true);
      final partial = '$destination.${task.id}.cdrpart';
      final partialFile = File(partial);
      if (!await partialFile.exists()) {
        await partialFile.create(exclusive: true);
      }
      var length = await partialFile.length();
      if (length > entry.sizeBytes) {
        await partialFile.writeAsBytes(const [], flush: true);
        length = 0;
      }
      final completePrefix = entry.sizeBytes == length
          ? length
          : (length ~/ explicitFileTransferLogicalBlockBytes) *
                explicitFileTransferLogicalBlockBytes;
      if (completePrefix != length) {
        final handle = await partialFile.open(mode: FileMode.writeOnlyAppend);
        await handle.truncate(completePrefix);
        await handle.close();
      }
      task.receiveEntries[entry.index] = _ReceiveEntry(
        destinationPath: destination,
        partialPath: partial,
      );
    }
    task
      ..destinationRoot = canonicalRoot
      ..transferredBytes = await _receivedBytes(task);
  }

  Future<void> _sendResumeState(_MutableTransferTask task) async {
    await _closeReceiveHandles(task);
    for (final entry in task.entries.where((entry) => entry.isFile)) {
      final receive = task.receiveEntries[entry.index];
      if (receive == null) {
        continue;
      }
      final partial = File(receive.partialPath);
      var length = receive.finalized
          ? entry.sizeBytes
          : await partial.exists()
          ? await partial.length()
          : 0;
      if (!receive.finalized && length < entry.sizeBytes) {
        final resumableLength =
            (length ~/ explicitFileTransferLogicalBlockBytes) *
            explicitFileTransferLogicalBlockBytes;
        if (resumableLength != length) {
          final handle = await partial.open(mode: FileMode.writeOnlyAppend);
          await handle.truncate(resumableLength);
          await handle.close();
          length = resumableLength;
        }
      }
      final blocks = <int>{
        for (
          var block = 0;
          block < length ~/ explicitFileTransferLogicalBlockBytes;
          block++
        )
          block,
        if (length == entry.sizeBytes && entry.sizeBytes > 0)
          _blockCount(entry.sizeBytes) - 1,
      };
      await _sendControl({
        'type': 'resume',
        'version': explicitFileTransferWireVersion,
        'transferId': task.id,
        'entryIndex': entry.index,
        'blockBytes': explicitFileTransferLogicalBlockBytes,
        'completedBlocks': encodeResumeBitmap(
          blocks,
          _blockCount(entry.sizeBytes),
        ),
      });
    }
    task.transferredBytes = await _receivedBytes(task);
    _notify();
  }

  Future<void> _sendOffer(_MutableTransferTask task) async {
    if (!transportReady || task.entries.isEmpty) return;
    task.resumeEntriesReceived.clear();
    task.remoteCompletedBlocks.clear();
    await _sendControl({
      'type': 'offer-start',
      'version': explicitFileTransferWireVersion,
      'transferId': task.id,
      'entryCount': task.entries.length,
      'totalBytes': task.totalBytes,
      'purpose': task.purpose.wireName,
    });
    var sequence = 0;
    var batch = <Map<String, dynamic>>[];
    for (final entry in task.entries) {
      final encoded = entry.toMessage();
      final candidate = [...batch, encoded];
      final message = {
        'type': 'manifest',
        'version': explicitFileTransferWireVersion,
        'transferId': task.id,
        'sequence': sequence,
        'entries': candidate,
      };
      if (batch.isNotEmpty &&
          utf8.encode(jsonEncode(message)).length > _maxControlMessageBytes) {
        await _sendManifestBatch(task.id, sequence, batch);
        sequence += 1;
        batch = [encoded];
      } else {
        batch = candidate;
      }
    }
    if (batch.isNotEmpty) await _sendManifestBatch(task.id, sequence, batch);
    await _sendControl({
      'type': 'offer-end',
      'version': explicitFileTransferWireVersion,
      'transferId': task.id,
    });
  }

  Future<void> _sendManifestBatch(
    String transferId,
    int sequence,
    List<Map<String, dynamic>> entries,
  ) => _sendControl({
    'type': 'manifest',
    'version': explicitFileTransferWireVersion,
    'transferId': transferId,
    'sequence': sequence,
    'entries': entries,
  });

  Future<void> _sendCommand(String transferId, String command) => _sendControl({
    'type': 'command',
    'version': explicitFileTransferWireVersion,
    'transferId': transferId,
    'command': command,
  });

  Future<void> _sendTransferError(_MutableTransferTask task, String message) =>
      _sendControl({
        'type': 'error',
        'version': explicitFileTransferWireVersion,
        'transferId': task.id,
        'message': message,
      });

  Future<void> _sendControl(Map<String, dynamic> message) async {
    final sender = _sendControlCallback;
    if (!_transportOpen || sender == null) return;
    final encoded = jsonEncode(message);
    if (utf8.encode(encoded).length > explicitFileTransferWireMessageBytes) {
      throw StateError('文件传输控制消息超出 16 KiB');
    }
    await sender(message);
  }

  Map<String, dynamic> get _helloMessage => {
    'type': 'hello',
    'version': explicitFileTransferWireVersion,
    'maxWireFragmentBytes': explicitFileTransferWireMessageBytes,
    'logicalBlockBytes': explicitFileTransferLogicalBlockBytes,
    'maxInFlightFragments': explicitFileTransferMaxInFlightFragments,
    'supportsResume': true,
    'supportsSha256': true,
  };

  Future<void> _failOutgoingTask(
    _MutableTransferTask task,
    String message,
  ) async {
    task
      ..state = ExplicitFileTransferState.failed
      ..message = message;
    await _sendTransferError(task, message);
    _notice(message);
    _notify();
  }

  Future<void> _discardReceivePartials(_MutableTransferTask task) async {
    await _closeReceiveHandles(task);
    for (final receive in task.receiveEntries.values) {
      if (receive.finalized) continue;
      final partial = File(receive.partialPath);
      if (await partial.exists()) await partial.delete();
    }
  }

  Future<void> _closeReceiveHandles(_MutableTransferTask task) async {
    for (final receive in task.receiveEntries.values) {
      final handle = receive.handle;
      receive.handle = null;
      if (handle != null) {
        try {
          await handle.flush();
          await handle.close();
        } catch (_) {
          // A closing DataChannel may race a file write; the .cdrpart stays.
        }
      }
    }
  }

  Future<int> _receivedBytes(_MutableTransferTask task) async {
    var total = 0;
    for (final entry in task.entries.where((entry) => entry.isFile)) {
      final receive = task.receiveEntries[entry.index];
      if (receive == null) {
        continue;
      }
      if (receive.finalized) {
        total += entry.sizeBytes;
      } else {
        final file = File(receive.partialPath);
        if (await file.exists()) {
          total += min(entry.sizeBytes, await file.length());
        }
      }
    }
    return total;
  }

  int _completedBytesFromResume(_MutableTransferTask task) {
    var total = 0;
    for (final entry in task.entries.where((entry) => entry.isFile)) {
      total += _contiguousCompletedBytes(
        entry.sizeBytes,
        task.remoteCompletedBlocks[entry.index] ?? const <int>{},
      );
    }
    return total;
  }

  int _contiguousCompletedBytes(int totalBytes, Set<int> blocks) {
    var block = 0;
    while (blocks.contains(block)) {
      block += 1;
    }
    return min(totalBytes, block * explicitFileTransferLogicalBlockBytes);
  }

  int _blockCount(int totalBytes) =>
      (totalBytes + explicitFileTransferLogicalBlockBytes - 1) ~/
      explicitFileTransferLogicalBlockBytes;

  Future<String> _sha256File(File file) async {
    final path = file.path;
    return Isolate.run(() => _sha256Path(path));
  }

  Future<String> _availableTopLevelName(Directory root, String original) async {
    if (!await FileSystemEntity.type(
      _joinPath(root.path, [original]),
      followLinks: false,
    ).then((type) => type != FileSystemEntityType.notFound)) {
      return original;
    }
    final extensionIndex = original.lastIndexOf('.');
    final hasExtension =
        extensionIndex > 0 && extensionIndex < original.length - 1;
    final stem = hasExtension
        ? original.substring(0, extensionIndex)
        : original;
    final extension = hasExtension ? original.substring(extensionIndex) : '';
    for (var suffix = 1; suffix < 10000; suffix++) {
      final candidate = '$stem ($suffix)$extension';
      final type = await FileSystemEntity.type(
        _joinPath(root.path, [candidate]),
        followLinks: false,
      );
      if (type == FileSystemEntityType.notFound) return candidate;
    }
    throw FileSystemException('无法为接收文件生成不冲突的名称', original);
  }

  Future<void> _rejectSymlinkAncestors(
    String root,
    List<String> components,
  ) async {
    var current = root;
    for (final component in components.take(components.length - 1)) {
      current = _joinPath(current, [component]);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw FileSystemException('接收路径包含符号链接', current);
      }
    }
  }

  bool _sameManifest(
    _MutableTransferTask task,
    _IncomingManifestAssembly assembly,
  ) {
    if (task.totalBytes != assembly.totalBytes ||
        task.entries.length != assembly.entries.length) {
      return false;
    }
    for (var index = 0; index < task.entries.length; index++) {
      final left = task.entries[index];
      final right = assembly.entries[index];
      if (left.relativePath != right.relativePath ||
          left.kind != right.kind ||
          left.sizeBytes != right.sizeBytes ||
          left.sha256Hex != right.sha256Hex) {
        return false;
      }
    }
    return true;
  }

  _MutableTransferTask _requireTask(String id) {
    final task = _tasks[id];
    if (task == null) throw StateError('文件传输任务不存在');
    return task;
  }

  String _readTransferId(Map<String, dynamic> message) {
    final id = message['transferId'];
    if (id is! String || !RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) {
      throw const FormatException('传输 ID 无效');
    }
    return id;
  }

  int _readPositiveInt(Object? value, {required bool allowZero}) {
    if (value is! num ||
        value.toInt() != value ||
        value < (allowZero ? 0 : 1)) {
      throw const FormatException('数值字段无效');
    }
    return value.toInt();
  }

  String _newTransferId() => List<int>.generate(
    16,
    (_) => _secureRandom.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();

  String _basename(String path) {
    final normalized = path
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    return normalized.split('/').last;
  }

  String _relativeSuffix(String root, String child) {
    final normalizedRoot = root
        .replaceAll(r'\', '/')
        .replaceFirst(RegExp(r'/+$'), '');
    final normalizedChild = child.replaceAll(r'\', '/');
    if (!normalizedChild.startsWith('$normalizedRoot/')) {
      throw FileSystemException('目录枚举越界', child);
    }
    return normalizedChild.substring(normalizedRoot.length + 1);
  }

  String _joinPath(String root, List<String> components) {
    final separator = Platform.pathSeparator;
    return [
      root.replaceFirst(RegExp(r'[\\/]+$'), ''),
      ...components,
    ].join(separator);
  }

  String _dirname(String path) {
    final normalized = path.replaceAll(r'\', '/');
    final index = normalized.lastIndexOf('/');
    if (index < 0) return '.';
    final parent = normalized.substring(0, index);
    return Platform.isWindows ? parent.replaceAll('/', r'\') : parent;
  }

  void _notice(String message) {
    if (!_notices.isClosed) _notices.add(message);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _transportGeneration += 1;
    for (final task in _tasks.values) {
      unawaited(_closeReceiveHandles(task));
    }
    unawaited(_notices.close());
    super.dispose();
  }
}

class _MutableTransferTask {
  _MutableTransferTask({
    required this.id,
    required this.direction,
    required this.state,
    required this.createdAt,
    this.purpose = ExplicitFileTransferPurpose.explicit,
    this.entries = const [],
    this.totalBytes = 0,
    this.message,
  });

  final String id;
  final ExplicitFileTransferDirection direction;
  final DateTime createdAt;
  final ExplicitFileTransferPurpose purpose;
  ExplicitFileTransferState state;
  List<ExplicitFileTransferEntry> entries;
  int totalBytes;
  int transferredBytes = 0;
  String? destinationRoot;
  String? message;
  final Map<int, Set<int>> remoteCompletedBlocks = {};
  final Set<int> resumeEntriesReceived = {};
  final Map<int, _ReceiveEntry> receiveEntries = {};

  ExplicitFileTransferTaskSnapshot get snapshot =>
      ExplicitFileTransferTaskSnapshot(
        id: id,
        direction: direction,
        state: state,
        entries: List.unmodifiable(entries),
        transferredBytes: transferredBytes,
        totalBytes: totalBytes,
        createdAt: createdAt,
        purpose: purpose,
        destinationRoot: destinationRoot,
        message: message,
      );
}

class _IncomingManifestAssembly {
  _IncomingManifestAssembly({
    required this.transferId,
    required this.entryCount,
    required this.totalBytes,
    required this.purpose,
  });

  final String transferId;
  final int entryCount;
  final int totalBytes;
  final ExplicitFileTransferPurpose purpose;
  final List<ExplicitFileTransferEntry> entries = [];
  int nextSequence = 0;
}

class _ReceiveEntry {
  _ReceiveEntry({required this.destinationPath, required this.partialPath});

  final String destinationPath;
  final String partialPath;
  RandomAccessFile? handle;
  bool finalized = false;
}

class _PendingEntry {
  const _PendingEntry({
    required this.path,
    required this.relativePath,
    this.isDirectory = false,
  });

  final String path;
  final String relativePath;
  final bool isDirectory;
}

Future<String> _sha256Path(String path) async {
  final value = await sha256.bind(File(path).openRead()).first;
  return value.toString();
}
