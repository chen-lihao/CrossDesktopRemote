import 'dart:async';

import 'package:cross_desktop_remote/app/design_system/app_design_tokens.dart';
import 'package:flutter/material.dart';

/// Persistent operation feedback that is independent from transient messages.
///
/// The banner occupies and intercepts only its own bounds. Dismiss hides the
/// presentation, while cancel invokes the operation's actual cancellation.
class OperationBanner extends StatefulWidget {
  const OperationBanner({
    super.key,
    required this.operationKey,
    required this.title,
    required this.collapsedLabel,
    this.details,
    this.progress,
    this.onCancel,
    this.collapseAfter = const Duration(seconds: 4),
  });

  final String operationKey;
  final String title;
  final String collapsedLabel;
  final String? details;
  final double? progress;
  final FutureOr<void> Function()? onCancel;
  final Duration collapseAfter;

  @override
  State<OperationBanner> createState() => _OperationBannerState();
}

class _OperationBannerState extends State<OperationBanner> {
  Timer? _collapseTimer;
  bool _visible = true;
  bool _expanded = true;

  @override
  void initState() {
    super.initState();
    _scheduleCollapse();
  }

  @override
  void didUpdateWidget(OperationBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.operationKey != widget.operationKey) {
      _visible = true;
      _expanded = true;
      _scheduleCollapse();
    }
  }

  void _scheduleCollapse() {
    _collapseTimer?.cancel();
    _collapseTimer = Timer(widget.collapseAfter, () {
      if (mounted) setState(() => _expanded = false);
    });
  }

  void _expand() {
    setState(() => _expanded = true);
    _scheduleCollapse();
  }

  void _dismiss() {
    _collapseTimer?.cancel();
    setState(() => _visible = false);
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    if (!_expanded) {
      return Align(
        alignment: Alignment.topCenter,
        child: InputChip(
          key: const ValueKey('operation-banner-collapsed'),
          avatar: const Icon(Icons.content_paste_go_outlined, size: 18),
          label: Text(widget.collapsedLabel),
          onPressed: _expand,
          onDeleted: _dismiss,
          deleteButtonTooltipMessage: '隐藏',
        ),
      );
    }

    final colorScheme = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Material(
          key: const ValueKey('operation-banner-expanded'),
          color: colorScheme.surfaceContainerHigh,
          elevation: 3,
          shadowColor: colorScheme.primary.withValues(alpha: .16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.inner),
            side: BorderSide(color: colorScheme.primary.withValues(alpha: .24)),
          ),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.sm,
              AppSpacing.xs,
              AppSpacing.xs,
              AppSpacing.xs,
            ),
            child: Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(AppRadii.control),
                  ),
                  child: Icon(
                    Icons.content_paste_go_outlined,
                    size: AppIconSizes.small,
                    color: colorScheme.onPrimaryContainer,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      if (widget.details != null) ...[
                        const SizedBox(height: AppSpacing.xxs),
                        Text(widget.details!),
                      ],
                      if (widget.progress != null) ...[
                        const SizedBox(height: AppSpacing.xs),
                        LinearProgressIndicator(value: widget.progress),
                      ],
                    ],
                  ),
                ),
                if (widget.onCancel != null)
                  TextButton(
                    key: const ValueKey('operation-banner-cancel'),
                    onPressed: () => widget.onCancel?.call(),
                    child: const Text('取消'),
                  ),
                IconButton(
                  key: const ValueKey('operation-banner-dismiss'),
                  tooltip: '隐藏',
                  onPressed: _dismiss,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _collapseTimer?.cancel();
    super.dispose();
  }
}
