import 'package:fl_clash/providers/providers.dart' as app;
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:fl_clash/views/proxies/proxies.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';

import '../providers.dart';
import '../connection_gate.dart';
import '../probe/region_classifier.dart';
import 'account/account_pages.dart';
import 'account/record_pages.dart';
import 'account/support_pages.dart';
import 'common/format.dart';
import 'common/commerce.dart';
import 'common/errors.dart';
import 'common/rich_content.dart';
import 'common/widgets.dart';
import 'store/store_pages.dart';
import 'restriction_notice.dart';

/// Keeps panel money/configuration and post-purchase effects inside one login.
/// The scope wraps the Navigator, including routes opened from the shell.
class XcCommerceHost extends ConsumerStatefulWidget {
  const XcCommerceHost({super.key, required this.child});
  final Widget child;
  @override
  ConsumerState<XcCommerceHost> createState() => _XcCommerceHostState();
}

class _XcCommerceHostState extends ConsumerState<XcCommerceHost> {
  XboardApi? _api;
  Future<Map<String, dynamic>>? _config;
  late final _entitlements = XcEntitlementRefresh(_refreshEntitlements);

  Future<void> _refreshEntitlements() async {
    final runtime = await ref.read(xcRuntimeProvider.future);
    if (!mounted || !runtime.session.state.isLoggedIn) return;
    final generation = runtime.session.generation;
    final actions = ref.read(xcActionsProvider);
    await actions.refreshUser();
    if (!mounted ||
        runtime.session.generation != generation ||
        !runtime.session.state.isLoggedIn) {
      return;
    }
    final previous = runtime.sync.status;
    final result = await actions.syncNow();
    if (!mounted || runtime.session.generation != generation) return;
    // A throttled or already-running pull may predate the purchase.
    if (previous.phase == SyncPhase.syncing ||
        previous.phase == SyncPhase.blocked ||
        result.lastSuccess == previous.lastSuccess) {
      runtime.sync.requestSync();
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.watch(xcApiProvider);
    if (api == null) {
      return const Scaffold(
        body: Center(child: CommonCircleLoading.page(semanticLabel: '正在加载')),
      );
    }
    if (!identical(_api, api)) {
      _api = api;
      _config = api.commConfig();
    }
    return FutureBuilder<Map<String, dynamic>>(
      future: _config,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 12,
                children: [
                  Text(xcErrorText(snapshot.error!)),
                  TextButton(
                    onPressed: () => setState(() => _config = api.commConfig()),
                    child: const Text('重试加载站点配置'),
                  ),
                ],
              ),
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(
              child: CommonCircleLoading.page(semanticLabel: '正在加载'),
            ),
          );
        }
        return XcCommerceScope(
          currency: XcCurrency.fromConfig(snapshot.data!),
          entitlements: _entitlements,
          child: widget.child,
        );
      },
    );
  }
}

class XcAppShell extends ConsumerStatefulWidget {
  const XcAppShell({super.key, this.settingsTiles = const []});
  final List<Widget> settingsTiles;
  @override
  ConsumerState<XcAppShell> createState() => _XcAppShellState();
}

class _XcAppShellState extends ConsumerState<XcAppShell> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final api = ref.watch(xcApiProvider);
    final brand = ref.watch(xcBrandConfigProvider);
    final session = ref.watch(xcSessionProvider).value;
    final sync = ref.watch(xcSyncStatusProvider).value;
    final actions = ref.read(xcActionsProvider);
    if (api == null || session == null) {
      return const Scaffold(
        body: Center(child: CommonCircleLoading.page(semanticLabel: '正在加载')),
      );
    }
    final body = switch (_index) {
      0 => XcHomePage(
        api: api,
        running: ref.watch(app.isStartProvider),
        canConnect: ref.watch(xcConnectionBlockProvider) == null,
        selectedNodes: ref.watch(app.selectedMapProvider),
        syncMessage:
            ref.watch(xcConnectionBlockProvider) ??
            sync?.message ??
            switch (sync?.phase) {
              SyncPhase.syncing => '正在安全同步节点…',
              SyncPhase.ok => '节点已安全同步',
              _ => '等待节点同步',
            },
        onConnect: () =>
            ref.read(app.commonActionProvider.notifier).toggleRunning(),
        onPlans: () => setState(() => _index = 2),
        onSync: () async {
          await actions.syncNow();
        },
      ),
      1 =>
        sync?.phase == SyncPhase.blocked
            ? XcRestrictedNodesView(
                status: sync!,
                onCheck: () async {
                  await actions.syncNow();
                },
              )
            : const ProxiesView(),
      2 => XcPlansPage(api: api, embedded: true),
      _ => XcAccountPage(
        api: api,
        user: session.user ?? {},
        panelWebUrl: brand.panelWebUrl,
        onLogout: actions.logout,
        onSync: () async {
          await actions.syncNow();
        },
        onRefreshUser: actions.refreshUser,
        onRegisterDevice: actions.registerDevice,
        settingsTiles: widget.settingsTiles,
      ),
    };
    return XcShellLayout(
      title: brand.displayName,
      selectedIndex: _index,
      onSelected: (index) => setState(() => _index = index),
      banner: Column(
        children: [
          XcRestrictionNotice(
            status: sync ?? const SyncStatus(),
            onCheck: () async {
              await actions.syncNow();
            },
            onPlans: () => setState(() => _index = 2),
            onTickets: () => xcPush(context, XcTicketsPage(api: api)),
          ),
          XcNoticeBanner(notice: ref.watch(xcNoticeProvider)),
          if (session.deviceError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    spacing: 8,
                    children: [
                      Text(session.deviceError!.displayMessage),
                      Wrap(
                        spacing: 8,
                        children: [
                          TextButton(
                            onPressed: () => xcPush(
                              context,
                              XcDevicesPage(
                                api: api,
                                onLogout: actions.logout,
                                onRegister: actions.registerDevice,
                              ),
                            ),
                            child: const Text('管理登录设备'),
                          ),
                          XcTaskButton(
                            label: '重试注册',
                            tonal: true,
                            action: actions.registerDevice,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      child: body,
    );
  }
}

class XcShellLayout extends StatelessWidget {
  const XcShellLayout({
    super.key,
    required this.title,
    required this.selectedIndex,
    required this.onSelected,
    required this.child,
    this.banner,
  });
  final String title;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;
  final Widget? banner;
  static const labels = ['首页', '节点', '套餐', '我的'];
  static const glyphs = [
    AppGlyphs.dashboard,
    AppGlyphs.proxies,
    AppGlyphs.resources,
    AppGlyphs.profiles,
  ];
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= 800;
      return Scaffold(
        backgroundColor: SurfaceLevel.page.colorOf(
          Theme.of(context).colorScheme,
        ),
        appBar: AppBar(
          title: Text(title, style: AppTextStyle.pageTitle.of(context)),
        ),
        body: Row(
          children: [
            if (desktop)
              NavigationRail(
                backgroundColor: SurfaceLevel.page.colorOf(
                  Theme.of(context).colorScheme,
                ),
                extended: constraints.maxWidth >= 1100,
                selectedIndex: selectedIndex,
                onDestinationSelected: onSelected,
                destinations: [
                  for (var index = 0; index < labels.length; index++)
                    NavigationRailDestination(
                      icon: GlyphIcon(glyphs[index]),
                      selectedIcon: GlyphIcon(glyphs[index], fill: 1),
                      label: Text(labels[index]),
                    ),
                ],
              ),
            Expanded(
              child: Column(
                children: [
                  if (banner != null)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: constraints.maxHeight * 0.55,
                      ),
                      child: SingleChildScrollView(child: banner!),
                    ),
                  Expanded(child: child),
                ],
              ),
            ),
          ],
        ),
        bottomNavigationBar: desktop
            ? null
            : NavigationBar(
                selectedIndex: selectedIndex,
                onDestinationSelected: onSelected,
                destinations: [
                  for (var index = 0; index < labels.length; index++)
                    NavigationDestination(
                      icon: GlyphIcon(glyphs[index]),
                      selectedIcon: GlyphIcon(glyphs[index], fill: 1),
                      label: labels[index],
                    ),
                ],
              ),
      );
    },
  );
}

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

class XcHomePage extends StatefulWidget {
  const XcHomePage({
    super.key,
    required this.api,
    required this.running,
    required this.canConnect,
    required this.selectedNodes,
    required this.syncMessage,
    required this.onConnect,
    required this.onPlans,
    required this.onSync,
  });
  final XboardApi api;
  final bool running;
  final bool canConnect;
  final Map<String, String> selectedNodes;
  final String syncMessage;
  final VoidCallback onConnect;
  final VoidCallback onPlans;
  final Future<void> Function() onSync;
  @override
  State<XcHomePage> createState() => _XcHomePageState();
}

class _XcHomePageState extends State<XcHomePage> {
  Future<XcHomeData> _load() async {
    final data = await Future.wait<Object?>([
      widget.api.userInfo(),
      widget.api.subscribeSummary(),
      widget.api.stat(),
      widget.api.notices(),
      widget.api.trafficCycle(historySize: 1, eventsSize: 1),
    ]);
    return XcHomeData(
      user: data[0] as Map<String, dynamic>,
      summary: data[1] as Map<String, dynamic>,
      stats: data[2] as List<int>,
      notices: (data[3] as XbPage).items,
      cycle: data[4] as Map<String, dynamic>?,
    );
  }

  @override
  Widget build(BuildContext context) => XcLoad<XcHomeData>(
    load: _load,
    builder: (context, data, refresh) => XcHomePanel(
      data: data,
      running: widget.running,
      canConnect: widget.canConnect,
      selectedNodes: widget.selectedNodes,
      syncMessage: widget.syncMessage,
      onConnect: widget.onConnect,
      onPlans: widget.onPlans,
      onSync: () async {
        await widget.onSync();
        await refresh();
      },
      onOrders: () => xcPush(context, XcOrdersPage(api: widget.api)),
      onTickets: () => xcPush(context, XcTicketsPage(api: widget.api)),
      onNotices: () => xcPush(context, XcNoticesPage(api: widget.api)),
      onCycle: () => xcPush(context, XcTrafficCyclePage(api: widget.api)),
      onResetPackage: () async {
        final id = XcFormat.toInt(data.summary['plan_id']);
        if (id == null) return;
        final plan = await widget.api.plan(id);
        if (context.mounted) {
          xcPush(
            context,
            XcPlanDetailPage(
              api: widget.api,
              plan: plan,
              initialPeriod: PlanPeriod.reset,
            ),
          );
        }
      },
    ),
  );
}

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
  });
  final XcHomeData data;
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
  @override
  Widget build(BuildContext context) {
    final summary = data.summary;
    final plan = summary['plan'] is Map
        ? Map<String, dynamic>.from(summary['plan'] as Map)
        : <String, dynamic>{};
    final used =
        (XcFormat.toDouble(summary['u']) ?? 0) +
        (XcFormat.toDouble(summary['d']) ?? 0);
    final total = XcFormat.toDouble(summary['transfer_enable']) ?? 0;
    final ratio = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final current = data.cycle?['current'];
    final reset = current is Map && current['ends_at'] != null
        ? XcFormat.date(current['ends_at'])
        : summary['next_reset_at'] != null
        ? XcFormat.date(summary['next_reset_at'])
        : '${summary['reset_day'] ?? '—'} 天后';
    final stats = data.stats;
    return xcList([
      XcSection(
        title: running ? '连接已开启' : '准备好，连接世界',
        children: [
          Text(syncMessage, style: AppTextStyle.callout.of(context)),
          if (selectedNodes.isEmpty) const Text('节点同步后，请在“节点”中选择线路'),
          for (final entry in selectedNodes.entries.take(3))
            XcValue(entry.key, entry.value),
          if (selectedNodes.values.firstOrNull case final name?
              when classifyRegion(name) != null)
            XcValue('当前地区', classifyRegion(name)),
          FilledButton(
            onPressed: running || canConnect ? onConnect : null,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(running ? '断开连接' : '连接'),
            ),
          ),
          XcTaskButton(label: '同步节点', tonal: true, action: onSync),
        ],
      ),
      XcSection(
        title: '${plan['name'] ?? '尚未订购套餐'}',
        children: [
          XcValue(
            '已用 / 总流量',
            '${XcFormat.bytes(used)} / ${XcFormat.bytes(total)}',
          ),
          LinearProgressIndicator(
            value: ratio,
            color: ratio >= 0.8 ? Theme.of(context).colorScheme.error : null,
          ),
          XcValue(
            '剩余流量',
            XcFormat.bytes((total - used).clamp(0, double.infinity)),
          ),
          XcValue('到期时间', XcFormat.expiry(summary['expired_at'])),
          XcValue('下次重置', reset),
          XcValue(
            '在线设备 / 限制',
            '${summary['online_count'] ?? summary['alive_ip'] ?? 0} / ${summary['device_limit'] ?? '不限'}',
          ),
          if (summary['speed_limit'] != null)
            XcValue('速率限制', '${summary['speed_limit']} Mbps'),
          XcValue('账户余额', context.xcMoney(data.user['balance'])),
          if (ratio >= 0.8) const Text('本期流量即将用尽，请留意剩余用量。'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: onPlans,
                child: const Text('购买 / 续费套餐'),
              ),
              TextButton(onPressed: onCycle, child: const Text('查看流量周期')),
              if (XcPlans.resetPriceCents(plan) != null)
                XcTaskButton(
                  label: '购买流量重置包',
                  tonal: true,
                  action: onResetPackage,
                ),
            ],
          ),
        ],
      ),
      if (stats.isNotEmpty && stats[0] > 0 || stats.length > 1 && stats[1] > 0)
        XcSection(
          children: [
            if (stats.isNotEmpty && stats[0] > 0)
              XcMenuRow(title: '${stats[0]} 笔待支付订单', onTap: onOrders),
            if (stats.length > 1 && stats[1] > 0)
              XcMenuRow(title: '${stats[1]} 个未关闭工单', onTap: onTickets),
          ],
        ),
      XcSection(
        title: '最新公告',
        children: [
          if (data.notices.isEmpty) const Text('暂无公告'),
          for (final notice in data.notices.take(1)) ...[
            Text(
              '${notice['title'] ?? '站点公告'}',
              style: AppTextStyle.headline.of(context),
            ),
            XcRichContent(content: '${notice['content'] ?? ''}'),
          ],
          TextButton(onPressed: onNotices, child: const Text('查看全部公告')),
        ],
      ),
    ]);
  }
}

class XcNoticeBanner extends StatefulWidget {
  const XcNoticeBanner({super.key, required this.notice});
  final XcNotice? notice;
  @override
  State<XcNoticeBanner> createState() => _XcNoticeBannerState();
}

class _XcNoticeBannerState extends State<XcNoticeBanner> {
  final _dismissed = <String>{};
  @override
  Widget build(BuildContext context) {
    final notice = widget.notice;
    if (notice == null || _dismissed.contains(notice.id)) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Card(
        elevation: 0,
        color: SurfaceLevel.card.colorOf(Theme.of(context).colorScheme),
        child: ListTile(
          title: Text(
            notice.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: const Text('查看公告详情'),
          trailing: IconButton(
            tooltip: '关闭公告',
            icon: const GlyphIcon(AppGlyphs.close),
            onPressed: () => setState(() => _dismissed.add(notice.id)),
          ),
          onTap: () => xcPush(
            context,
            XcPage(
              title: notice.title,
              child: xcList([
                XcSection(children: [XcRichContent(content: notice.body)]),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}
