import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:fl_clash/providers/providers.dart' as upstream;
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/ui/restriction_notice.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/ui/account/account_pages.dart';
import 'package:fl_clash/xboard/ui/account/support_pages.dart';
import 'package:fl_clash/xboard/ui/account/gift_card_pages.dart';
import 'package:fl_clash/xboard/ui/account/invite_pages.dart';
import 'package:fl_clash/xboard/ui/common/commerce.dart';
import 'package:fl_clash/xboard/ui/common/format.dart';
import 'package:fl_clash/xboard/ui/common/widgets.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart'
    show SubscriptionSync;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/xboard/ui/shell.dart';
import 'package:fl_clash/xboard/ui/store/store_pages.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Api extends Fake implements XboardApi {
  int saved = 0;
  int registered = 0;
  int createdTickets = 0;
  String? period;
  @override
  Future<Map<String, dynamic>> commConfig() async => {};
  @override
  Future<List<Map<String, dynamic>>> tickets() async => [];
  @override
  Future<List<Map<String, dynamic>>> devices() async => [];
  @override
  Future<List<Map<String, dynamic>>> plans() async => [demoPlan];
  @override
  Future<String> saveOrder({
    required int planId,
    required String period,
    String? couponCode,
  }) async {
    saved++;
    this.period = period;
    return 'demo-order';
  }

  @override
  Future<Map<String, dynamic>> orderDetail(String tradeNo) async => {
    'trade_no': tradeNo,
    'plan': {'name': '安心月卡'},
    'period': 'month_price',
    'status': 0,
    'total_amount': 0,
  };
  @override
  Future<List<Map<String, dynamic>>> paymentMethods() async => [];
  @override
  Future<int> checkOrder(String tradeNo) async => 0;
  @override
  Future<XbCheckoutResult> checkout({
    required String tradeNo,
    int? method,
  }) async => const XbCheckoutResult(-1, true);
}

class _Actions extends Fake implements XcActions {}

class _CommerceApi extends _Api {
  int status = OrderStatus.pending;
  int redeemed = 0;
  @override
  Future<Map<String, dynamic>> commConfig() async => {
    'currency': 'USD',
    'currency_symbol': r'$',
  };
  @override
  Future<Map<String, dynamic>> checkCoupon({
    required String code,
    required int planId,
    required String period,
  }) async => {'type': 1, 'value': 500};
  @override
  Future<Map<String, dynamic>> orderDetail(String tradeNo) async => {
    'trade_no': tradeNo,
    'plan': {'name': '安心月卡'},
    'period': 'month_price',
    'status': status,
    'total_amount': 0,
    'balance_amount': 1200,
    'discount_amount': 100,
    'surplus_amount': 200,
  };
  @override
  Future<int> checkOrder(String tradeNo) async => status;
  @override
  Future<XbCheckoutResult> checkout({
    required String tradeNo,
    int? method,
  }) async {
    status = OrderStatus.processing;
    return const XbCheckoutResult(-1, true);
  }

  @override
  Future<Map<String, dynamic>> invites() async => {
    'stat': [1, 1200, 300, 10, 500],
  };
  @override
  Future<XbPage> giftCardHistory({int page = 1, int pageSize = 15}) async =>
      const XbPage([], 0);
  @override
  Future<Map<String, dynamic>> giftCardCheck(String code) async => {
    'can_redeem': true,
    'reward_preview': {'balance': 1234, 'plan_name': '安心专线'},
  };
  @override
  Future<Map<String, dynamic>> giftCardRedeem(String code) async {
    redeemed++;
    return {'message': '兑换成功'};
  }
}

class _CommerceSession extends Fake implements Session {
  @override
  int generation = 1;
  @override
  XcSessionState get state =>
      const XcSessionState(status: XcSessionStatus.loggedIn);
}

class _CommerceRuntime extends Fake implements XClientRuntime {
  @override
  final _CommerceSession session = _CommerceSession();
  @override
  final _CommerceSync sync = _CommerceSync();
}

class _CommerceSync extends Fake implements SubscriptionSync {
  @override
  SyncStatus status = const SyncStatus();
  int requested = 0;
  @override
  void requestSync({Duration delay = const Duration(seconds: 2)}) =>
      requested++;
}

class _CommerceActions extends Fake implements XcActions {
  _CommerceActions({this.refreshBarrier, this.syncResult});
  final Future<void>? refreshBarrier;
  final SyncStatus? syncResult;
  final calls = <String>[];
  @override
  Future<void> refreshUser() async {
    calls.add('user');
    await refreshBarrier;
  }

  @override
  Future<SyncStatus> syncNow() async {
    calls.add('sync');
    return syncResult ??
        SyncStatus(phase: SyncPhase.ok, lastSuccess: DateTime(2026, 11, 4, 12));
  }
}

const demoPlan = <String, dynamic>{
  'id': 1,
  'name': '安心专线',
  'transfer_enable': 100,
  'month_price': 1200,
  'year_price': 12000,
  'device_limit': 3,
  'speed_limit': 200,
  'content':
      '[{"feature":"全球精选线路","support":true},{"feature":"智能分流与地区故障转移","support":true}]',
  'tags': ['精选线路', '稳定连接'],
};
const demoHome = XcHomeData(
  user: {'email': 'demo@example.invalid', 'balance': 2000},
  summary: {
    'plan': {'name': '安心专线'},
    'u': 2147483648,
    'd': 10737418240,
    'transfer_enable': 107374182400,
    'expired_at': 1800000000,
    'next_reset_at': 1795000000,
    'online_count': 1,
    'device_limit': 3,
  },
  stats: [1, 0, 3],
  notices: [
    {'title': '欢迎回来', 'content': '线路已更新，祝您连接顺畅。'},
  ],
);

Widget _app(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: ThemeData(
    useMaterial3: true,
    fontFamily: Platform.isWindows ? 'XcQa' : null,
    colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff177f8b)),
  ).withAppTypography.withAppShapes,
  home: child,
);
Widget _home() => XcHomePanel(
  data: demoHome,
  running: false,
  canConnect: true,
  selectedNodes: const {'当前线路': '日本 · 东京 01'},
  syncMessage: '节点已安全同步',
  onConnect: () {},
  onPlans: () {},
  onSync: () async {},
  onOrders: () {},
  onTickets: () {},
  onNotices: () {},
  onCycle: () {},
  onResetPackage: () async {},
);

Future<void> _save(WidgetTester tester, GlobalKey key, String name) async {
  final path = Platform.environment['XC_UI_SCREENSHOTS'];
  if (path == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$path/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File(r'C:\Windows\Fonts\msyh.ttc');
    if (Platform.isWindows && file.existsSync()) {
      final font = FontLoader('XcQa')
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await font.load();
    }
    final configFile = File('.dart_tool/package_config.json');
    final config = jsonDecode(configFile.readAsStringSync()) as Map;
    final flutter = (config['packages'] as List).whereType<Map>().firstWhere(
      (package) => package['name'] == 'flutter',
    );
    final root = flutter['rootUri'] as String;
    final flutterPackage = configFile.absolute.uri.resolve(
      root.endsWith('/') ? root : '$root/',
    );
    if (flutterPackage.scheme == 'file') {
      final icons = File.fromUri(
        flutterPackage.resolve(
          '../../bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
        ),
      );
      if (icons.existsSync()) {
        final font = FontLoader(
          'MaterialIcons',
        )..addFont(Future.value(ByteData.sublistView(icons.readAsBytesSync())));
        await font.load();
      }
    }
  });

  testWidgets(
    'balance checkout waits for completion then refreshes user and sync once',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1100);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _CommerceApi();
      final actions = _CommerceActions();
      final runtime = _CommerceRuntime();
      final boundary = GlobalKey();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            xcApiProvider.overrideWithValue(api),
            xcRuntimeProvider.overrideWith((ref) async => runtime),
            xcActionsProvider.overrideWithValue(actions),
          ],
          child: _app(
            XcCommerceHost(
              child: RepaintBoundary(
                key: boundary,
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (_) => XcPlansPage(api: api),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择套餐'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('创建订单'));
      await tester.tap(find.text('创建订单'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('使用余额完成支付'));
      await tester.tap(find.text('使用余额完成支付'));
      await tester.pumpAndSettle();
      expect(find.text('开通中'), findsOneWidget);
      expect(find.text(r'$12.00'), findsOneWidget);
      expect(actions.calls, isEmpty);
      await _save(tester, boundary, 'phone-order-processing');
      api.status = OrderStatus.completed;
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      expect(actions.calls, ['user', 'sync']);
      expect(runtime.sync.requested, 0);
      expect(find.text('已完成'), findsOneWidget);
      await _save(tester, boundary, 'phone-order-completed');
      await tester.ensureVisible(find.text('刷新订单状态'));
      await tester.tap(find.text('刷新订单状态'));
      await tester.pumpAndSettle();
      expect(actions.calls, ['user', 'sync']);
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 4));
    },
  );

  testWidgets(
    'reopening completed order reconciles; cancelled order does not',
    (tester) async {
      final api = _CommerceApi()..status = OrderStatus.completed;
      var refreshed = 0;
      final effects = XcEntitlementRefresh(() async => refreshed++);
      Widget order(String trade) => XcCommerceScope(
        currency: XcCurrency.cny,
        entitlements: effects,
        child: _app(
          XcOrderPage(key: ValueKey(trade), api: api, tradeNo: trade),
        ),
      );
      await tester.pumpWidget(order('completed'));
      await tester.pumpAndSettle();
      expect(refreshed, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(order('completed'));
      await tester.pumpAndSettle();
      expect(refreshed, 1);
      api.status = OrderStatus.cancelled;
      await tester.pumpWidget(order('cancelled'));
      await tester.pumpAndSettle();
      expect(refreshed, 1);
    },
  );

  testWidgets(
    'gift card redemption invokes the shared entitlement refresh once',
    (tester) async {
      final api = _CommerceApi();
      var refreshes = 0;
      final effects = XcEntitlementRefresh(() async => refreshes++);
      await tester.pumpWidget(
        XcCommerceScope(
          currency: XcCurrency.fromConfig({'currency': 'USD'}),
          entitlements: effects,
          child: _app(
            XcGiftCardsPage(api: api, onRedeemed: effects.giftCardRedeemed),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'DEMO123456');
      await tester.tap(find.text('检查礼品卡'));
      await tester.pumpAndSettle();
      expect(find.text(r'$12.34'), findsOneWidget);
      await tester.tap(find.text('确认兑换'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('确认'));
      await tester.pumpAndSettle();
      expect(api.redeemed, 1);
      expect(refreshes, 1);
    },
  );

  testWidgets(
    'USD currency reaches plans accounts commissions coupons and rewards without leaking',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1100);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _CommerceApi();
      final boundary = GlobalKey();
      final effects = XcEntitlementRefresh(() async {});
      Widget withCurrency(
        Widget child, {
        XcCurrency currency = const XcCurrency(code: 'USD', symbol: r'$'),
      }) => XcCommerceScope(
        currency: currency,
        entitlements: effects,
        child: _app(child),
      );
      await tester.pumpWidget(
        withCurrency(
          RepaintBoundary(
            key: boundary,
            child: XcPlansPage(api: api),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'$12.00 / 月付'), findsOneWidget);
      await _save(tester, boundary, 'phone-usd-plans');
      await tester.pumpWidget(
        withCurrency(XcPlanDetailPage(api: api, plan: demoPlan)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'DEMO');
      await tester.tap(find.text('验证优惠码'));
      await tester.pumpAndSettle();
      expect(find.text(r'立减 $5.00'), findsOneWidget);
      expect(find.text(r'-$5.00'), findsOneWidget);
      await tester.pumpWidget(
        withCurrency(
          Scaffold(
            body: XcAccountPage(
              api: api,
              user: const {'balance': 1234, 'commission_balance': 567},
              panelWebUrl: 'https://example.invalid',
              onLogout: () async {},
              onSync: () async {},
              onRefreshUser: () async {},
              onRegisterDevice: () async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'$12.34'), findsOneWidget);
      expect(find.text(r'$5.67'), findsOneWidget);
      await tester.pumpWidget(
        withCurrency(
          XcInvitePage(api: api, panelWebUrl: 'https://example.invalid'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'$12.00'), findsOneWidget);
      expect(find.text('转入金额（USD）'), findsOneWidget);
      expect(
        XcCoupons.describe({'type': 1, 'value': 500}, symbol: r'$'),
        r'立减 $5.00',
      );
      await tester.pumpWidget(
        withCurrency(
          const Scaffold(body: XcRewards(rewards: {'balance': 1234})),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(r'$12.34'), findsOneWidget);
      await tester.pumpWidget(
        withCurrency(
          const Scaffold(body: XcRewards(rewards: {'balance': 1234})),
          currency: XcCurrency.cny,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('¥12.34'), findsOneWidget);
      expect(find.text(r'$12.34'), findsNothing);
    },
  );

  testWidgets(
    'processing timeout keeps a manual check and completed refresh errors can retry',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1100);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = _CommerceApi()..status = OrderStatus.processing;
      var calls = 0;
      var fail = true;
      final effects = XcEntitlementRefresh(() async {
        calls++;
        if (fail) throw StateError('offline');
      });
      await tester.pumpWidget(
        XcCommerceScope(
          currency: XcCurrency.cny,
          entitlements: effects,
          child: _app(
            XcOrderPage(
              api: api,
              tradeNo: 'slow-order',
              pollTimeout: Duration.zero,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('自动查询已暂停'), findsOneWidget);
      expect(calls, 0);
      api.status = OrderStatus.completed;
      await tester.ensureVisible(find.text('刷新订单状态'));
      await tester.tap(find.text('刷新订单状态'));
      await tester.pumpAndSettle();
      expect(find.textContaining('刷新账户与节点失败'), findsOneWidget);
      expect(calls, 1);
      fail = false;
      await tester.ensureVisible(find.text('重试刷新账户与节点'));
      await tester.tap(find.text('重试刷新账户与节点'));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.textContaining('账户信息与节点同步已检查'), findsOneWidget);
    },
  );

  testWidgets(
    'completion callback cannot sync a newer login after user refresh',
    (tester) async {
      final api = _CommerceApi()..status = OrderStatus.completed;
      final runtime = _CommerceRuntime();
      final barrier = Completer<void>();
      final actions = _CommerceActions(refreshBarrier: barrier.future);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            xcApiProvider.overrideWithValue(api),
            xcRuntimeProvider.overrideWith((ref) async => runtime),
            xcActionsProvider.overrideWithValue(actions),
          ],
          child: _app(
            XcCommerceHost(
              child: XcOrderPage(api: api, tradeNo: 'old-login'),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(actions.calls, ['user']);
      runtime.session.generation++;
      barrier.complete();
      await tester.pumpAndSettle();
      expect(actions.calls, ['user']);
    },
  );

  testWidgets(
    'completed order queues central retry after throttled or inflight pull',
    (tester) async {
      for (final phase in [
        SyncPhase.ok,
        SyncPhase.syncing,
        SyncPhase.blocked,
      ]) {
        final api = _CommerceApi()..status = OrderStatus.completed;
        final runtime = _CommerceRuntime();
        final previous = SyncStatus(
          phase: phase,
          lastSuccess: DateTime(2026, 11, 4),
        );
        runtime.sync.status = previous;
        final result = phase != SyncPhase.ok
            ? SyncStatus(
                phase: SyncPhase.ok,
                lastSuccess: DateTime(2026, 11, 4, 12),
              )
            : previous;
        final actions = _CommerceActions(syncResult: result);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              xcApiProvider.overrideWithValue(api),
              xcRuntimeProvider.overrideWith((ref) async => runtime),
              xcActionsProvider.overrideWithValue(actions),
            ],
            child: _app(
              XcCommerceHost(
                child: XcOrderPage(api: api, tradeNo: 'recent-sync'),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(actions.calls, ['user', 'sync']);
        expect(runtime.sync.requested, 1);
        await tester.pumpWidget(const SizedBox());
      }
    },
  );

  testWidgets(
    'restricted shell replaces cached node choices with admission help',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const blocked = SyncStatus(
        phase: SyncPhase.blocked,
        message: '当前网络暂不可获取节点，请更换网络',
        blockedCode: 'subscription_restricted',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            xcSessionProvider.overrideWith(
              (ref) => Stream.value(
                const XcSessionState(
                  status: XcSessionStatus.loggedIn,
                  deviceRegistered: true,
                ),
              ),
            ),
            xcApiProvider.overrideWithValue(_Api()),
            xcSyncStatusProvider.overrideWith((ref) => Stream.value(blocked)),
            xcNoticeProvider.overrideWithValue(null),
            xcActionsProvider.overrideWithValue(_Actions()),
            xcConnectionBlockProvider.overrideWithValue('受限'),
            upstream.isStartProvider.overrideWith((ref) => false),
            upstream.selectedMapProvider.overrideWith(
              (ref) => {'旧节点组': 'Old sensitive node'},
            ),
          ],
          child: _app(const XcAppShell()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('节点'));
      await tester.pumpAndSettle();
      expect(find.text('暂时无法获取节点'), findsOneWidget);
      expect(find.text('Old sensitive node'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'restriction prompts once per reason, keeps banner and cooldown, and clears only on recovery',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var clock = DateTime(2026, 11, 4, 12);
      var status = SyncStatus(
        phase: SyncPhase.blocked,
        blockedCode: 'subscription_restricted',
        message: '当前网络触发订阅风控，请关闭其他代理或更换网络后重新检查；仍有问题请联系客服。',
        retryAt: clock.add(const Duration(seconds: 10)),
        nextSync: clock.add(const Duration(seconds: 60)),
      );
      late StateSetter rebuild;
      var checks = 0;
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _app(
            StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return XcShellLayout(
                  title: '示例专线',
                  selectedIndex: 1,
                  onSelected: (_) {},
                  banner: XcRestrictionNotice(
                    status: status,
                    now: () => clock,
                    onCheck: () async {
                      checks++;
                      setState(
                        () => status = SyncStatus(
                          phase: SyncPhase.ok,
                          lastSuccess: clock,
                        ),
                      );
                    },
                    onPlans: () {},
                    onTickets: () {},
                  ),
                  child: status.phase == SyncPhase.blocked
                      ? XcRestrictedNodesView(
                          status: status,
                          onCheck: () async {},
                          now: () => clock,
                        )
                      : const Center(child: Text('节点已恢复')),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('我知道了'), findsOneWidget);
      await _save(tester, key, 'phone-restriction-prompt');
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      expect(find.textContaining('请等待 10 秒'), findsOneWidget);
      final check = find.descendant(
        of: find.byType(XcRestrictionNotice),
        matching: find.widgetWithText(FilledButton, '已更换网络，重新检查'),
      );
      expect(tester.widget<FilledButton>(check).onPressed, isNull);
      await _save(tester, key, 'phone-restriction-banner');
      rebuild(
        () => status = status.copyWith(
          nextSync: clock.add(const Duration(seconds: 90)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('我知道了'), findsNothing);
      clock = clock.add(const Duration(seconds: 10));
      await tester.pump(const Duration(seconds: 1));
      await tester.ensureVisible(check);
      await tester.tap(check);
      await tester.pumpAndSettle();
      expect(checks, 1);
      expect(find.text('节点已恢复'), findsOneWidget);
      expect(find.text('节点获取受到限制'), findsNothing);
      rebuild(
        () => status = const SyncStatus(
          phase: SyncPhase.blocked,
          blockedCode: 'subscription_restricted',
          message: '套餐已到期，请续费后重试',
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('我知道了'), findsOneWidget);
      rebuild(
        () => status = SyncStatus(phase: SyncPhase.ok, lastSuccess: clock),
      );
      await tester.pumpAndSettle();
      expect(find.text('我知道了'), findsNothing);
      expect(find.text('节点已恢复'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('remote notice dismissal applies only to its id', (tester) async {
    const first = XcNotice(id: 'a', title: 'First notice', body: 'First body');
    const second = XcNotice(
      id: 'b',
      title: 'Second notice',
      body: 'Second body',
    );
    Widget banner(XcNotice notice) =>
        _app(Scaffold(body: XcNoticeBanner(notice: notice)));
    await tester.pumpWidget(banner(first));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('关闭公告'));
    await tester.pumpAndSettle();
    expect(find.text(first.title), findsNothing);
    await tester.pumpWidget(banner(second));
    await tester.pumpAndSettle();
    expect(find.text(second.title), findsOneWidget);
    await tester.tap(find.text('查看公告详情'));
    await tester.pumpAndSettle();
    expect(find.text(second.body), findsOneWidget);
  });

  testWidgets('session expiry removes pushed account routes', (tester) async {
    final session = StreamController<XcSessionState>();
    addTearDown(session.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          xcSessionProvider.overrideWith((ref) => session.stream),
          xcApiProvider.overrideWithValue(_Api()),
        ],
        child: _app(
          XcAuthGate(
            child: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => xcPush(
                    context,
                    const XcPage(
                      title: 'Private order',
                      child: Text('Order details'),
                    ),
                  ),
                  child: const Text('Open order'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    session.add(const XcSessionState(status: XcSessionStatus.loggedIn));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open order'));
    await tester.pumpAndSettle();
    expect(find.text('Order details'), findsOneWidget);
    session.add(const XcSessionState(status: XcSessionStatus.loggedOut));
    await tester.pumpAndSettle();
    expect(find.text('Order details'), findsNothing);
    expect(find.byKey(const Key('xc-login-submit')), findsOneWidget);
  });

  testWidgets('invalid login stays local; errors restore the submit button', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      _app(
        XcLoginPage(
          displayName: '示例专线',
          onLogin: (email, password) async {
            calls++;
            throw const XbApiException(XbErrorKind.rateLimited);
          },
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('xc-login-submit')));
    await tester.pumpAndSettle();
    expect(find.text('请输入邮箱'), findsOneWidget);
    expect(calls, 0);
    await tester.enterText(
      find.byKey(const Key('xc-login-email')),
      'demo@example.invalid',
    );
    await tester.enterText(
      find.byKey(const Key('xc-login-password')),
      'password123',
    );
    await tester.tap(find.byKey(const Key('xc-login-submit')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.textContaining('临时锁定'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('xc-login-submit')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('login prevents duplicate submissions while awaiting the panel', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final completion = Completer<void>();
    final boundary = GlobalKey();
    var calls = 0;
    await tester.pumpWidget(
      _app(
        RepaintBoundary(
          key: boundary,
          child: XcLoginPage(
            displayName: '示例专线',
            onLogin: (email, password) {
              calls++;
              return completion.future;
            },
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('xc-login-email')),
      'demo@example.invalid',
    );
    await tester.enterText(
      find.byKey(const Key('xc-login-password')),
      'password123',
    );
    await tester.tap(find.byKey(const Key('xc-login-submit')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(CommonCircleLoading), findsOneWidget);
    await _save(tester, boundary, 'phone-login-loading');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('xc-login-submit')))
          .onPressed,
      isNull,
    );
    expect(calls, 1);
    completion.complete();
    await tester.pumpAndSettle();
  });

  testWidgets('empty ticket list still offers creating a ticket', (
    tester,
  ) async {
    await tester.pumpWidget(_app(XcTicketsPage(api: _Api())));
    await tester.pumpAndSettle();
    expect(find.text('暂无工单'), findsOneWidget);
    await tester.tap(find.text('提交工单'));
    await tester.pumpAndSettle();
    expect(find.text('工单主题'), findsOneWidget);
  });

  testWidgets('device limit recovery remains available with no devices', (
    tester,
  ) async {
    final api = _Api();
    await tester.pumpWidget(
      _app(
        XcDevicesPage(
          api: api,
          onLogout: () async {},
          onRegister: () async {
            api.registered++;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新注册当前设备'));
    await tester.pumpAndSettle();
    expect(api.registered, 1);
  });

  testWidgets('checkout places selected period and reaches balance payment', (
    tester,
  ) async {
    final api = _Api();
    await tester.pumpWidget(_app(XcPlanDetailPage(api: api, plan: demoPlan)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('创建订单'));
    await tester.tap(find.text('创建订单'));
    await tester.pumpAndSettle();
    expect(api.saved, 1);
    expect(api.period, PlanPeriod.month);
    await tester.ensureVisible(find.text('使用余额完成支付'));
    expect(find.text('使用余额完成支付'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets(
    'async loader displays failure and retries without unhandled errors',
    (tester) async {
      var attempts = 0;
      await tester.pumpWidget(
        _app(
          Scaffold(
            body: XcLoad<String>(
              load: () async {
                if (attempts++ == 0) {
                  throw const XbApiException(XbErrorKind.network);
                }
                return '已恢复';
              },
              builder: (_, value, refresh) => ListView(children: [Text(value)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('网络连接失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();
      expect(find.text('已恢复'), findsOneWidget);
    },
  );

  testWidgets('payment QR builds using the installed qr package', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: XcPaymentQr(content: 'https://example.invalid/pay/demo'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('支付二维码'), findsOneWidget);
    expect(find.textContaining('内容无效'), findsNothing);
  });

  testWidgets('phone login, home and plans render without overflow', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loginKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: loginKey,
        child: _app(
          XcLoginPage(
            displayName: '示例专线',
            onLogin: (_, _) async {},
            panelWebUrl: Uri.parse('https://example.invalid'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _save(tester, loginKey, 'phone-login');
    final homeKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: homeKey,
        child: _app(
          XcShellLayout(
            title: '示例专线',
            selectedIndex: 0,
            onSelected: (_) {},
            child: _home(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _save(tester, homeKey, 'phone-home');
    final plansKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: plansKey,
        child: _app(
          XcShellLayout(
            title: '示例专线',
            selectedIndex: 2,
            onSelected: (_) {},
            child: XcPlansPage(api: _Api(), embedded: true),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await _save(tester, plansKey, 'phone-plans');
  });

  testWidgets(
    'desktop shell renders rail with account and commerce destinations',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: _app(
            XcShellLayout(
              title: '示例专线',
              selectedIndex: 0,
              onSelected: (_) {},
              child: _home(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.text('我的'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _save(tester, key, 'desktop-shell');
    },
  );
}
