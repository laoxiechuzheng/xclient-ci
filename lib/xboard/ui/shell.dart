import 'package:fl_clash/common/datetime.dart' show getTimeText;
import 'package:fl_clash/providers/providers.dart' as app;
import 'package:fl_clash/ui/icons/icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';

import '../providers.dart';
import '../connection_gate.dart';
import 'account/account_pages.dart';
import 'account/record_pages.dart';
import 'account/support_pages.dart';
import 'common/components.dart';
import 'common/format.dart';
import 'common/commerce.dart';
import 'common/errors.dart';
import 'common/motion.dart';
import 'common/rich_content.dart';
import 'common/tokens.dart';
import 'common/widgets.dart';
import 'home/home_panel.dart';
import 'nodes_view.dart';
import 'shell/navigation.dart';
import 'store/store_pages.dart';
import 'restriction_notice.dart';

export 'home/home_panel.dart' show XcHomeData, XcHomePanel;

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
            body: XcStateView(
              tone: XcTone.danger,
              glyph: AppGlyphs.wifiOff,
              title: '站点配置没有加载出来',
              message: '${xcErrorText(snapshot.error!)}。请检查网络后重试。',
              action: XcButton(
                label: '重试加载站点配置',
                glyph: AppGlyphs.refresh,
                onPressed: () => setState(() => _config = api.commConfig()),
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
    final block = ref.watch(xcConnectionBlockProvider);
    final body = switch (_index) {
      0 => XcHomePage(
        api: api,
        running: ref.watch(app.isStartProvider),
        canConnect: block == null,
        blockReason: block,
        syncPhase: sync?.phase,
        selectedNodes: ref.watch(app.selectedMapProvider),
        syncMessage:
            block ??
            sync?.message ??
            switch (sync?.phase) {
              SyncPhase.syncing => '正在安全同步节点…',
              SyncPhase.ok => '节点已安全同步',
              _ => '等待节点同步',
            },
        onConnect: () =>
            ref.read(app.commonActionProvider.notifier).toggleRunning(),
        onPlans: () => setState(() => _index = 2),
        onNodes: () => setState(() => _index = 1),
        onSync: () async {
          await actions.syncNow();
        },
        sessionTimer: const _XcSessionTimer(),
      ),
      1 =>
        sync?.phase == SyncPhase.blocked
            ? XcRestrictedNodesView(
                status: sync!,
                onCheck: () async {
                  await actions.syncNow();
                },
              )
            : const XcNodesView(),
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
    final (pageTitle, pageSubtitle) = switch (_index) {
      2 => ('选购套餐', '支付成功后自动生效，可随时续费或升级'),
      3 => ('我的账户', session.user?['email'] as String?),
      _ => (null, null),
    };
    return XcShellLayout(
      title: brand.displayName,
      selectedIndex: _index,
      onSelected: (index) => setState(() => _index = index),
      pageTitle: pageTitle,
      pageSubtitle: pageSubtitle,
      banner: Column(
        mainAxisSize: MainAxisSize.min,
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
          if (session.deviceError case final error?)
            XcBannerSlot(
              child: XcCallout(
                tone: XcTone.danger,
                glyph: AppGlyphs.devices,
                filled: true,
                title: '这台设备还没有完成登记',
                message: error.displayMessage,
                actions: [
                  XcTaskButton(
                    label: '重试注册',
                    size: XcButtonSize.small,
                    action: actions.registerDevice,
                  ),
                  XcButton(
                    label: '管理登录设备',
                    size: XcButtonSize.small,
                    variant: XcButtonVariant.ghost,
                    onPressed: () => xcPush(
                      context,
                      XcDevicesPage(
                        api: api,
                        onLogout: actions.logout,
                        onRegister: actions.registerDevice,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
      child: body,
    );
  }
}

class _XcSessionTimer extends ConsumerWidget {
  const _XcSessionTimer();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Text(
    getTimeText(ref.watch(app.runTimeProvider)),
    style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
  );
}

class XcShellLayout extends StatelessWidget {
  const XcShellLayout({
    super.key,
    required this.title,
    required this.selectedIndex,
    required this.onSelected,
    required this.child,
    this.banner,
    this.pageTitle,
    this.pageSubtitle,
  });
  final String title;
  final int selectedIndex;
  final ValueChanged<int> onSelected;
  final Widget child;
  final Widget? banner;
  final String? pageTitle;
  final String? pageSubtitle;
  static const labels = ['首页', '节点', '套餐', '我的'];
  static const glyphs = [
    AppGlyphs.dashboard,
    AppGlyphs.proxies,
    AppGlyphs.resources,
    AppGlyphs.account,
  ];
  static final destinations = [
    for (var index = 0; index < labels.length; index++)
      XcDestination(glyph: glyphs[index], label: labels[index]),
  ];
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final desktop = constraints.maxWidth >= XcBreakpoint.desktop;
      final colors = XcColors.of(context);
      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (banner case final banner?)
            AnimatedSize(
              duration: XcMotion.of(context, XcMotion.standard),
              curve: XcMotion.emphasizedCurve,
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: constraints.maxHeight * 0.55,
                ),
                child: SingleChildScrollView(child: banner),
              ),
            ),
          Expanded(
            child: XcPageSwitcher(
              child: Column(
                key: ValueKey(selectedIndex),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (pageTitle case final pageTitle?)
                    _PageHeader(title: pageTitle, subtitle: pageSubtitle),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        ],
      );
      if (!desktop) {
        return Scaffold(
          backgroundColor: colors.page,
          body: SafeArea(bottom: false, child: content),
          bottomNavigationBar: XcBottomNav(
            destinations: destinations,
            selectedIndex: selectedIndex,
            onSelected: onSelected,
          ),
        );
      }
      return Scaffold(
        backgroundColor: colors.page,
        body: Row(
          children: [
            XcSideNav(
              key: const Key('xc-side-nav'),
              title: title,
              destinations: destinations,
              selectedIndex: selectedIndex,
              onSelected: onSelected,
              extended: constraints.maxWidth >= XcBreakpoint.wide,
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(child: SafeArea(left: false, child: content)),
          ],
        ),
      );
    },
  );
}

class _PageHeader extends StatelessWidget {
  const _PageHeader({required this.title, this.subtitle});
  final String title;
  final String? subtitle;
  @override
  Widget build(BuildContext context) {
    final gutter = XcSpace.gutterOf(MediaQuery.sizeOf(context).width);
    return Padding(
      padding: EdgeInsets.fromLTRB(gutter, XcSpace.lg, gutter, XcSpace.xs),
      child: XcEntrance(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 2,
          children: [
            Text(title, style: XcType.pageTitle(context)),
            if (subtitle case final subtitle?)
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: XcType.secondary(context),
              ),
          ],
        ),
      ),
    );
  }
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
    this.onNodes,
    this.syncPhase,
    this.blockReason,
    this.sessionTimer,
  });
  final XboardApi api;
  final bool running;
  final bool canConnect;
  final Map<String, String> selectedNodes;
  final String syncMessage;
  final VoidCallback onConnect;
  final VoidCallback onPlans;
  final Future<void> Function() onSync;
  final VoidCallback? onNodes;
  final SyncPhase? syncPhase;
  final String? blockReason;
  final Widget? sessionTimer;
  @override
  State<XcHomePage> createState() => _XcHomePageState();
}

class _XcHomePageState extends State<XcHomePage> {
  late Future<XcHomeData> _future = _load();

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

  Future<void> _refresh() async {
    if (!mounted) return;
    final future = _load();
    setState(() => _future = future);
    try {
      await future;
    } catch (_) {}
  }

  Future<void> _syncAndRefresh() async {
    await widget.onSync();
    await _refresh();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<XcHomeData>(
    future: _future,
    builder: (context, snapshot) {
      final data = snapshot.data;
      final done = snapshot.connectionState == ConnectionState.done;
      return RefreshIndicator(
        onRefresh: _syncAndRefresh,
        child: XcHomePanel(
          data: data,
          error: done && snapshot.hasError ? snapshot.error : null,
          onRetry: _refresh,
          running: widget.running,
          canConnect: widget.canConnect,
          blockReason: widget.blockReason,
          syncPhase: widget.syncPhase,
          selectedNodes: widget.selectedNodes,
          syncMessage: widget.syncMessage,
          sessionTimer: widget.sessionTimer,
          onConnect: widget.onConnect,
          onPlans: widget.onPlans,
          onNodes: widget.onNodes,
          onSync: _syncAndRefresh,
          onOrders: () => xcPush(context, XcOrdersPage(api: widget.api)),
          onTickets: () => xcPush(context, XcTicketsPage(api: widget.api)),
          onNotices: () => xcPush(context, XcNoticesPage(api: widget.api)),
          onCycle: () => xcPush(context, XcTrafficCyclePage(api: widget.api)),
          onResetPackage: () async {
            final id = XcFormat.toInt(data?.summary['plan_id']);
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
    },
  );
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
    final colors = XcColors.of(context);
    final (tone, glyph) = switch (notice.level) {
      'critical' => (XcTone.danger, AppGlyphs.error),
      'warning' => (XcTone.warning, AppGlyphs.warning),
      _ => (XcTone.accent, AppGlyphs.info),
    };
    return XcBannerSlot(
      child: XcEntrance(
        child: XcCallout(
          tone: tone,
          glyph: glyph,
          title: notice.title,
          dismissTooltip: '关闭公告',
          onDismiss: () => setState(() => _dismissed.add(notice.id)),
          children: [
            Material(
              type: MaterialType.transparency,
              child: InkWell(
                customBorder: XcRadius.control,
                onTap: () => xcPush(
                  context,
                  XcPage(
                    title: notice.title,
                    child: xcList([
                      XcSection(
                        children: [XcRichContent(content: notice.body)],
                      ),
                    ]),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 2,
                    children: [
                      Text(
                        '查看公告详情',
                        style: XcType.secondary(
                          context,
                        ).copyWith(color: colors.accent),
                      ),
                      GlyphIcon(
                        AppGlyphs.chevronForward,
                        size: 14,
                        color: colors.accent,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
