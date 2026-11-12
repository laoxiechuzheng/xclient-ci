import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import '../core/sync/subscription_sync.dart';
import 'common/components.dart';
import 'common/motion.dart';
import 'common/tokens.dart';
import 'common/widgets.dart';

const _restrictionTitle = '节点获取受到限制';
const _restrictionAdvice = '请关闭其他代理或更换网络后重新检查；如仍受限，请核对套餐状态或联系客服。';
const _restrictionSafety = '客户端已禁止连接和使用旧节点。账户、套餐购买和工单仍可正常使用。';
const _restrictionSteps = [
  '关闭其他代理或 VPN 软件',
  '更换网络，例如切换到移动数据',
  '回到这里点“重新检查”；仍受限请核对套餐或联系客服',
];

class _Steps extends StatelessWidget {
  const _Steps();

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: XcSpace.xs,
      children: [
        for (final (index, step) in _restrictionSteps.indexed)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: XcSpace.sm,
            children: [
              DecoratedBox(
                decoration: ShapeDecoration(
                  color: colors.softOf(XcTone.accent),
                  shape: const CircleBorder(),
                ),
                child: SizedBox.square(
                  dimension: 22,
                  child: Center(
                    child: Text(
                      '${index + 1}',
                      style: XcType.label(
                        context,
                      ).copyWith(color: colors.accent),
                    ),
                  ),
                ),
              ),
              Expanded(child: Text(step, style: XcType.body(context))),
            ],
          ),
      ],
    );
  }
}

class XcRestrictionNotice extends StatefulWidget {
  const XcRestrictionNotice({
    super.key,
    required this.status,
    required this.onCheck,
    required this.onPlans,
    required this.onTickets,
    this.now,
  });
  final SyncStatus status;
  final Future<void> Function() onCheck;
  final VoidCallback onPlans;
  final VoidCallback onTickets;
  final DateTime Function()? now;
  @override
  State<XcRestrictionNotice> createState() => _XcRestrictionNoticeState();
}

class _XcRestrictionNoticeState extends State<XcRestrictionNotice> {
  final _seen = <String>{};
  Timer? _clock;
  bool _promptOpen = false;
  BuildContext? _dialogContext;
  DateTime get _now => widget.now?.call() ?? DateTime.now();
  bool get _blocked => widget.status.phase == SyncPhase.blocked;
  String get _reason => widget.status.message ?? SyncMessages.blocked;
  int _seconds(DateTime? at) => at == null
      ? 0
      : ((at.difference(_now).inMilliseconds + 999) ~/ 1000).clamp(0, 86400);
  @override
  void initState() {
    super.initState();
    _updateClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _considerPrompt();
  }

  @override
  void didUpdateWidget(XcRestrictionNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateClock();
    _considerPrompt();
  }

  void _updateClock() {
    _clock?.cancel();
    _clock = null;
    if (!_blocked) return;
    if (_seconds(widget.status.retryAt) == 0 &&
        _seconds(widget.status.nextSync) == 0) {
      return;
    }
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_seconds(widget.status.retryAt) == 0 &&
          _seconds(widget.status.nextSync) == 0) {
        _clock?.cancel();
        _clock = null;
      }
    });
  }

  void _considerPrompt() {
    if (!_blocked) {
      final dialog = _dialogContext;
      if (dialog != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!dialog.mounted) return;
          final route = ModalRoute.of(dialog);
          if (route != null && route.isActive) {
            Navigator.of(dialog).removeRoute(route);
          }
        });
      }
      return;
    }
    if (_promptOpen) return;
    final reason =
        '${widget.status.blockedCode ?? 'subscription_restricted'}:$_reason';
    if (!_seen.add(reason)) return;
    _promptOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_blocked) {
        _promptOpen = false;
        return;
      }
      try {
        await showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (context) {
            _dialogContext = context;
            return AlertDialog(
              icon: const XcGlyphWell(
                glyph: AppGlyphs.vpn,
                tone: XcTone.danger,
                size: 56,
              ),
              title: const Text(_restrictionTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: XcSpace.md,
                  children: [
                    Text(_reason, style: XcType.body(context)),
                    Text('可以这样做', style: XcType.label(context)),
                    const _Steps(),
                    Text(_restrictionSafety, style: XcType.caption(context)),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('我知道了'),
                ),
              ],
            );
          },
        );
      } finally {
        _dialogContext = null;
        _promptOpen = false;
        if (mounted) _considerPrompt();
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_blocked) return const SizedBox.shrink();
    final wait = _seconds(widget.status.retryAt);
    final auto = _seconds(widget.status.nextSync);
    final colors = XcColors.of(context);
    return XcBannerSlot(
      child: XcEntrance(
        child: XcCallout(
          tone: XcTone.danger,
          filled: true,
          glyph: AppGlyphs.vpn,
          title: _restrictionTitle,
          actions: [
            XcTaskButton(
              label: '已更换网络，重新检查',
              size: XcButtonSize.small,
              glyph: AppGlyphs.refresh,
              enabled: wait == 0,
              action: widget.onCheck,
            ),
            XcButton(
              label: '查看详情',
              size: XcButtonSize.small,
              variant: XcButtonVariant.ghost,
              onPressed: () => xcPush(
                context,
                XcPage(
                  title: _restrictionTitle,
                  child: xcList([
                    XcPanel(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: XcSpace.md,
                        children: [
                          Text(_reason, style: XcType.body(context)),
                          const _Steps(),
                          Text(
                            _restrictionAdvice,
                            style: XcType.secondary(context),
                          ),
                          Text(
                            _restrictionSafety,
                            style: XcType.caption(context),
                          ),
                        ],
                      ),
                    ),
                  ]),
                ),
              ),
            ),
            XcButton(
              label: '联系客服',
              size: XcButtonSize.small,
              variant: XcButtonVariant.ghost,
              onPressed: widget.onTickets,
            ),
            XcButton(
              label: '账户与套餐',
              size: XcButtonSize.small,
              variant: XcButtonVariant.ghost,
              onPressed: widget.onPlans,
            ),
          ],
          children: [
            Text(
              _reason,
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
              style: XcType.body(context),
            ),
            Text(_restrictionSafety, style: XcType.caption(context)),
            if (widget.status.cleanupWarning case final warning?)
              Text(warning, style: XcType.caption(context)),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                spacing: 6,
                children: [
                  GlyphIcon(AppGlyphs.clock, size: 14, color: colors.muted),
                  Expanded(
                    child: Text(
                      wait > 0
                          ? '请等待 $wait 秒后再手动检查${auto > 0 ? '；约 $auto 秒后自动复查' : ''}'
                          : auto > 0
                          ? '约 $auto 秒后自动复查，也可在更换网络后手动检查'
                          : '更换网络后可重新检查，连续操作至少间隔 10 秒',
                      style: XcType.caption(context),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class XcRestrictedNodesView extends StatefulWidget {
  const XcRestrictedNodesView({
    super.key,
    required this.status,
    required this.onCheck,
    this.now,
  });
  final SyncStatus status;
  final Future<void> Function() onCheck;
  final DateTime Function()? now;
  @override
  State<XcRestrictedNodesView> createState() => _XcRestrictedNodesViewState();
}

class _XcRestrictedNodesViewState extends State<XcRestrictedNodesView> {
  Timer? _clock;
  bool get _ready =>
      widget.status.retryAt == null ||
      !(widget.now?.call() ?? DateTime.now()).isBefore(widget.status.retryAt!);
  void _updateClock() {
    _clock?.cancel();
    _clock = null;
    if (_ready) return;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_ready) {
        _clock?.cancel();
        _clock = null;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _updateClock();
  }

  @override
  void didUpdateWidget(XcRestrictedNodesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateClock();
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: constraints.maxHeight),
        child: XcStateView(
          tone: XcTone.danger,
          glyph: AppGlyphs.vpn,
          title: '暂时无法获取节点',
          message: widget.status.message ?? SyncMessages.blocked,
          action: XcTaskButton(
            label: '已更换网络，重新检查',
            glyph: AppGlyphs.refresh,
            enabled: _ready,
            action: widget.onCheck,
          ),
          children: [
            const SizedBox(height: XcSpace.xl),
            XcPanel(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: XcSpace.md,
                children: [
                  Text('可以这样做', style: XcType.label(context)),
                  const _Steps(),
                  Text(
                    '服务器允许下发后才会重新显示节点，旧缓存不会用于连接。',
                    style: XcType.caption(context),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
