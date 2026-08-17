import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:flutter/material.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key, required this.session});

  final RemoteSessionController session;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: session,
      builder: (context, _) {
        final active = !{
          RemoteSessionState.idle,
          RemoteSessionState.disconnected,
          RemoteSessionState.failed,
        }.contains(session.state);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('会话', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            const Text('查看进行中的连接和本机会话记录。'),
            const SizedBox(height: 24),
            if (active)
              Card(
                child: ListTile(
                  leading: const Icon(Icons.desktop_windows_outlined),
                  title: const Text('进行中的远程会话'),
                  subtitle: Text(session.statusMessage),
                  trailing: const Icon(
                    Icons.circle,
                    color: Colors.green,
                    size: 12,
                  ),
                ),
              )
            else
              const Card(
                child: ListTile(
                  leading: Icon(Icons.history),
                  title: Text('暂无会话记录'),
                  subtitle: Text('这里只记录会话元数据，不保存屏幕内容。'),
                ),
              ),
          ],
        );
      },
    );
  }
}
