enum ExplicitFileTransferDirection { outgoing, incoming }

enum ExplicitFileTransferState {
  preparing,
  offered,
  awaitingAcceptance,
  transferring,
  paused,
  reconnecting,
  verifying,
  completed,
  rejected,
  failed,
  cancelled,
}

enum ExplicitFileEntryKind { file, directory }

extension ExplicitFileTransferStateLabel on ExplicitFileTransferState {
  String get label => switch (this) {
    ExplicitFileTransferState.preparing => '正在准备',
    ExplicitFileTransferState.offered => '等待对方确认',
    ExplicitFileTransferState.awaitingAcceptance => '等待接收确认',
    ExplicitFileTransferState.transferring => '传输中',
    ExplicitFileTransferState.paused => '已暂停',
    ExplicitFileTransferState.reconnecting => '等待网络恢复',
    ExplicitFileTransferState.verifying => '正在校验',
    ExplicitFileTransferState.completed => '已完成',
    ExplicitFileTransferState.rejected => '已拒绝',
    ExplicitFileTransferState.failed => '失败',
    ExplicitFileTransferState.cancelled => '已取消',
  };
}

class ExplicitFileTransferEntry {
  const ExplicitFileTransferEntry({
    required this.index,
    required this.relativePath,
    required this.kind,
    required this.sizeBytes,
    required this.modifiedAtUnixMs,
    required this.sha256Hex,
    this.sourcePath,
  });

  factory ExplicitFileTransferEntry.fromMessage(Map<String, dynamic> value) {
    final index = value['index'];
    final relativePath = value['path'];
    final kind = value['kind'];
    final size = value['size'];
    final modifiedAt = value['modifiedAt'];
    final digest = value['sha256'];
    if (index is! num ||
        relativePath is! String ||
        kind is! String ||
        size is! num ||
        modifiedAt is! num ||
        digest is! String) {
      throw const FormatException('文件清单字段无效');
    }
    final parsedKind = switch (kind) {
      'file' => ExplicitFileEntryKind.file,
      'directory' => ExplicitFileEntryKind.directory,
      _ => throw const FormatException('文件清单类型无效'),
    };
    return ExplicitFileTransferEntry(
      index: index.toInt(),
      relativePath: relativePath,
      kind: parsedKind,
      sizeBytes: size.toInt(),
      modifiedAtUnixMs: modifiedAt.toInt(),
      sha256Hex: digest,
    );
  }

  final int index;
  final String relativePath;
  final ExplicitFileEntryKind kind;
  final int sizeBytes;
  final int modifiedAtUnixMs;
  final String sha256Hex;
  final String? sourcePath;

  bool get isFile => kind == ExplicitFileEntryKind.file;

  Map<String, dynamic> toMessage() => {
    'index': index,
    'path': relativePath,
    'kind': kind == ExplicitFileEntryKind.file ? 'file' : 'directory',
    'size': sizeBytes,
    'modifiedAt': modifiedAtUnixMs,
    'sha256': sha256Hex,
  };
}

class ExplicitFileTransferTaskSnapshot {
  const ExplicitFileTransferTaskSnapshot({
    required this.id,
    required this.direction,
    required this.state,
    required this.entries,
    required this.transferredBytes,
    required this.totalBytes,
    required this.createdAt,
    this.destinationRoot,
    this.message,
  });

  final String id;
  final ExplicitFileTransferDirection direction;
  final ExplicitFileTransferState state;
  final List<ExplicitFileTransferEntry> entries;
  final int transferredBytes;
  final int totalBytes;
  final DateTime createdAt;
  final String? destinationRoot;
  final String? message;

  bool get isIncoming => direction == ExplicitFileTransferDirection.incoming;
  bool get awaitsAcceptance =>
      isIncoming && state == ExplicitFileTransferState.awaitingAcceptance;
  bool get canPause => state == ExplicitFileTransferState.transferring;
  bool get canResume =>
      state == ExplicitFileTransferState.paused ||
      state == ExplicitFileTransferState.reconnecting;
  bool get canCancel => !{
    ExplicitFileTransferState.completed,
    ExplicitFileTransferState.rejected,
    ExplicitFileTransferState.failed,
    ExplicitFileTransferState.cancelled,
  }.contains(state);

  double? get progress {
    if (totalBytes == 0) {
      return state == ExplicitFileTransferState.completed ? 1 : null;
    }
    return (transferredBytes / totalBytes).clamp(0, 1);
  }

  String get title {
    if (entries.isEmpty) return '文件传输';
    if (entries.length == 1) return entries.first.relativePath;
    return '${entries.first.relativePath} 等 ${entries.length} 项';
  }
}
