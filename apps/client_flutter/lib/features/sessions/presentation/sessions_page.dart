import 'package:flutter/material.dart';

class SessionsPage extends StatelessWidget {
  const SessionsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('会话', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        const Text('查看进行中的连接和本机会话记录。'),
        const SizedBox(height: 24),
        const Card(
          child: ListTile(
            leading: Icon(Icons.history),
            title: Text('暂无会话记录'),
            subtitle: Text('这里只记录会话元数据，不保存屏幕内容。'),
          ),
        ),
      ],
    );
  }
}
