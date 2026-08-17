import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text('设置', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 24),
        const Card(
          child: Column(
            children: [
              ListTile(
                leading: Icon(Icons.security_outlined),
                title: Text('安全与权限'),
                subtitle: Text('设备身份、会话授权和无人值守策略'),
              ),
              Divider(height: 1),
              ListTile(
                leading: Icon(Icons.speed_outlined),
                title: Text('画质与性能'),
                subtitle: Text('支持自动、720p、1080p、2K 和原画档位'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
