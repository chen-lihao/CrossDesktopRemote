import 'package:cross_desktop_remote/core/presentation/app_messenger.dart';
import 'package:cross_desktop_remote/features/remote/application/explicit_file_transfer_models.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

typedef ExplicitFileTransferDestinationPicker = Future<String?> Function();

Future<void> showExplicitFileTransferCenter(
  BuildContext context,
  RemoteSessionController session,
) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    constraints: const BoxConstraints(maxWidth: 760),
    builder: (context) => SafeArea(
      child: ListenableBuilder(
        listenable: session,
        builder: (context, _) {
          final tasks = session.fileTransferTasks;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              20,
              0,
              20,
              MediaQuery.viewInsetsOf(context).bottom + 24,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '文件传输',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (session.explicitFileTransferReady)
                      const Chip(
                        avatar: Icon(Icons.link, size: 16),
                        label: Text('通道已就绪'),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(_transferAvailabilityMessage(session)),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    FilledButton.icon(
                      onPressed: session.explicitFileTransferReady
                          ? () => _selectAndSendFiles(context, session)
                          : null,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: const Text('发送文件'),
                    ),
                    if (session.explicitFileTransferDirectorySelectionSupported)
                      OutlinedButton.icon(
                        onPressed: session.explicitFileTransferReady
                            ? () => _selectAndSendDirectory(context, session)
                            : null,
                        icon: const Icon(Icons.drive_folder_upload_outlined),
                        label: const Text('发送目录'),
                      ),
                  ],
                ),
                const Divider(height: 28),
                if (tasks.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: Text('暂无文件传输任务')),
                  )
                else
                  for (final task in tasks) ...[
                    ExplicitFileTransferTaskTile(task: task, session: session),
                    const SizedBox(height: 10),
                  ],
              ],
            ),
          );
        },
      ),
    ),
  );
}

class HostFileTransferSection extends StatelessWidget {
  const HostFileTransferSection({
    super.key,
    required this.session,
    this.destinationPicker,
  });

  final RemoteSessionController session;
  final ExplicitFileTransferDestinationPicker? destinationPicker;

  @override
  Widget build(BuildContext context) {
    final pendingTasks = session.fileTransferTasks
        .where((task) => task.awaitsAcceptance)
        .toList(growable: false);
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: pendingTasks.isEmpty
            ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.45)
            : colorScheme.primaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: pendingTasks.isEmpty
              ? colorScheme.outlineVariant
              : colorScheme.primary.withValues(alpha: 0.45),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.swap_horiz),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '文件传输',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      Text(
                        pendingTasks.isEmpty
                            ? _transferAvailabilityMessage(session)
                            : '收到 ${pendingTasks.length} 个待确认的文件传输请求',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                Badge.count(
                  isLabelVisible: pendingTasks.isNotEmpty,
                  count: pendingTasks.length,
                  child: OutlinedButton.icon(
                    onPressed: () =>
                        showExplicitFileTransferCenter(context, session),
                    icon: const Icon(Icons.folder_open_outlined),
                    label: const Text('打开传输中心'),
                  ),
                ),
              ],
            ),
            if (pendingTasks.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final task in pendingTasks) ...[
                ExplicitFileTransferTaskTile(
                  task: task,
                  session: session,
                  destinationPicker: destinationPicker,
                ),
                if (task != pendingTasks.last) const SizedBox(height: 10),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class ExplicitFileTransferTaskTile extends StatelessWidget {
  const ExplicitFileTransferTaskTile({
    super.key,
    required this.task,
    required this.session,
    this.destinationPicker,
  });

  final ExplicitFileTransferTaskSnapshot task;
  final RemoteSessionController session;
  final ExplicitFileTransferDestinationPicker? destinationPicker;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return DecoratedBox(
      key: ValueKey('explicitFileTransferTask-${task.id}'),
      decoration: BoxDecoration(
        color: task.awaitsAcceptance
            ? colorScheme.primaryContainer.withValues(alpha: 0.45)
            : colorScheme.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  task.isIncoming
                      ? Icons.download_outlined
                      : Icons.upload_outlined,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        task.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      Text(
                        '${task.isIncoming ? '接收' : '发送'} · '
                        '${task.state.label} · '
                        '${formatTransferBytes(task.totalBytes)}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (task.progress case final progress?) ...[
              const SizedBox(height: 10),
              LinearProgressIndicator(value: progress),
              const SizedBox(height: 4),
              Text(
                '${formatTransferBytes(task.transferredBytes)} / '
                '${formatTransferBytes(task.totalBytes)}',
                textAlign: TextAlign.right,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (task.destinationRoot case final destination?) ...[
              const SizedBox(height: 6),
              Text(
                session.explicitFileTransferUsesManagedReceiveStorage
                    ? '已保存到应用暂存区；请导出到“文件”或通过分享保存。'
                    : '保存位置：$destination',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (task.message case final message?) ...[
              const SizedBox(height: 6),
              Text(message, style: Theme.of(context).textTheme.bodySmall),
            ],
            if (task.awaitsAcceptance) ...[
              const SizedBox(height: 10),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: ValueKey('rejectExplicitFileTransfer-${task.id}'),
                    onPressed: () =>
                        session.rejectExplicitFileTransfer(task.id),
                    child: const Text('拒绝'),
                  ),
                  FilledButton(
                    key: ValueKey('acceptExplicitFileTransfer-${task.id}'),
                    onPressed: () => _acceptTransfer(context),
                    child: Text(
                      session.explicitFileTransferUsesManagedReceiveStorage
                          ? '接收到应用暂存区'
                          : '选择保存位置并接收',
                    ),
                  ),
                ],
              ),
            ] else if (task.isIncoming &&
                task.state == ExplicitFileTransferState.completed &&
                session.explicitFileTransferReceivedExportSupported) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    key: ValueKey('shareExplicitFileTransfer-${task.id}'),
                    onPressed: () => _shareTransfer(context),
                    icon: const Icon(Icons.ios_share_outlined),
                    label: const Text('分享…'),
                  ),
                  FilledButton.icon(
                    key: ValueKey('exportExplicitFileTransfer-${task.id}'),
                    onPressed: () => _exportTransfer(context),
                    icon: const Icon(Icons.folder_outlined),
                    label: const Text('导出到“文件”'),
                  ),
                ],
              ),
            ] else if (task.canPause || task.canResume || task.canCancel) ...[
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (task.canPause)
                    TextButton.icon(
                      onPressed: () =>
                          session.pauseExplicitFileTransfer(task.id),
                      icon: const Icon(Icons.pause),
                      label: const Text('暂停'),
                    ),
                  if (task.canResume)
                    TextButton.icon(
                      onPressed: session.explicitFileTransferReady
                          ? () => session.resumeExplicitFileTransfer(task.id)
                          : null,
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('继续'),
                    ),
                  if (task.canCancel)
                    TextButton.icon(
                      onPressed: () =>
                          session.cancelExplicitFileTransfer(task.id),
                      icon: const Icon(Icons.close),
                      label: const Text('取消'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _acceptTransfer(BuildContext context) async {
    try {
      if (session.explicitFileTransferUsesManagedReceiveStorage) {
        await session.acceptExplicitFileTransferToManagedStorage(task.id);
        if (context.mounted) {
          AppMessenger.show('已开始接收，完成后可导出或分享');
        }
        return;
      }
      final destination =
          await (destinationPicker ??
              () => getDirectoryPath(confirmButtonText: '保存到此处'))();
      if (destination == null) return;
      await session.acceptExplicitFileTransfer(task.id, destination);
      if (context.mounted) {
        AppMessenger.show('已开始接收文件', level: AppMessageLevel.success);
      }
    } catch (error) {
      if (context.mounted) {
        AppMessenger.show('接收文件失败：$error', level: AppMessageLevel.error);
      }
    }
  }

  Future<void> _exportTransfer(BuildContext context) async {
    try {
      await session.exportExplicitFileTransfer(task.id);
      if (context.mounted) {
        AppMessenger.show('已完成系统文件导出', level: AppMessageLevel.success);
      }
    } catch (error) {
      if (context.mounted) {
        AppMessenger.show('导出文件失败：$error', level: AppMessageLevel.error);
      }
    }
  }

  Future<void> _shareTransfer(BuildContext context) async {
    try {
      await session.shareExplicitFileTransfer(task.id);
    } catch (error) {
      if (context.mounted) {
        AppMessenger.show('分享文件失败：$error', level: AppMessageLevel.error);
      }
    }
  }
}

Future<void> _selectAndSendFiles(
  BuildContext context,
  RemoteSessionController session,
) async {
  try {
    if (!session.explicitFileTransferDirectorySelectionSupported) {
      final transferId = await session.pickAndSendExplicitFiles();
      if (transferId == null) return;
      if (context.mounted) {
        AppMessenger.show('已发送文件清单，等待对方确认');
      }
      return;
    }
    final selected = await openFiles();
    if (selected.isEmpty) return;
    await session.sendExplicitFiles(
      selected.map((file) => file.path).toList(growable: false),
    );
    if (context.mounted) {
      AppMessenger.show('已发送文件清单，等待对方确认');
    }
  } catch (error) {
    if (context.mounted) {
      AppMessenger.show('准备文件传输失败：$error', level: AppMessageLevel.error);
    }
  }
}

Future<void> _selectAndSendDirectory(
  BuildContext context,
  RemoteSessionController session,
) async {
  try {
    final selected = await getDirectoryPath(confirmButtonText: '发送此目录');
    if (selected == null) return;
    await session.sendExplicitDirectory(selected);
    if (context.mounted) {
      AppMessenger.show('已发送目录清单，等待对方确认');
    }
  } catch (error) {
    if (context.mounted) {
      AppMessenger.show('准备目录传输失败：$error', level: AppMessageLevel.error);
    }
  }
}

String _transferAvailabilityMessage(RemoteSessionController session) {
  if (session.explicitFileTransferReady) {
    return session.explicitFileTransferUsesManagedReceiveStorage
        ? '选择文件可发送；接收文件先进入应用暂存区，完成后由你导出或分享。'
        : '可以双向发送文件或目录；接收方选择保存位置后开始传输。';
  }
  if (session.remoteSupportsExplicitFileTransferV1) {
    return '文件通道正在建立，请稍候。';
  }
  return '远程设备版本不支持显式文件传输。';
}

String formatTransferBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GiB';
}
