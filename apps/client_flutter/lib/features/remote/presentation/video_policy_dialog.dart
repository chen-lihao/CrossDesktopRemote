import 'package:cross_desktop_remote/features/remote/application/remote_session_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<RemoteVideoPolicy?> showVideoPolicyEditor({
  required BuildContext context,
  required RemoteVideoPolicy initialPolicy,
  String title = '分辨率与帧率',
  String confirmLabel = '应用',
  bool customValuesOnly = false,
}) {
  return showDialog<RemoteVideoPolicy>(
    context: context,
    builder: (_) => VideoPolicyDialog(
      initialPolicy: initialPolicy,
      title: title,
      confirmLabel: confirmLabel,
      customValuesOnly: customValuesOnly,
    ),
  );
}

class VideoPolicyDialog extends StatefulWidget {
  const VideoPolicyDialog({
    super.key,
    required this.initialPolicy,
    this.title = '分辨率与帧率',
    this.confirmLabel = '应用',
    this.customValuesOnly = false,
  });

  final RemoteVideoPolicy initialPolicy;
  final String title;
  final String confirmLabel;
  final bool customValuesOnly;

  @override
  State<VideoPolicyDialog> createState() => _VideoPolicyDialogState();
}

class _VideoPolicyDialogState extends State<VideoPolicyDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _edgeController;
  late final TextEditingController _fpsController;
  late final TextEditingController _bitrateController;
  late RemoteVideoPolicy _policy;

  @override
  void initState() {
    super.initState();
    _policy = widget.customValuesOnly
        ? widget.initialPolicy.copyWith(
            resolution: RemoteResolutionMode.custom,
            frameRate: RemoteFrameRateMode.custom,
          )
        : widget.initialPolicy;
    _edgeController = TextEditingController(
      text: '${widget.initialPolicy.customLongEdge}',
    );
    _fpsController = TextEditingController(
      text: '${widget.initialPolicy.customFramesPerSecond}',
    );
    _bitrateController = TextEditingController(
      text: widget.initialPolicy.maxBitrateMbps?.toString() ?? '',
    );
  }

  @override
  void dispose() {
    _edgeController.dispose();
    _fpsController.dispose();
    _bitrateController.dispose();
    super.dispose();
  }

  String? _validateInteger(
    String? raw, {
    required String label,
    required int minimum,
    required int maximum,
    bool optional = false,
  }) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return optional ? null : '请输入$label';
    final parsed = int.tryParse(value);
    if (parsed == null) return '$label必须是整数';
    if (parsed < minimum || parsed > maximum) {
      return '$label范围为 $minimum～$maximum';
    }
    return null;
  }

  void _close([RemoteVideoPolicy? result]) {
    FocusScope.of(context).unfocus();
    Navigator.of(context).pop(result);
  }

  void _apply() {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final bitrateText = _bitrateController.text.trim();
    _close(
      _policy.copyWith(
        customLongEdge: int.parse(_edgeController.text.trim()),
        customFramesPerSecond: int.parse(_fpsController.text.trim()),
        maxBitrateMbps: bitrateText.isEmpty ? null : int.parse(bitrateText),
        automaticBitrate: bitrateText.isEmpty,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 430,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (!widget.customValuesOnly) ...[
                  DropdownButtonFormField<RemoteResolutionMode>(
                    key: const ValueKey('videoPolicyResolutionField'),
                    initialValue: _policy.resolution,
                    decoration: const InputDecoration(labelText: '分辨率'),
                    items: [
                      for (final value in RemoteResolutionMode.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(
                          () => _policy = _policy.copyWith(resolution: value),
                        );
                      }
                    },
                  ),
                ],
                if (widget.customValuesOnly ||
                    _policy.resolution == RemoteResolutionMode.custom) ...[
                  if (!widget.customValuesOnly) const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('videoPolicyCustomLongEdgeField'),
                    controller: _edgeController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '分辨率长边像素（320～7680）',
                    ),
                    validator: (value) => _validateInteger(
                      value,
                      label: '分辨率长边',
                      minimum: 320,
                      maximum: 7680,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                if (!widget.customValuesOnly)
                  DropdownButtonFormField<RemoteFrameRateMode>(
                    key: const ValueKey('videoPolicyFrameRateField'),
                    initialValue: _policy.frameRate,
                    decoration: const InputDecoration(labelText: '帧率'),
                    items: [
                      for (final value in RemoteFrameRateMode.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(
                          () => _policy = _policy.copyWith(frameRate: value),
                        );
                      }
                    },
                  ),
                if (widget.customValuesOnly ||
                    _policy.frameRate == RemoteFrameRateMode.custom) ...[
                  if (!widget.customValuesOnly) const SizedBox(height: 12),
                  TextFormField(
                    key: const ValueKey('videoPolicyCustomFpsField'),
                    controller: _fpsController,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '帧率（5～120 fps）',
                    ),
                    validator: (value) => _validateInteger(
                      value,
                      label: '帧率',
                      minimum: 5,
                      maximum: 120,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  key: const ValueKey('videoPolicyBitrateField'),
                  controller: _bitrateController,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    labelText: '最大码率 Mbps（留空为自动）',
                  ),
                  validator: (value) => _validateInteger(
                    value,
                    label: '最大码率',
                    minimum: 1,
                    maximum: 100,
                    optional: true,
                  ),
                ),
                if (!widget.customValuesOnly) ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<RemoteVideoPreference>(
                    key: const ValueKey('videoPolicyPreferenceField'),
                    initialValue: _policy.preference,
                    decoration: const InputDecoration(labelText: '降级策略'),
                    items: [
                      for (final value in RemoteVideoPreference.values)
                        DropdownMenuItem(
                          value: value,
                          child: Text(value.label),
                        ),
                    ],
                    onChanged: (value) {
                      if (value != null) {
                        setState(
                          () => _policy = _policy.copyWith(preference: value),
                        );
                      }
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('videoPolicyCancelButton'),
          onPressed: _close,
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('videoPolicyApplyButton'),
          onPressed: _apply,
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}
