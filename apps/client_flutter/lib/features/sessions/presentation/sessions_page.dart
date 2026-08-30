import 'dart:async';

import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/sessions/application/session_history_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class SessionsPage extends StatefulWidget {
  const SessionsPage({
    super.key,
    required this.sessions,
    required this.history,
    required this.onOpenDevices,
  });

  final List<RemoteSessionController> sessions;
  final SessionHistoryController history;
  final VoidCallback onOpenDevices;

  @override
  State<SessionsPage> createState() => _SessionsPageState();
}

class _SessionsPageState extends State<SessionsPage> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && widget.history.currentStartedAt != null) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([...widget.sessions, widget.history]),
      builder: (context, _) {
        final session = _activeSession;
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 980),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      '会话',
                      style: Theme.of(context).textTheme.headlineMedium,
                    ),
                    const SizedBox(height: 6),
                    const Text('查看当前连接质量和最近的本机会话元数据。'),
                    const SizedBox(height: 24),
                    if (session != null) _buildActiveSession(context, session),
                    if (session != null) const SizedBox(height: 24),
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            '最近会话',
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        if (widget.history.records.isNotEmpty)
                          TextButton.icon(
                            onPressed: _confirmClearHistory,
                            icon: const Icon(Icons.delete_outline),
                            label: const Text('清空'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    if (widget.history.records.isEmpty)
                      const Card(
                        child: Padding(
                          padding: EdgeInsets.all(24),
                          child: Row(
                            children: [
                              Icon(Icons.history),
                              SizedBox(width: 16),
                              Expanded(child: Text('暂无会话记录；这里只保存连接元数据。')),
                            ],
                          ),
                        ),
                      )
                    else
                      for (final record in widget.history.records)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _HistoryTile(record: record),
                        ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  RemoteSessionController? get _activeSession {
    for (final session in widget.sessions) {
      if (session.state == RemoteSessionState.streaming) return session;
    }
    for (final session in widget.sessions) {
      if ({
        RemoteSessionState.connecting,
        RemoteSessionState.awaitingApproval,
        RemoteSessionState.reconnecting,
      }.contains(session.state)) {
        return session;
      }
    }
    return null;
  }

  Widget _buildActiveSession(
    BuildContext context,
    RemoteSessionController session,
  ) {
    final startedAt = widget.history.currentStartedAtFor(session);
    final duration = startedAt == null
        ? null
        : DateTime.now().difference(startedAt);
    final media = session.mediaDiagnostics;
    final diagnostics = [
      ('角色', session.role == RemoteRole.host ? '共享本机' : '控制远程设备'),
      ('设备', session.remoteDeviceId ?? '等待设备信息'),
      ('显示器', session.selectedDisplay?.name ?? '等待屏幕信息'),
      ('画质', session.qualityStatusLabel),
      ('发送', session.outboundVideoFrameSize?.label ?? '检测中'),
      ('接收', session.inboundVideoFrameSize?.label ?? '检测中'),
      (
        '输入 RTT',
        session.inputRoundTripMs == null
            ? '检测中'
            : '${session.inputRoundTripMs!.toStringAsFixed(0)} ms',
      ),
      if (media?.framesPerSecond != null)
        ('视频帧率', '${media!.framesPerSecond!.toStringAsFixed(0)} FPS'),
      if (media?.encodeMsPerFrame != null)
        ('编码', '${media!.encodeMsPerFrame!.toStringAsFixed(1)} ms/帧'),
      if (media?.decodeMsPerFrame != null)
        ('解码', '${media!.decodeMsPerFrame!.toStringAsFixed(1)} ms/帧'),
      if (media?.jitterBufferMsPerFrame != null)
        ('抖动缓冲', '${media!.jitterBufferMsPerFrame!.toStringAsFixed(1)} ms'),
      if (media?.networkRoundTripMs != null)
        ('网络 RTT', '${media!.networkRoundTripMs!.toStringAsFixed(0)} ms'),
      if (media?.bitrateMbps != null)
        ('实际码率', '${media!.bitrateMbps!.toStringAsFixed(1)} Mbps'),
      if (media?.packetLossPercent != null)
        ('区间丢包', '${media!.packetLossPercent!.toStringAsFixed(2)}%'),
      if (media?.packetsLost != null) ('累计丢包', '${media!.packetsLost}'),
      if (media?.codec != null) ('编解码', media!.codec!),
      if (duration != null) ('时长', _formatDuration(duration)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: const BoxDecoration(
                    color: Colors.green,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '进行中的远程会话',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                Text(session.statusMessage),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final item in diagnostics)
                  _DiagnosticChip(label: item.$1, value: item.$2),
              ],
            ),
            const SizedBox(height: 20),
            Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                TextButton.icon(
                  onPressed: () => _copyDiagnostics(session),
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('复制诊断'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onOpenDevices,
                  icon: const Icon(Icons.desktop_windows_outlined),
                  label: const Text('打开远程桌面'),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => unawaited(session.disconnect()),
                  icon: const Icon(Icons.link_off),
                  label: const Text('断开'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _copyDiagnostics(RemoteSessionController session) async {
    final media = session.mediaDiagnostics;
    final text = [
      '状态: ${session.statusMessage}',
      '角色: ${session.role.name}',
      '设备: ${session.remoteDeviceId ?? 'Unknown'}',
      '显示器: ${session.selectedDisplay?.name ?? 'Unknown'}',
      '显示几何: ${session.selectedDisplay?.geometryDiagnosticsLabel ?? 'Unknown'}',
      '画质: ${session.qualityStatusLabel}',
      '发送分辨率: ${session.outboundVideoFrameSize?.label ?? 'Unknown'}',
      '接收分辨率: ${session.inboundVideoFrameSize?.label ?? 'Unknown'}',
      '输入 RTT: ${session.inputRoundTripMs?.toStringAsFixed(0) ?? 'Unknown'} ms',
      '视频 FPS: ${media?.framesPerSecond?.toStringAsFixed(0) ?? 'Unknown'}',
      '编码耗时: ${media?.encodeMsPerFrame?.toStringAsFixed(1) ?? 'Unknown'} ms/frame',
      '解码耗时: ${media?.decodeMsPerFrame?.toStringAsFixed(1) ?? 'Unknown'} ms/frame',
      '抖动缓冲: ${media?.jitterBufferMsPerFrame?.toStringAsFixed(1) ?? 'Unknown'} ms/frame',
      '网络 RTT: ${media?.networkRoundTripMs?.toStringAsFixed(0) ?? 'Unknown'} ms',
      '实际码率: ${media?.bitrateMbps?.toStringAsFixed(2) ?? 'Unknown'} Mbps',
      '可用发送带宽: ${media?.availableOutgoingBitrateMbps?.toStringAsFixed(2) ?? 'Unknown'} Mbps',
      '区间丢包: ${media?.packetLossPercent?.toStringAsFixed(2) ?? 'Unknown'}%',
      '累计丢包: ${media?.packetsLost ?? 'Unknown'}',
      '区间丢帧: ${media?.framesDroppedDelta ?? 'Unknown'}',
      '区间冻结: ${media?.freezeCountDelta ?? 'Unknown'}',
      '关键帧 encoded/decoded: ${media?.keyFramesEncoded ?? 'Unknown'}/${media?.keyFramesDecoded ?? 'Unknown'}',
      '区间 NACK/PLI/FIR: ${media?.nackCountDelta ?? 'Unknown'}/${media?.pliCountDelta ?? 'Unknown'}/${media?.firCountDelta ?? 'Unknown'}',
      'Codec: ${media?.codec ?? 'Unknown'}',
      'Encoder: ${media?.encoderImplementation ?? 'Unknown'}',
      'Decoder: ${media?.decoderImplementation ?? 'Unknown'}',
      '质量限制: ${media?.qualityLimitationReason ?? 'Unknown'}',
    ].join('\n');
    await Clipboard.setData(ClipboardData(text: text));
    AppMessenger.show('会话诊断已复制', level: AppMessageLevel.success);
  }

  Future<void> _confirmClearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空会话历史？'),
        content: const Text('此操作只会删除本机保存的会话元数据。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.history.clear();
      AppMessenger.show('会话历史已清空', level: AppMessageLevel.success);
    }
  }
}

class _DiagnosticChip extends StatelessWidget {
  const _DiagnosticChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Text('$label  $value'),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.record});

  final SessionRecord record;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(
          record.role == RemoteRole.host.name
              ? Icons.screen_share_outlined
              : Icons.desktop_windows_outlined,
        ),
        title: Text(record.deviceName),
        subtitle: Text(
          '${_formatDate(record.startedAt)} · ${record.displayName} · '
          '${record.quality} · ${_formatDuration(record.duration)}',
        ),
        trailing: Text(record.outcome),
      ),
    );
  }
}

String _formatDuration(Duration value) {
  final hours = value.inHours;
  final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
  return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
}

String _formatDate(DateTime value) {
  final local = value.toLocal();
  String two(int item) => item.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}
