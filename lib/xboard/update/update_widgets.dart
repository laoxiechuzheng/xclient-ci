import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers.dart';
import 'update_manager.dart';
import 'update_providers.dart';

Future<void> checkXcUpdate(BuildContext context, WidgetRef ref) async {
  try {
    await ref.read(xcActionsProvider).pollState();
    final manager = ref.read(xcUpdateManagerProvider);
    await manager?.onPolicy(ref.read(xcPolicyProvider));
    if (!context.mounted) return;
    if (manager == null || manager.state.decision.policy == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('尚未获取有效更新策略，请稍后重试')));
      return;
    }
    await showXcUpdateDialog(context);
  } catch (_) {
    if (!context.mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('检查更新失败，请检查网络后重试')));
  }
}

Future<void> showXcUpdateDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const XcUpdateDialog());

class XcUpdateHost extends ConsumerStatefulWidget {
  final Widget child;
  const XcUpdateHost({super.key, required this.child});
  @override
  ConsumerState<XcUpdateHost> createState() => _XcUpdateHostState();
}

class _XcUpdateHostState extends ConsumerState<XcUpdateHost> {
  String? _forcedVersionShown;
  bool _dialogOpen = false;

  @override
  Widget build(BuildContext context) {
    ref.watch(xcUpdateManagerProvider);
    final state = ref.watch(xcUpdateStateProvider).value;
    final uiReady = ref.watch(xcUpdateUiReadyProvider);
    final requested = ref.watch(xcUpdateOpenRequestedProvider);
    if (state != null && uiReady && !_dialogOpen) {
      final newForced =
          state.isForced && _forcedVersionShown != state.decision.latest;
      if ((state.noticeDue || newForced || requested) &&
          state.decision.hasUpdate) {
        _dialogOpen = true;
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          try {
            if (!ref.read(xcUpdateUiReadyProvider)) return;
            final current = ref.read(xcUpdateStateProvider).value;
            if (current == null || !current.decision.hasUpdate) return;
            if (current.isForced) _forcedVersionShown = current.decision.latest;
            ref.read(xcUpdateOpenRequestedProvider.notifier).set(false);
            final displayed = showXcUpdateDialog(context);
            unawaited(
              ref
                  .read(xcUpdateManagerProvider)
                  ?.noticeShown()
                  .catchError((Object _) {}),
            );
            await displayed;
          } finally {
            if (mounted) setState(() => _dialogOpen = false);
          }
        });
      }
    }
    return widget.child;
  }
}

class XcUpdateDialog extends ConsumerWidget {
  const XcUpdateDialog({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state =
        ref.watch(xcUpdateStateProvider).value ?? const XcUpdateState();
    final manager = ref.watch(xcUpdateManagerProvider);
    return XcUpdatePanel(
      state: state,
      currentVersion: ref.watch(xcCurrentVersionProvider) ?? '',
      onClose: () => Navigator.of(context).pop(),
      onUpdate: manager == null ? null : () => unawaited(manager.start()),
      onPermission: manager == null
          ? null
          : () async {
              try {
                await manager.grantPermission();
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('无法打开安装权限设置，请在系统设置中允许安装未知应用')),
                );
              }
            },
    );
  }
}

class XcUpdatePanel extends StatelessWidget {
  final XcUpdateState state;
  final String currentVersion;
  final VoidCallback onClose;
  final VoidCallback? onUpdate;
  final VoidCallback? onPermission;
  const XcUpdatePanel({
    super.key,
    required this.state,
    required this.currentVersion,
    required this.onClose,
    this.onUpdate,
    this.onPermission,
  });

  @override
  Widget build(BuildContext context) {
    final stage = switch (state.phase) {
      XcUpdatePhase.idle => state.decision.hasUpdate ? '新版本已就绪' : '当前已是最新版本',
      XcUpdatePhase.checking => '正在校验发布信息',
      XcUpdatePhase.downloading => '正在下载安装包',
      XcUpdatePhase.needsPermission => '需要安装权限',
      XcUpdatePhase.installing => '正在安装',
      XcUpdatePhase.awaitingUser => '请在系统安装窗口确认',
      XcUpdatePhase.restarting => '安装器已接管，即将重新启动',
      XcUpdatePhase.manual => '请完成手动安装',
      XcUpdatePhase.failed => '更新暂未完成',
    };
    return AlertDialog(
      title: Text(state.isForced ? '需要更新客户端' : '客户端更新'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(stage, style: AppTextStyle.headline.of(context)),
            const SizedBox(height: 12),
            if (currentVersion.isNotEmpty) Text('当前版本：$currentVersion'),
            if (state.decision.latest.isNotEmpty)
              Text('新版本：${state.decision.latest}'),
            if (state.isForced) ...[
              const SizedBox(height: 12),
              const Text('完成更新后可恢复连接。账号、购买和工单仍可使用。'),
            ],
            if (state.decision.notes.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(state.decision.notes),
            ],
            if (state.isBusy) ...[
              const SizedBox(height: 20),
              LinearProgressIndicator(
                value: state.phase == XcUpdatePhase.downloading
                    ? state.progress
                    : null,
              ),
              const SizedBox(height: 8),
              if (state.total > 0)
                Text(
                  '${(state.received / 1048576).toStringAsFixed(1)} / ${(state.total / 1048576).toStringAsFixed(1)} MB',
                ),
            ],
            if (state.message != null) ...[
              const SizedBox(height: 16),
              Text(state.message!, style: AppTextStyle.footnote.of(context)),
            ],
            if (state.retryAt != null) ...[
              const SizedBox(height: 8),
              const Text('稍后会自动重试，也可以立即重试。'),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: onClose,
          child: Text(state.isBusy ? '后台更新' : '稍后'),
        ),
        if (state.phase == XcUpdatePhase.needsPermission)
          FilledButton(onPressed: onPermission, child: const Text('允许安装'))
        else if (state.decision.hasUpdate && !state.isBusy)
          FilledButton(
            onPressed: onUpdate,
            child: Text(state.phase == XcUpdatePhase.failed ? '重试更新' : '立即更新'),
          ),
      ],
    );
  }
}

class XcUpdateTile extends ConsumerWidget {
  const XcUpdateTile({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(xcUpdateStateProvider).value;
    final version = ref.watch(xcCurrentVersionProvider);
    return ListTile(
      leading: const GlyphIcon(AppGlyphs.refresh),
      title: const Text('检查客户端更新'),
      subtitle: Text(
        state?.isForced == true
            ? '需要完成更新后恢复连接'
            : version == null
            ? '获取客户端版本信息'
            : '当前版本 $version',
      ),
      onTap: () => unawaited(checkXcUpdate(context, ref)),
    );
  }
}
