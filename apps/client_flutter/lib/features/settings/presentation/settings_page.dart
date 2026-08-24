import 'dart:async';

import 'package:cross_desktop_remote/features/remote/application/remote_session_controller.dart';
import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:cross_desktop_remote/core/signaling/signaling_endpoint.dart';
import 'package:cross_desktop_remote/features/settings/application/app_settings_controller.dart';
import 'package:flutter/material.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.settings,
    required this.session,
  });

  final AppSettingsController settings;
  final RemoteSessionController session;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge([settings, session]),
      builder: (context, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text('设置', style: Theme.of(context).textTheme.headlineMedium),
                  const SizedBox(height: 6),
                  Text(
                    '这些选项会保存在本机，并作为后续远程会话的默认值。',
                    style: Theme.of(context).textTheme.bodyLarge,
                  ),
                  const SizedBox(height: 24),
                  _SettingsSection(
                    title: '画质与性能',
                    icon: Icons.high_quality_outlined,
                    children: [
                      ListTile(
                        title: const Text('默认传输画质'),
                        subtitle: const Text('Sidecar 和 Retina 屏幕会优先按实际像素采集'),
                        trailing: DropdownButton<RemoteQualityProfile>(
                          value: settings.defaultQuality,
                          onChanged: (value) {
                            if (value != null) {
                              unawaited(settings.setDefaultQuality(value));
                            }
                          },
                          items: [
                            for (final profile in RemoteQualityProfile.values)
                              DropdownMenuItem(
                                value: profile,
                                child: Text(profile.label),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SettingsSection(
                    title: '远程输入',
                    icon: Icons.touch_app_outlined,
                    children: [
                      ListTile(
                        title: const Text('默认触控方式'),
                        trailing: SegmentedButton<RemotePointerMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: RemotePointerMode.touchpad,
                              label: Text('触控板'),
                            ),
                            ButtonSegment(
                              value: RemotePointerMode.direct,
                              label: Text('直接触控'),
                            ),
                          ],
                          selected: {settings.pointerMode},
                          onSelectionChanged: (values) =>
                              unawaited(settings.setPointerMode(values.single)),
                        ),
                      ),
                      _SliderSetting(
                        label: '指针灵敏度',
                        value: settings.pointerSensitivity,
                        min: .5,
                        max: 2.5,
                        divisions: 20,
                        onChanged: (value) =>
                            unawaited(settings.setPointerSensitivity(value)),
                      ),
                      _SliderSetting(
                        label: '滚动灵敏度',
                        value: settings.scrollSensitivity,
                        min: .5,
                        max: 4,
                        divisions: 35,
                        onChanged: (value) =>
                            unawaited(settings.setScrollSensitivity(value)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SettingsSection(
                    title: '连接与发现',
                    icon: Icons.lan_outlined,
                    children: [
                      SwitchListTile(
                        title: const Text('局域网设备发现'),
                        subtitle: const Text('自动显示同一局域网内正在共享的设备'),
                        value: settings.lanDiscoveryEnabled,
                        onChanged: (value) =>
                            unawaited(settings.setLanDiscoveryEnabled(value)),
                      ),
                      SwitchListTile(
                        title: const Text('显示高级网络信息'),
                        subtitle: const Text('在设备页显示信令地址和全部网卡地址'),
                        value: settings.showAdvancedNetwork,
                        onChanged: (value) =>
                            unawaited(settings.setShowAdvancedNetwork(value)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _SettingsSection(
                    title: '安全与权限',
                    icon: Icons.security_outlined,
                    children: [
                      SwitchListTile(
                        title: const Text('保存会话元数据'),
                        subtitle: const Text('不保存屏幕、剪贴板和键盘输入内容'),
                        value: settings.sessionHistoryEnabled,
                        onChanged: (value) =>
                            unawaited(settings.setSessionHistoryEnabled(value)),
                      ),
                      ListTile(
                        enabled: settings.sessionHistoryEnabled,
                        title: const Text('历史记录上限'),
                        trailing: DropdownButton<int>(
                          value: settings.sessionHistoryLimit,
                          onChanged: settings.sessionHistoryEnabled
                              ? (value) {
                                  if (value != null) {
                                    unawaited(
                                      settings.setSessionHistoryLimit(value),
                                    );
                                  }
                                }
                              : null,
                          items: const [
                            DropdownMenuItem(value: 10, child: Text('10 条')),
                            DropdownMenuItem(value: 25, child: Text('25 条')),
                            DropdownMenuItem(value: 50, child: Text('50 条')),
                            DropdownMenuItem(value: 100, child: Text('100 条')),
                          ],
                        ),
                      ),
                      if (session.role == RemoteRole.host)
                        ListTile(
                          leading: Icon(
                            session.accessibilityGranted == true
                                ? Icons.check_circle_outline
                                : Icons.warning_amber_outlined,
                          ),
                          title: const Text('远程输入权限'),
                          subtitle: Text(
                            session.accessibilityGranted == true
                                ? '辅助功能权限已就绪'
                                : '尚未允许鼠标和键盘控制',
                          ),
                          trailing: TextButton(
                            onPressed: session.accessibilityGranted == true
                                ? () => session.refreshHostPermissions(
                                    announce: true,
                                  )
                                : session.requestHostInputPermission,
                            child: Text(
                              session.accessibilityGranted == true
                                  ? '重新检查'
                                  : '前往设置',
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.title,
    required this.icon,
    required this.children,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 16, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(icon, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 10),
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
            const SizedBox(height: 8),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _SliderSetting extends StatelessWidget {
  const _SliderSetting({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      subtitle: Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        label: value.toStringAsFixed(2),
        onChanged: onChanged,
      ),
      trailing: SizedBox(
        width: 44,
        child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end),
      ),
    );
  }
}
