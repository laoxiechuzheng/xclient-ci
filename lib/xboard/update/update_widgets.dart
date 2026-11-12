import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../providers.dart';
import '../ui/common/components.dart';
import '../ui/common/motion.dart';
import '../ui/common/tokens.dart';
import '../ui/common/widgets.dart';
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
    final colors = XcColors.of(context);
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
    final failed = state.phase == XcUpdatePhase.failed;
    final tone = failed
        ? XcTone.danger
        : state.isForced
        ? XcTone.warning
        : XcTone.accent;
    final progress = state.phase == XcUpdatePhase.downloading
        ? state.progress
        : null;
    final retryNote = state.retryAt != null ? '稍后会自动重试，也可以立即重试。' : null;
    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(
        horizontal: XcSpace.lg,
        vertical: XcSpace.xl,
      ),
      icon: XcGlyphWell(
        glyph: failed
            ? AppGlyphs.error
            : state.isForced
            ? AppGlyphs.warning
            : AppGlyphs.cloudDownload,
        tone: tone,
        size: 56,
      ),
      title: Text(
        state.isForced ? '需要更新客户端' : '客户端更新',
        style: XcType.title(context),
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: XcSpace.formWidth),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            spacing: XcSpace.sm,
            children: [
              XcSwap(
                value: stage,
                child: Text(
                  stage,
                  textAlign: TextAlign.center,
                  style: XcType.label(
                    context,
                  ).copyWith(color: colors.toneOf(tone)),
                ),
              ),
              if (currentVersion.isNotEmpty || state.decision.latest.isNotEmpty)
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: XcSpace.xs,
                  runSpacing: XcSpace.xs,
                  children: [
                    if (currentVersion.isNotEmpty)
                      XcBadge(label: '当前 $currentVersion'),
                    if (currentVersion.isNotEmpty &&
                        state.decision.latest.isNotEmpty)
                      GlyphIcon(
                        AppGlyphs.chevronForward,
                        size: 16,
                        color: colors.muted,
                      ),
                    if (state.decision.latest.isNotEmpty)
                      XcBadge(
                        label: '最新 ${state.decision.latest}',
                        tone: XcTone.accent,
                      ),
                  ],
                ),
              if (state.isForced)
                const XcCallout(
                  tone: XcTone.warning,
                  glyph: AppGlyphs.lock,
                  filled: true,
                  title: '完成更新后可恢复连接。',
                  message: '账号、购买和工单仍可使用。',
                ),
              if (state.decision.notes.isNotEmpty)
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colors.inset,
                    shape: XcRadius.tile,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(XcSpace.md),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: XcSpace.xxs,
                      children: [
                        Text('更新内容', style: XcType.label(context)),
                        Text(
                          state.decision.notes,
                          style: XcType.secondary(
                            context,
                          ).copyWith(color: colors.title),
                        ),
                      ],
                    ),
                  ),
                ),
              if (state.isBusy) ...[
                if (progress != null)
                  XcMeter(value: progress)
                else
                  ClipPath(
                    clipper: const ShapeBorderClipper(shape: AppShape.full),
                    child: LinearProgressIndicator(
                      minHeight: 8,
                      color: colors.accent,
                      backgroundColor: colors.inset,
                    ),
                  ),
                if (state.total > 0)
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${(state.received / 1048576).toStringAsFixed(1)} / ${(state.total / 1048576).toStringAsFixed(1)} MB',
                          style: XcType.caption(context).copyWith(
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                      if (progress != null)
                        Text(
                          '${(progress * 100).round()}%',
                          style: XcType.label(
                            context,
                          ).copyWith(color: colors.accent),
                        ),
                    ],
                  ),
              ],
              if (state.message case final message? when failed)
                XcCallout(
                  tone: XcTone.danger,
                  glyph: AppGlyphs.error,
                  title: message,
                  message: retryNote,
                )
              else ...[
                if (state.message case final message?)
                  Text(
                    message,
                    textAlign: TextAlign.center,
                    style: XcType.caption(context),
                  ),
                if (retryNote case final note?)
                  Text(
                    note,
                    textAlign: TextAlign.center,
                    style: XcType.caption(context),
                  ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: onClose,
          child: Text(state.isBusy ? '后台更新' : '稍后'),
        ),
        if (state.phase == XcUpdatePhase.needsPermission)
          XcButton(
            label: '允许安装',
            glyph: AppGlyphs.check,
            onPressed: onPermission,
          )
        else if (state.decision.hasUpdate && !state.isBusy)
          XcButton(
            label: failed ? '重试更新' : '立即更新',
            glyph: failed ? AppGlyphs.refresh : AppGlyphs.cloudDownload,
            onPressed: onUpdate,
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
    final forced = state?.isForced == true;
    return XcMenuRow(
      title: '检查客户端更新',
      glyph: forced ? AppGlyphs.warning : AppGlyphs.cloudDownload,
      tone: forced ? XcTone.warning : XcTone.accent,
      subtitle: forced
          ? '需要完成更新后恢复连接'
          : version == null
          ? '获取客户端版本信息'
          : '当前版本 $version',
      trailing: state?.decision.hasUpdate == true && !forced
          ? const XcBadge(label: '有新版本', tone: XcTone.accent)
          : null,
      onTap: () => unawaited(checkXcUpdate(context, ref)),
    );
  }
}
