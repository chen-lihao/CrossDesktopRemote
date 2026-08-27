enum ClipboardSyncMode {
  disabled,
  bidirectional,
  controllerToHost,
  hostToController;

  String get label => switch (this) {
    ClipboardSyncMode.disabled => '关闭',
    ClipboardSyncMode.bidirectional => '双向同步',
    ClipboardSyncMode.controllerToHost => '控制端 → 被控端',
    ClipboardSyncMode.hostToController => '被控端 → 控制端',
  };

  String get description => switch (this) {
    ClipboardSyncMode.disabled => '不读取、不传输也不写入系统剪贴板',
    ClipboardSyncMode.bidirectional => '两端新复制的文本会自动同步',
    ClipboardSyncMode.controllerToHost => '只将控制端新复制的文本发送到被控端',
    ClipboardSyncMode.hostToController => '只将被控端新复制的文本发送到控制端',
  };

  bool allowsOutbound({required bool localIsController}) => switch (this) {
    ClipboardSyncMode.disabled => false,
    ClipboardSyncMode.bidirectional => true,
    ClipboardSyncMode.controllerToHost => localIsController,
    ClipboardSyncMode.hostToController => !localIsController,
  };

  bool allowsInbound({required bool localIsController}) => switch (this) {
    ClipboardSyncMode.disabled => false,
    ClipboardSyncMode.bidirectional => true,
    ClipboardSyncMode.controllerToHost => !localIsController,
    ClipboardSyncMode.hostToController => localIsController,
  };
}

enum ClipboardSyncStatus {
  unavailable,
  disabled,
  waitingForPeer,
  ready,
  sending,
  receiving,
  error;

  String get label => switch (this) {
    ClipboardSyncStatus.unavailable => '当前平台不支持',
    ClipboardSyncStatus.disabled => '已关闭',
    ClipboardSyncStatus.waitingForPeer => '等待支持剪贴板的远程设备',
    ClipboardSyncStatus.ready => '已就绪',
    ClipboardSyncStatus.sending => '正在发送文本',
    ClipboardSyncStatus.receiving => '正在接收文本',
    ClipboardSyncStatus.error => '同步异常',
  };
}
