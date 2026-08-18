import 'package:flutter/material.dart';

Future<String?> showRemoteComposedTextEditor(BuildContext context) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (_) => const _RemoteComposedTextEditor(),
  );
}

class _RemoteComposedTextEditor extends StatefulWidget {
  const _RemoteComposedTextEditor();

  @override
  State<_RemoteComposedTextEditor> createState() =>
      _RemoteComposedTextEditorState();
}

class _RemoteComposedTextEditorState extends State<_RemoteComposedTextEditor> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode(debugLabel: 'remote-composed-text');

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text;
    Navigator.of(context).pop(text.isEmpty ? null : text);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        20,
        0,
        20,
        MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本地编辑后发送', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 6),
          Text(
            '兼容入口：先在本机完成组合输入，再一次发送到远程设备。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 14),
          TextField(
            key: const ValueKey('remote-composed-text-field'),
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            minLines: 2,
            maxLines: 5,
            autocorrect: true,
            enableSuggestions: true,
            textInputAction: TextInputAction.newline,
            decoration: const InputDecoration(
              hintText: '输入完成后点击“发送到远程设备”',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: const ValueKey('cancel-composed-text'),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                key: const ValueKey('send-composed-text'),
                onPressed: _send,
                icon: const Icon(Icons.send_outlined),
                label: const Text('发送到远程设备'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
