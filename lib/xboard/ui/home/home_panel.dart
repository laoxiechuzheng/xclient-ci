import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/skeleton.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/sync/subscription_sync.dart' show SyncPhase;
import '../../probe/region_classifier.dart';
import '../common/commerce.dart';
import '../common/components.dart';
import '../common/errors.dart';
import '../common/format.dart';
import '../common/motion.dart';
import '../common/tokens.dart';
import '../common/widgets.dart';
import 'connection_orb.dart';

class XcHomeData {
  const XcHomeData({
    required this.user,
    required this.summary,
    this.stats = const [],
    this.notices = const [],
    this.cycle,
  });
  final Map<String, dynamic> user;
  final Map<String, dynamic> summary;
  final List<int> stats;
  final List<Map<String, dynamic>> notices;
  final Map<String, dynamic>? cycle;
}

/// The home screen. The connect control never waits for account data; the
/// account sections show a skeleton, then the data or a retryable error.
class XcHomePanel extends StatelessWidget {
  const XcHomePanel({
    super.key,
    required this.data,
    required this.running,
    required this.canConnect,
    required this.selectedNodes,
    required this.syncMessage,
    required this.onConnect,
    required this.onPlans,
    required this.onSync,
    required this.onOrders,
    required this.onTickets,
    required this.onNotices,
    required this.onCycle,
    required this.onResetPackage,
    this.syncPhase,
    this.blockReason,
    this.error,
    this.onRetry,
    this.onNodes,
    this.sessionTimer,
    this.now,
  });
  final XcHomeData? data;
  final bool running;
  final bool canConnect;
  final Map<String, String> selectedNodes;
  final String syncMessage;
  final VoidCallback onConnect;
  final VoidCallback onPlans;
  final Future<void> Function() onSync;
  final VoidCallback onOrders;
  final VoidCallback onTickets;
  final VoidCallback onNotices;
  final VoidCallback onCycle;
  final Future<void> Function() onResetPackage;
  final SyncPhase? syncPhase;
  final String? blockReason;
  final Object? error;
  final VoidCallback? onRetry;
  final VoidCallback? onNodes;
  final Widget? sessionTimer;
  final DateTime Function()? now;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final width = constraints.maxWidth;
      final gutter = XcSpace.gutterOf(width);
      final wide = width >= 960;
      final clock = now?.call() ?? DateTime.now();
      final header = _Greeting(
        name: _nameOf(data?.user['email']),
        hour: clock.hour,
        phase: syncPhase,
        onSync: onSync,
      );
      final hero = _ConnectionHero(
        running: running,
        canConnect: canConnect,
        onConnect: onConnect,
        line: selectedNodes.values.firstOrNull,
        blockReason: blockReason ?? syncMessage,
        sessionTimer: sessionTimer,
        onNodes: onNodes,
        orbSize: wide
            ? 212
            : constraints.maxHeight < 680
            ? 148
            : width < 380
            ? 164
            : 184,
      );
      final account = data;
      final tips = account == null ? const <Widget>[] : _tips(context, clock);
      final details = <Widget>[
        if (account != null)
          _PlanCard(
            data: account,
            now: clock,
            onPlans: onPlans,
            onCycle: onCycle,
            onResetPackage: onResetPackage,
          )
        else if (error case final error?)
          XcCallout(
            tone: XcTone.danger,
            glyph: AppGlyphs.wifiOff,
            title: '账户信息暂时没有加载出来',
            message: '${xcErrorText(error)}。连接功能不受影响。',
            actions: [
              if (onRetry != null)
                XcButton(
                  label: '重试',
                  size: XcButtonSize.small,
                  variant: XcButtonVariant.secondary,
                  onPressed: onRetry,
                ),
            ],
          )
        else
          const _PlanSkeleton(),
        if (account != null)
          _NoticeCard(notices: account.notices, onNotices: onNotices),
      ];
      final sections = wide
          ? [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: XcSpace.xl,
                children: [
                  Expanded(flex: 5, child: _stack([hero, ...tips], start: 1)),
                  Expanded(flex: 6, child: _stack(details, start: 2)),
                ],
              ),
            ]
          : [hero, ...tips, ...details];
      return SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.fromLTRB(gutter, XcSpace.xs, gutter, XcSpace.xl),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: XcSpace.contentWidth),
            child: wide
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: XcSpace.lg,
                    children: [
                      XcEntrance(child: header),
                      ...sections,
                    ],
                  )
                : _stack([header, ...sections]),
          ),
        ),
      );
    },
  );

  Widget _stack(List<Widget> children, {int start = 0}) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: XcSpace.md,
    children: [
      for (final (index, child) in children.indexed)
        XcEntrance(index: start + index, child: child),
    ],
  );

  List<Widget> _tips(BuildContext context, DateTime clock) {
    final data = this.data!;
    final summary = data.summary;
    final plan = _planOf(summary);
    final days = XcFormat.daysLeft(summary['expired_at'], now: clock);
    final usage = _Usage.of(summary);
    final pending = data.stats.firstOrNull ?? 0;
    final tickets = data.stats.length > 1 ? data.stats[1] : 0;
    final canReset = XcPlans.resetPriceCents(plan) != null;
    final tips = <Widget>[
      if (plan['name'] == null)
        XcCallout(
          glyph: AppGlyphs.sparkle,
          title: '还没有可用套餐',
          message: '选一个套餐，支付后即可一键连接。',
          actions: [
            XcButton(
              label: '选择套餐',
              size: XcButtonSize.small,
              onPressed: onPlans,
            ),
          ],
        )
      else if (days != null && days < 0)
        XcCallout(
          tone: XcTone.danger,
          glyph: AppGlyphs.clock,
          title: '套餐已过期',
          message: '续费后即可继续使用全部线路。',
          actions: [
            XcButton(
              label: '立即续费',
              size: XcButtonSize.small,
              onPressed: onPlans,
            ),
          ],
        ),
      if (pending > 0)
        XcCallout(
          glyph: AppGlyphs.resources,
          title: '有 $pending 笔订单待支付',
          message: '完成支付后，套餐会自动生效。',
          onTap: onOrders,
          actions: [
            XcButton(
              label: '去支付',
              size: XcButtonSize.small,
              variant: XcButtonVariant.secondary,
              onPressed: onOrders,
            ),
          ],
        ),
      if (plan['name'] != null && usage.total > 0 && usage.ratio >= 0.8)
        XcCallout(
          tone: usage.ratio >= 0.95 ? XcTone.danger : XcTone.warning,
          glyph: AppGlyphs.dataUsage,
          title: '本期流量已用 ${(usage.ratio * 100).floor()}%',
          message: canReset
              ? '还剩 ${XcFormat.bytes(usage.remaining)}，可购买流量重置包立即恢复。'
              : '还剩 ${XcFormat.bytes(usage.remaining)}，可升级到更大流量的套餐。',
          actions: [
            if (canReset)
              XcTaskButton(
                label: '购买流量重置包',
                size: XcButtonSize.small,
                variant: XcButtonVariant.secondary,
                action: onResetPackage,
              )
            else
              XcButton(
                label: '升级套餐',
                size: XcButtonSize.small,
                variant: XcButtonVariant.secondary,
                onPressed: onPlans,
              ),
          ],
        ),
      if (days != null && days >= 0 && days <= 7)
        XcCallout(
          tone: XcTone.warning,
          glyph: AppGlyphs.clock,
          title: days == 0 ? '套餐今天到期' : '套餐 $days 天后到期',
          message: '到期后将无法连接，建议提前续费。',
          actions: [
            XcButton(
              label: '续费套餐',
              size: XcButtonSize.small,
              variant: XcButtonVariant.secondary,
              onPressed: onPlans,
            ),
          ],
        ),
      if (tickets > 0)
        XcCallout(
          tone: XcTone.neutral,
          glyph: AppGlyphs.compose,
          title: '$tickets 个工单处理中',
          message: '可以随时查看客服的处理进度。',
          onTap: onTickets,
        ),
    ];
    return tips.take(2).toList();
  }

  static String? _nameOf(Object? email) {
    final text = '${email ?? ''}';
    final at = text.indexOf('@');
    if (at <= 0) return null;
    final name = text.substring(0, at);
    return name.length > 12 ? '${name.substring(0, 12)}…' : name;
  }
}

Map<String, dynamic> _planOf(Map<String, dynamic> summary) =>
    summary['plan'] is Map
    ? Map<String, dynamic>.from(summary['plan'] as Map)
    : <String, dynamic>{};

class _Usage {
  const _Usage(this.used, this.total);

  factory _Usage.of(Map<String, dynamic> summary) => _Usage(
    (XcFormat.toDouble(summary['u']) ?? 0) +
        (XcFormat.toDouble(summary['d']) ?? 0),
    XcFormat.toDouble(summary['transfer_enable']) ?? 0,
  );

  final double used;
  final double total;

  double get ratio => total > 0 ? (used / total).clamp(0.0, 1.0) : 0;

  double get remaining => (total - used).clamp(0, double.infinity);
}

class _Greeting extends StatelessWidget {
  const _Greeting({
    required this.name,
    required this.hour,
    required this.phase,
    required this.onSync,
  });

  final String? name;
  final int hour;
  final SyncPhase? phase;
  final Future<void> Function() onSync;

  @override
  Widget build(BuildContext context) {
    final greeting = switch (hour) {
      >= 5 && < 11 => '早上好',
      >= 11 && < 13 => '中午好',
      >= 13 && < 18 => '下午好',
      _ => '晚上好',
    };
    return Padding(
      padding: const EdgeInsets.only(top: XcSpace.sm, bottom: XcSpace.xxs),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(greeting, style: XcType.pageTitle(context)),
                Text(
                  name == null ? '欢迎回来' : '欢迎回来，$name',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XcType.secondary(context),
                ),
              ],
            ),
          ),
          _SyncChip(phase: phase, onSync: onSync),
        ],
      ),
    );
  }
}

class _SyncChip extends StatefulWidget {
  const _SyncChip({required this.phase, required this.onSync});

  final SyncPhase? phase;
  final Future<void> Function() onSync;

  @override
  State<_SyncChip> createState() => _SyncChipState();
}

class _SyncChipState extends State<_SyncChip> {
  bool _busy = false;

  Future<void> _sync() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.onSync();
    } catch (error) {
      if (mounted) xcMessage(context, xcErrorText(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final busy = _busy || widget.phase == SyncPhase.syncing;
    final (label, tone, glyph) = busy
        ? ('正在同步', XcTone.accent, null)
        : switch (widget.phase) {
            SyncPhase.ok => ('节点已同步', XcTone.success, AppGlyphs.checkCircle),
            SyncPhase.error => ('同步失败', XcTone.danger, AppGlyphs.error),
            SyncPhase.blocked => ('同步受限', XcTone.warning, AppGlyphs.warning),
            _ => ('同步节点', XcTone.neutral, AppGlyphs.sync),
          };
    final color = colors.toneOf(tone);
    return Tooltip(
      message: '立即同步节点',
      child: Material(
        color: colors.softOf(tone),
        shape: AppShape.full,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: busy ? null : _sync,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 6,
                children: [
                  if (glyph case final glyph?)
                    GlyphIcon(glyph, size: 16, color: color, fill: 1)
                  else
                    CommonCircleLoading(size: 14, color: color),
                  XcSwap(
                    value: label,
                    child: Text(
                      label,
                      style: AppTextStyle.footnote
                          .of(context, emphasized: true)
                          .copyWith(
                            color: tone == XcTone.neutral
                                ? colors.title
                                : color,
                          ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ConnectionHero extends StatefulWidget {
  const _ConnectionHero({
    required this.running,
    required this.canConnect,
    required this.onConnect,
    required this.line,
    required this.blockReason,
    required this.sessionTimer,
    required this.onNodes,
    required this.orbSize,
  });

  final bool running;
  final bool canConnect;
  final VoidCallback onConnect;
  final String? line;
  final String blockReason;
  final Widget? sessionTimer;
  final VoidCallback? onNodes;
  final double orbSize;

  @override
  State<_ConnectionHero> createState() => _ConnectionHeroState();
}

class _ConnectionHeroState extends State<_ConnectionHero> {
  static const _pendingLimit = Duration(seconds: 20);

  bool? _target;
  Timer? _timeout;

  XcLinkState get _state {
    if (_target != null) {
      return _target! ? XcLinkState.connecting : XcLinkState.disconnecting;
    }
    if (widget.running) return XcLinkState.on;
    return widget.canConnect ? XcLinkState.off : XcLinkState.blocked;
  }

  @override
  void didUpdateWidget(_ConnectionHero oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_target != null && widget.running == _target) _settle();
  }

  void _settle() {
    _timeout?.cancel();
    _timeout = null;
    _target = null;
  }

  void _toggle() {
    if (_target != null) return;
    setState(() => _target = !widget.running);
    _timeout = Timer(_pendingLimit, () {
      if (mounted) setState(_settle);
    });
    widget.onConnect();
  }

  @override
  void dispose() {
    _timeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final state = _state;
    final (title, hint, label) = switch (state) {
      XcLinkState.off => (
        '未连接',
        widget.line == null ? '节点同步完成后即可连接' : '轻点上方按钮，一键开启加密连接',
        '连接',
      ),
      XcLinkState.connecting => ('正在连接…', '正在建立加密通道，请稍候', '正在连接'),
      XcLinkState.on => ('已安全连接', '你的网络流量正在加密传输', '断开连接'),
      XcLinkState.disconnecting => ('正在断开…', '正在安全关闭连接', '正在断开'),
      XcLinkState.blocked => ('暂时无法连接', widget.blockReason, '暂时无法连接'),
    };
    final titleColor = switch (state) {
      XcLinkState.on => colors.accent,
      XcLinkState.blocked => colors.warning,
      _ => colors.title,
    };
    return XcPanel(
      elevated: true,
      shape: XcRadius.hero,
      padding: const EdgeInsets.fromLTRB(
        XcSpace.lg,
        XcSpace.xl,
        XcSpace.lg,
        XcSpace.lg,
      ),
      child: Column(
        children: [
          XcConnectionOrb(
            state: state,
            size: widget.orbSize,
            semanticLabel: label,
            onPressed: widget.running || widget.canConnect ? _toggle : null,
          ),
          const SizedBox(height: XcSpace.md),
          XcSwap(
            value: title,
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: AppTextStyle.title2
                  .of(context, emphasized: true)
                  .copyWith(color: titleColor),
            ),
          ),
          const SizedBox(height: XcSpace.xxs),
          XcSwap(
            value: state == XcLinkState.on ? 'session' : hint,
            child: state == XcLinkState.on && widget.sessionTimer != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      GlyphIcon(
                        AppGlyphs.lock,
                        size: 14,
                        color: colors.success,
                        fill: 1,
                      ),
                      Text('加密连接已持续', style: XcType.secondary(context)),
                      DefaultTextStyle.merge(
                        style: XcType.secondary(
                          context,
                        ).copyWith(color: colors.title),
                        child: widget.sessionTimer!,
                      ),
                    ],
                  )
                : Text(
                    hint,
                    textAlign: TextAlign.center,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: XcType.secondary(context),
                  ),
          ),
          const SizedBox(height: XcSpace.lg),
          _LinePill(line: widget.line, onTap: widget.onNodes),
        ],
      ),
    );
  }
}

class _LinePill extends StatelessWidget {
  const _LinePill({required this.line, required this.onTap});

  final String? line;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final region = line == null ? null : classifyRegion(line!);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Material(
        color: colors.block,
        shape: XcRadius.tile,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
            child: Row(
              spacing: XcSpace.sm,
              children: [
                DecoratedBox(
                  decoration: ShapeDecoration(
                    color: colors.card,
                    shape: AppShape.circle,
                  ),
                  child: SizedBox.square(
                    dimension: 40,
                    child: Center(
                      child: region == null
                          ? GlyphIcon(
                              AppGlyphs.proxies,
                              size: 20,
                              color: colors.muted,
                            )
                          : Text(
                              region,
                              style: AppTextStyle.footnote
                                  .of(context, emphasized: true)
                                  .copyWith(color: colors.accent),
                            ),
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 1,
                    children: [
                      Text('当前线路', style: XcType.caption(context)),
                      Text(
                        line ?? '还没有选择线路',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: XcType.headline(context),
                      ),
                    ],
                  ),
                ),
                if (onTap != null) ...[
                  if (MediaQuery.sizeOf(context).width >= 380)
                    Text(
                      line == null ? '去选择' : '切换',
                      style: AppTextStyle.subheadline
                          .of(context, emphasized: true)
                          .copyWith(color: colors.accent),
                    ),
                  GlyphIcon(
                    AppGlyphs.chevronForward,
                    size: 16,
                    color: colors.accent,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard({
    required this.data,
    required this.now,
    required this.onPlans,
    required this.onCycle,
    required this.onResetPackage,
  });

  final XcHomeData data;
  final DateTime now;
  final VoidCallback onPlans;
  final VoidCallback onCycle;
  final Future<void> Function() onResetPackage;

  @override
  Widget build(BuildContext context) {
    final summary = data.summary;
    final plan = _planOf(summary);
    final usage = _Usage.of(summary);
    final days = XcFormat.daysLeft(summary['expired_at'], now: now);
    final current = data.cycle?['current'];
    final reset = current is Map && current['ends_at'] != null
        ? XcFormat.date(current['ends_at'], withTime: false)
        : summary['next_reset_at'] != null
        ? XcFormat.date(summary['next_reset_at'], withTime: false)
        : summary['reset_day'] != null
        ? '${summary['reset_day']} 天后'
        : '不重置';
    final ringTone = usage.ratio >= 0.95
        ? XcTone.danger
        : usage.ratio >= 0.8
        ? XcTone.warning
        : XcTone.accent;
    final (badge, badgeTone) = switch (days) {
      null => ('长期有效', XcTone.success),
      < 0 => ('已过期', XcTone.danger),
      <= 7 => ('剩 $days 天', XcTone.warning),
      _ => ('剩 $days 天', XcTone.neutral),
    };
    final speed = summary['speed_limit'];
    final hasPlan = plan['name'] != null;
    return XcPanel(
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: XcSpace.sm,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    Text('我的套餐', style: XcType.label(context)),
                    Text(
                      '${plan['name'] ?? '尚未订购套餐'}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: XcType.title(context),
                    ),
                  ],
                ),
              ),
              if (hasPlan) XcBadge(label: badge, tone: badgeTone),
            ],
          ),
          const SizedBox(height: XcSpace.lg),
          LayoutBuilder(
            builder: (context, constraints) {
              final ring = (constraints.maxWidth * 0.4).clamp(116.0, 148.0);
              return Row(
                children: [
                  XcRing(
                    value: usage.total > 0 ? 1 - usage.ratio : 0,
                    size: ring,
                    stroke: ring * 0.085,
                    tone: ringTone,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('剩余流量', style: XcType.caption(context)),
                        XcAnimatedNumber(
                          value: usage.remaining,
                          format: XcFormat.bytes,
                          style: XcType.metric(context),
                        ),
                        Text(
                          usage.total > 0
                              ? '共 ${XcFormat.bytes(usage.total)}'
                              : '未开通',
                          style: XcType.caption(context),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: XcSpace.lg),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: XcSpace.md,
                      children: [
                        XcMetric(
                          label: '已用',
                          value: XcFormat.bytes(usage.used),
                          tone: ringTone == XcTone.accent
                              ? XcTone.neutral
                              : ringTone,
                          caption: usage.total > 0
                              ? '本期 ${(usage.ratio * 100).toStringAsFixed(usage.ratio < 0.1 ? 1 : 0)}%'
                              : null,
                        ),
                        XcMetric(
                          label: '到期时间',
                          value: days == null
                              ? '长期有效'
                              : XcFormat.date(
                                  summary['expired_at'],
                                  withTime: false,
                                ),
                        ),
                        XcMetric(label: '下次重置', value: reset),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: XcSpace.lg),
          Row(
            spacing: XcSpace.xs,
            children: [
              Expanded(
                child: _Tile(
                  glyph: AppGlyphs.devices,
                  label: '在线设备',
                  value:
                      '${summary['online_count'] ?? summary['alive_ip'] ?? 0} / ${summary['device_limit'] ?? '不限'}',
                ),
              ),
              Expanded(
                child: _Tile(
                  glyph: AppGlyphs.account,
                  label: '账户余额',
                  value: context.xcMoney(data.user['balance']),
                ),
              ),
              if (speed != null)
                Expanded(
                  child: _Tile(
                    glyph: AppGlyphs.speed,
                    label: '速率上限',
                    value: '$speed Mbps',
                  ),
                ),
            ],
          ),
          const SizedBox(height: XcSpace.md),
          Wrap(
            spacing: XcSpace.xs,
            runSpacing: XcSpace.xs,
            children: [
              XcButton(
                label: hasPlan ? '续费 / 升级' : '选择套餐',
                size: XcButtonSize.small,
                variant: hasPlan
                    ? XcButtonVariant.secondary
                    : XcButtonVariant.primary,
                onPressed: onPlans,
              ),
              XcButton(
                label: '流量明细',
                size: XcButtonSize.small,
                variant: XcButtonVariant.ghost,
                onPressed: onCycle,
              ),
              if (XcPlans.resetPriceCents(plan) != null && usage.ratio < 0.8)
                XcTaskButton(
                  label: '购买流量重置包',
                  size: XcButtonSize.small,
                  variant: XcButtonVariant.ghost,
                  action: onResetPackage,
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({required this.glyph, required this.label, required this.value});

  final Glyph glyph;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: ShapeDecoration(
      color: XcColors.of(context).block,
      shape: XcRadius.control,
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
      child: XcMetric(label: label, value: value, glyph: glyph),
    ),
  );
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({required this.notices, required this.onNotices});

  final List<Map<String, dynamic>> notices;
  final VoidCallback onNotices;

  static final _tags = RegExp(r'<[^>]*>|[#*_`>]|!?\[([^\]]*)\]\([^)]*\)');

  static String _plain(Object? content) => '${content ?? ''}'
      .replaceAllMapped(_tags, (match) => match[1] ?? ' ')
      .replaceAll(RegExp(r'&nbsp;|\s+'), ' ')
      .trim();

  @override
  Widget build(BuildContext context) {
    final notice = notices.firstOrNull;
    return XcPanel(
      elevated: true,
      onTap: onNotices,
      padding: const EdgeInsets.fromLTRB(
        XcSpace.lg,
        XcSpace.md,
        XcSpace.md,
        XcSpace.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: XcSpace.xs,
        children: [
          Row(
            children: [
              Expanded(child: Text('最新公告', style: XcType.label(context))),
              Text(
                '全部公告',
                style: AppTextStyle.footnote
                    .of(context, emphasized: true)
                    .copyWith(color: XcColors.of(context).accent),
              ),
              GlyphIcon(
                AppGlyphs.chevronForward,
                size: 14,
                color: XcColors.of(context).accent,
              ),
            ],
          ),
          if (notice == null)
            Text('暂无公告，有新消息会第一时间显示在这里。', style: XcType.secondary(context))
          else ...[
            Text(
              '${notice['title'] ?? '站点公告'}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: XcType.headline(context),
            ),
            Text(
              _plain(notice['content']),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: XcType.secondary(context),
            ),
          ],
        ],
      ),
    );
  }
}

class _PlanSkeleton extends StatelessWidget {
  const _PlanSkeleton();

  @override
  Widget build(BuildContext context) => Semantics(
    label: '正在加载套餐信息',
    child: XcPanel(
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: XcSpace.lg,
        children: [
          SkeletonText(width: 160, style: XcType.title(context)),
          Row(
            spacing: XcSpace.lg,
            children: [
              const SkeletonPill(width: 124, height: 124),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: XcSpace.md,
                  children: [
                    for (final width in const [96.0, 128.0, 80.0])
                      SkeletonText(width: width, style: XcType.value(context)),
                  ],
                ),
              ),
            ],
          ),
          const SkeletonPill(width: double.infinity, height: 52),
        ],
      ),
    ),
  );
}
