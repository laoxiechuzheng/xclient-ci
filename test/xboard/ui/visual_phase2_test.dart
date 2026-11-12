import 'dart:async';

import 'package:fl_clash/providers/providers.dart'
    show initProvider, isStartProvider;
import 'package:fl_clash/xboard/app_host.dart';
import 'package:fl_clash/xboard/probe/settings_tile.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/ui/account/account_pages.dart';
import 'package:fl_clash/xboard/ui/account/gift_card_pages.dart';
import 'package:fl_clash/xboard/ui/account/invite_pages.dart';
import 'package:fl_clash/xboard/ui/account/record_pages.dart';
import 'package:fl_clash/xboard/ui/account/support_pages.dart';
import 'package:fl_clash/xboard/ui/common/commerce.dart';
import 'package:fl_clash/xboard/ui/common/exit_action.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:fl_clash/xboard/ui/shell.dart';
import 'package:fl_clash/xboard/ui/store/store_pages.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:fl_clash/xboard/update/update_widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'visual_support.dart';

const _gib = 1024 * 1024 * 1024;
const _mib = 1024 * 1024;
const _trade = '2026111220301588';

int _ts(Duration offset) =>
    DateTime.now().add(offset).millisecondsSinceEpoch ~/ 1000;

const _features =
    '[{"feature":"全球 30+ 精选线路","support":true},'
    '{"feature":"智能分流与地区故障转移","support":true},'
    '{"feature":"流媒体解锁","support":false}]';
const _featuresAll =
    '[{"feature":"香港、日本 IEPL 专线","support":true},'
    '{"feature":"智能分流与地区故障转移","support":true},'
    '{"feature":"流媒体与游戏加速","support":true}]';

final _plans = <Map<String, dynamic>>[
  {
    'id': 1,
    'name': '轻享入门',
    'transfer_enable': 100,
    'month_price': 1500,
    'quarter_price': 4200,
    'year_price': 15000,
    'device_limit': 2,
    'speed_limit': 100,
    'content': _features,
    'tags': ['新手推荐'],
  },
  {
    'id': 2,
    'name': '安心专线',
    'transfer_enable': 300,
    'month_price': 2800,
    'quarter_price': 7800,
    'half_year_price': 15000,
    'year_price': 28000,
    'reset_price': 1000,
    'device_limit': 5,
    'speed_limit': 300,
    'content': _featuresAll,
    'tags': ['最受欢迎', 'IEPL 专线'],
  },
  {
    'id': 3,
    'name': '家庭畅享',
    'transfer_enable': 1000,
    'month_price': 5800,
    'year_price': 58000,
    'device_limit': 10,
    'content': _featuresAll,
    'tags': ['多设备'],
  },
  {
    'id': 4,
    'name': '流量加油包',
    'transfer_enable': 50,
    'onetime_price': 1000,
    'content': '[{"feature":"一次性 50 GB 流量","support":true}]',
    'capacity_limit': 0,
  },
];

final _user = <String, dynamic>{
  'email': 'lin.demo@example.invalid',
  'balance': 2000,
  'commission_balance': 9600,
  'created_at': _ts(const Duration(days: -210)),
  'last_login_at': _ts(const Duration(hours: -1)),
  'remind_expire': 1,
  'remind_traffic': 0,
};

class _ShotApi extends Fake implements XboardApi {
  int orderStatus = OrderStatus.pending;
  int orderTotal = 2300;
  int orderBalance = 1200;
  Completer<String>? orderGate;
  bool noTickets = false;
  bool earned = true;
  Exception? giftError;

  @override
  Future<List<Map<String, dynamic>>> plans() async => _plans;
  @override
  Future<Map<String, dynamic>> checkCoupon({
    required String code,
    required int planId,
    required String period,
  }) async => {'type': 1, 'value': 500, 'name': '新人立减'};
  @override
  Future<String> saveOrder({
    required int planId,
    required String period,
    String? couponCode,
  }) => orderGate?.future ?? Future.value(_trade);
  @override
  Future<Map<String, dynamic>> orderDetail(String tradeNo) async => {
    'trade_no': tradeNo,
    'plan': {'name': '安心专线'},
    'plan_id': 2,
    'type': 1,
    'period': 'quarter_price',
    'status': orderStatus,
    'total_amount': orderTotal,
    'balance_amount': orderBalance,
    'discount_amount': 500,
    'surplus_amount': 0,
    'created_at': _ts(const Duration(minutes: -4)),
    if (orderStatus == OrderStatus.completed)
      'paid_at': _ts(const Duration(minutes: -1)),
  };
  @override
  Future<List<Map<String, dynamic>>> paymentMethods() async => [
    {'id': 1, 'name': '支付宝'},
    {'id': 2, 'name': '微信支付'},
    {'id': 3, 'name': 'USDT（TRC20）', 'handling_fee_percent': 1.5},
  ];
  @override
  Future<int> checkOrder(String tradeNo) async => orderStatus;
  @override
  Future<XbCheckoutResult> checkout({
    required String tradeNo,
    int? method,
  }) async => orderTotal > 0
      ? const XbCheckoutResult(0, 'https://pay.example.invalid/qr/7F31AF28')
      : const XbCheckoutResult(-1, true);
  @override
  Future<void> cancelOrder(String tradeNo) async {}
  @override
  Future<List<Map<String, dynamic>>> orders({int? status}) async => [
    for (final (index, value) in const [
      OrderStatus.pending,
      OrderStatus.processing,
      OrderStatus.completed,
      OrderStatus.cancelled,
    ].indexed)
      {
        'trade_no': '20261112203015${88 - index}',
        'plan': {'name': index.isEven ? '安心专线' : '轻享入门'},
        'type': index == 2 ? 2 : 1,
        'period': index.isEven ? 'quarter_price' : 'month_price',
        'status': value,
        'total_amount': index.isEven ? 7800 : 1500,
        'created_at': _ts(Duration(days: -index * 31, minutes: -4)),
      },
  ];

  @override
  Future<Map<String, dynamic>> userInfo() async => _user;
  @override
  Future<List<Map<String, dynamic>>> devices() async => [
    {
      'device_id': 'a',
      'device_name': 'Pixel 8',
      'platform': 'Android',
      'app_version': '1.3.2',
      'last_seen_at': _ts(const Duration(minutes: -1)),
      'current': true,
    },
    {
      'device_id': 'b',
      'device_name': 'MacBook Air',
      'platform': 'macOS',
      'app_version': '1.3.2',
      'last_seen_at': _ts(const Duration(days: -2)),
    },
    {
      'device_id': 'c',
      'device_name': '办公室台式机',
      'platform': 'Windows',
      'app_version': '1.2.9',
      'last_seen_at': _ts(const Duration(days: -16)),
    },
  ];
  @override
  Future<Map<String, dynamic>> telegramBotInfo() async => {
    'username': 'example_helper_bot',
  };
  @override
  Future<List<Map<String, dynamic>>> trafficLog() async => [
    for (var day = 0; day < 6; day++)
      {
        'record_at': _ts(Duration(days: -day)),
        'u': (0.2 + day * 0.07) * _gib,
        'd': (1.6 + day * 0.9) * _gib,
        'server_rate': day == 2 ? 1.5 : 1,
      },
  ];
  @override
  Future<XbPage?> loginLog({int page = 1, int pageSize = 15}) async => XbPage([
    for (final (index, os) in const [
      'Android 15',
      'macOS 15',
      'Windows 11',
    ].indexed)
      {
        'created_at': _ts(Duration(hours: -index * 30)),
        'is_current': index == 0,
        'success': index != 2,
        'ip': '203.0.113.${24 + index}',
        'device': {'type': index == 0 ? '手机' : '电脑', 'os': os},
        'user_agent': 'XClient/1.3.2',
        'location': {'country': '中国', 'region': '上海'},
        'origin': 'client',
      },
  ], 3);
  @override
  Future<List<Map<String, dynamic>>> activeSessions() async => [
    {
      'id': 1,
      'device_name': 'Pixel 8',
      'is_current': true,
      'ip': '203.0.113.24',
      'created_at': _ts(const Duration(days: -3)),
      'last_used_at': _ts(const Duration(minutes: -1)),
    },
    {
      'id': 2,
      'device_name': 'MacBook Air',
      'ip': '203.0.113.25',
      'created_at': _ts(const Duration(days: -20)),
      'last_used_at': _ts(const Duration(days: -2)),
    },
  ];
  @override
  Future<Map<String, dynamic>?> trafficCycle({
    int historyPage = 1,
    int historySize = 10,
    int eventsSize = 20,
  }) async => {
    'plan': {'name': '安心专线'},
    'reset_method': 'monthly',
    'expired_at': _ts(const Duration(days: 73)),
    'current': {
      'started_at': _ts(const Duration(days: -24)),
      'ends_at': _ts(const Duration(days: 6)),
      'quota': 300 * _gib,
      'used': 247 * _gib,
      'remaining': 53 * _gib,
      'reason': 'rollover',
    },
    'history': [
      {
        'started_at': _ts(const Duration(days: -54)),
        'ends_at': _ts(const Duration(days: -24)),
        'quota': 300 * _gib,
        'used': 181 * _gib,
        'reason': 'purchase',
      },
    ],
    'history_total': 1,
    'events': [
      {
        'reason': 'cycle_rollover',
        'at': _ts(const Duration(days: -24)),
        'cleared': 181 * _gib,
        'quota_before': 300 * _gib,
        'quota_after': 300 * _gib,
        'carried': 0,
      },
    ],
  };
  @override
  Future<XbPage> notices({int page = 1}) async => XbPage([
    {
      'title': '春节线路升级完成',
      'content': '<p>香港、日本线路已完成扩容，晚高峰更稳定。</p><p>如遇问题请提交工单，我们会第一时间处理。</p>',
      'created_at': _ts(const Duration(days: -1)),
    },
    {
      'title': '客户端 1.4.0 即将发布',
      'content': '<p>新版本优化了地区故障转移，并修复部分安卓设备后台断线的问题。</p>',
      'created_at': _ts(const Duration(days: -6)),
    },
  ], 2);
  @override
  Future<Map<String, List<Map<String, dynamic>>>> knowledge({
    String language = 'zh-CN',
    String? keyword,
  }) async => {
    '新手入门': [
      {'id': 1, 'title': '第一次使用：三步完成连接'},
      {'id': 2, 'title': '如何选择最快的线路'},
    ],
    '常见问题': [
      {'id': 3, 'title': '连接成功但网页打不开怎么办'},
      {'id': 4, 'title': '支付完成后套餐没有生效'},
    ],
  };
  @override
  Future<Map<String, dynamic>> knowledgeArticle(
    int id, {
    String language = 'zh-CN',
  }) async => {
    'title': '第一次使用：三步完成连接',
    'body':
        '<p>欢迎使用！只需要三步：</p><ol><li>登录账号并选购套餐。</li>'
        '<li>回到首页，等待节点自动同步完成。</li><li>点击中间的连接按钮。</li></ol>'
        '<p>连接成功后，按钮会变成绿色并显示已连接时长。</p>',
  };
  @override
  Future<List<Map<String, dynamic>>> tickets() async => noTickets
      ? []
      : [
          {
            'id': 1,
            'subject': '晚高峰香港节点偶尔断开',
            'level': 1,
            'status': 0,
            'reply_status': 1,
            'created_at': _ts(const Duration(hours: -5)),
          },
          {
            'id': 2,
            'subject': '支付成功但套餐还没有生效',
            'level': 2,
            'status': 0,
            'reply_status': 0,
            'created_at': _ts(const Duration(minutes: -20)),
          },
          {
            'id': 3,
            'subject': '如何在电视上使用',
            'level': 0,
            'status': 1,
            'reply_status': 1,
            'created_at': _ts(const Duration(days: -12)),
          },
        ];
  @override
  Future<Map<String, dynamic>> ticket(int id) async => {
    'id': id,
    'subject': '晚高峰香港节点偶尔断开',
    'status': 0,
    'reply_status': 1,
    'created_at': _ts(const Duration(hours: -5)),
    'message': [
      {
        'is_me': true,
        'message': '最近两天晚上 9 点左右，香港 01 会断开几秒，然后自动恢复。',
        'created_at': _ts(const Duration(hours: -5)),
      },
      {
        'is_me': false,
        'message': '您好，我们已定位到该线路晚高峰拥塞，今晚会完成扩容。期间可以先切换到香港 02 或日本线路。',
        'created_at': _ts(const Duration(hours: -3)),
      },
      {
        'is_me': true,
        'message': '好的，切到香港 02 之后稳定了，谢谢！',
        'created_at': _ts(const Duration(hours: -2)),
      },
    ],
  };
  @override
  Future<Map<String, dynamic>> commConfig() async => {
    'withdraw_methods': ['支付宝', 'USDT'],
    'withdraw_close': 0,
  };
  @override
  Future<Map<String, dynamic>> invites() async => earned
      ? {
          'stat': [6, 12800, 1500, 20, 9600],
          'codes': [
            {'code': 'LIN2026', 'pv': 38},
            {'code': 'FRIENDS8', 'pv': 4},
          ],
        }
      : {
          'stat': [0, 0, 0, 20, 0],
          'codes': [
            {'code': 'LIN2026', 'pv': 0},
          ],
        };
  @override
  Future<XbPage> inviteDetails({int page = 1, int pageSize = 10}) async =>
      XbPage([
        for (var index = 0; index < 3; index++)
          {
            'get_amount': 560 + index * 280,
            'order_amount': 2800 + index * 1400,
            'trade_no': '2026110${index + 1}1830${index}2741',
            'created_at': _ts(Duration(days: -index * 9)),
          },
      ], 3);
  @override
  Future<XbPage> giftCardHistory({int page = 1, int pageSize = 15}) async =>
      XbPage([
        {
          'id': 1,
          'template_name': '新春礼品卡',
          'code': 'GIFT-8F2K-29QD',
          'created_at': _ts(const Duration(days: -8)),
          'template_type_name': '余额卡',
          'rewards_given': {'balance': 5000},
        },
      ], 1);
  @override
  Future<Map<String, dynamic>> giftCardCheck(String code) async {
    if (giftError case final error?) throw error;
    return {
      'can_redeem': true,
      'code_info': {'status_name': '可使用'},
      'reward_preview': {'balance': 5000, 'expire_days': 30},
    };
  }

  @override
  Future<Map<String, dynamic>> giftCardRedeem(String code) async => {
    'message': '兑换成功，已发放 ¥50.00 余额',
  };
  @override
  Future<Map<String, dynamic>> giftCardDetail(int id) async => {
    'template_name': '新春礼品卡',
    'code': 'GIFT-8F2K-29QD',
    'created_at': _ts(const Duration(days: -8)),
    'multiplier_applied': 1,
    'rewards_given': {'balance': 5000, 'expire_days': 30},
  };
}

Future<void> _pump(
  WidgetTester tester,
  XcShotSize size,
  Brightness brightness,
  Widget page, {
  List<Override> overrides = const [],
}) async {
  xcView(tester, size);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: overrides,
      child: xcFramed(xcApp(brightness: brightness, page)),
    ),
  );
  await xcSettle(tester);
}

Future<void> _reveal(
  WidgetTester tester,
  Finder finder, {
  Finder? within,
}) async {
  if (finder.evaluate().isEmpty) {
    final lists = find.byWidgetPredicate(
      (widget) =>
          widget is Scrollable && widget.axisDirection == AxisDirection.down,
    );
    await tester.scrollUntilVisible(
      finder,
      200,
      scrollable:
          (within == null
                  ? lists
                  : find.descendant(of: within, matching: lists))
              .first,
    );
  }
  await tester.ensureVisible(finder.first);
  await xcSettle(tester);
}

/// Unmounts the tree and lets a stopped payment watcher's last delay expire.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 4));
}

Widget _commerce(Widget child) => XcCommerceScope(
  currency: XcCurrency.cny,
  entitlements: XcEntitlementRefresh(() async {}),
  child: child,
);

Widget _shell(int index, Widget child) => XcShellLayout(
  title: 'Example 加速器',
  selectedIndex: index,
  onSelected: (_) {},
  pageTitle: index == 2 ? '选购套餐' : '我的账户',
  pageSubtitle: index == 2 ? '支付成功后自动生效，可随时续费或升级' : '订单、权益与账户安全',
  child: child,
);

Widget _account(XboardApi api) => _shell(
  3,
  XcAccountPage(
    api: api,
    user: _user,
    panelWebUrl: 'https://example.invalid',
    onLogout: () async {},
    onSync: () async {},
    onRefreshUser: () async {},
    onRegisterDevice: () async {},
    settingsTiles: const [
      XcProbeSettingsTile(),
      XcUpdateTile(),
      XcExitAction(),
    ],
  ),
);

final _clientOverrides = <Override>[
  xcManagedAndroidProvider.overrideWithValue(true),
  isStartProvider.overrideWithValue(false),
  xcCurrentVersionProvider.overrideWithValue('1.3.2'),
  xcUpdateStateProvider.overrideWith(
    (ref) => Stream.value(
      const XcUpdateState(
        decision: UpdateDecision(mode: UpdateMode.notify, latest: '1.4.0'),
      ),
    ),
  ),
];

const _notes = '· 地区故障转移更快、更安静\n· 修复部分安卓设备后台断线\n· 首页加载速度提升约 30%';
const _notify = UpdateDecision(
  mode: UpdateMode.notify,
  latest: '1.4.0',
  notes: _notes,
);
const _force = UpdateDecision(
  mode: UpdateMode.force,
  latest: '1.4.0',
  notes: _notes,
);

final _updateStates = <String, XcUpdateState>{
  'notify': const XcUpdateState(decision: _notify, noticeDue: true),
  'forced': const XcUpdateState(decision: _force),
  'downloading': const XcUpdateState(
    phase: XcUpdatePhase.downloading,
    decision: _notify,
    received: 23 * _mib,
    total: 41 * _mib,
  ),
  'forced-downloading': const XcUpdateState(
    phase: XcUpdatePhase.downloading,
    decision: _force,
    received: 9 * _mib,
    total: 41 * _mib,
  ),
  'permission': const XcUpdateState(
    phase: XcUpdatePhase.needsPermission,
    decision: _force,
  ),
  'failed': XcUpdateState(
    phase: XcUpdatePhase.failed,
    decision: _notify,
    message: '安装包校验未通过，已删除下载的文件',
    retryAt: DateTime(2026, 11, 12, 21),
  ),
};

Future<ValueNotifier<XcUpdateState>> _showUpdate(
  WidgetTester tester,
  XcShotSize size,
  Brightness brightness,
  XcUpdateState state,
) async {
  final notifier = ValueNotifier(state);
  addTearDown(notifier.dispose);
  await _pump(
    tester,
    size,
    brightness,
    XcHomeHarness(
      data: xcHomeData(),
      canConnect: !state.isForced,
      blockReason: state.isForced ? '请完成客户端更新后再连接' : null,
    ),
  );
  unawaited(
    showDialog<void>(
      context: tester.element(find.byType(XcHomeHarness)),
      builder: (_) => ValueListenableBuilder(
        valueListenable: notifier,
        builder: (_, value, _) => XcUpdatePanel(
          state: value,
          currentVersion: '1.3.2',
          onClose: () {},
          onUpdate: () {},
          onPermission: () {},
        ),
      ),
    ),
  );
  await xcSettle(tester);
  return notifier;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(xcLoadFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    for (final size in XcShotSize.values) {
      final core = XcShotSize.core.contains(size);
      Future<void> shot(WidgetTester tester, String name) =>
          xcShot(tester, '${size.name}-$theme-$name', size);

      xcVisual('plans render at ${size.name} $theme', (tester) async {
        await _pump(
          tester,
          size,
          brightness,
          _shell(2, XcPlansPage(api: _ShotApi(), embedded: true)),
        );
        expect(find.text('安心专线'), findsOneWidget);
        await shot(tester, 'store-plans');
      });

      xcVisual('checkout states render at ${size.name} $theme', (tester) async {
        final api = _ShotApi()..orderGate = Completer();
        await _pump(
          tester,
          size,
          brightness,
          XcPlanDetailPage(
            api: api,
            plan: _plans[1],
            initialPeriod: 'quarter_price',
          ),
        );
        await shot(tester, 'checkout-default');
        await _reveal(tester, find.byType(TextField));
        await tester.enterText(find.byType(TextField), 'WELCOME5');
        await tester.tap(find.text('验证优惠码'));
        await xcSettle(tester);
        await _reveal(tester, find.text('优惠已生效'));
        await shot(tester, 'checkout-coupon');
        await tester.tap(find.text('创建订单'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('正在创建订单'), findsOneWidget);
        await shot(tester, 'checkout-placing');
        api.orderGate!.completeError(const XbApiException(XbErrorKind.server));
        await xcSettle(tester);
        await _reveal(tester, find.text('订单没有创建成功'));
        await shot(tester, 'checkout-failed');
      });

      xcVisual('payment states render at ${size.name} $theme', (tester) async {
        final api = _ShotApi();
        await _pump(
          tester,
          size,
          brightness,
          _commerce(XcOrderPage(api: api, tradeNo: _trade)),
        );
        await _reveal(tester, find.text('支付宝'));
        await tester.tap(find.text('支付宝'));
        await _reveal(tester, find.text('前往支付'));
        await tester.tap(find.text('前往支付'));
        await xcSettle(tester);
        await _reveal(tester, find.byType(XcPaymentQr));
        await shot(tester, 'checkout-qr');
        api
          ..orderTotal = 0
          ..orderBalance = 2300;
        await _pump(
          tester,
          size,
          brightness,
          _commerce(
            XcOrderPage(key: const Key('balance'), api: api, tradeNo: _trade),
          ),
        );
        await _reveal(tester, find.text('使用余额完成支付'));
        await shot(tester, 'checkout-balance');
        await _drain(tester);
      });

      xcVisual('order states render at ${size.name} $theme', (tester) async {
        final api = _ShotApi();
        for (final (name, status) in const [
          ('pending', OrderStatus.pending),
          ('processing', OrderStatus.processing),
          ('completed', OrderStatus.completed),
          ('cancelled', OrderStatus.cancelled),
        ]) {
          api.orderStatus = status;
          await _pump(
            tester,
            size,
            brightness,
            _commerce(XcOrderPage(key: Key(name), api: api, tradeNo: _trade)),
          );
          expect(find.text(OrderStatus.labels[status]!), findsWidgets);
          await shot(tester, 'order-$name');
        }
        await _drain(tester);
      });

      xcVisual('account overview renders at ${size.name} $theme', (
        tester,
      ) async {
        await _pump(
          tester,
          size,
          brightness,
          _account(_ShotApi()),
          overrides: _clientOverrides,
        );
        await shot(tester, 'account-overview');
        await _reveal(
          tester,
          find.text('退出客户端'),
          within: find.byType(XcAccountPage),
        );
        expect(find.text('有新版本'), findsOneWidget);
        await shot(tester, 'account-client-settings');
      });

      xcVisual('update prompts render at ${size.name} $theme', (tester) async {
        for (final entry in _updateStates.entries) {
          if (!core && entry.key != 'forced') continue;
          await _showUpdate(tester, size, brightness, entry.value);
          expect(find.byType(XcUpdatePanel), findsOneWidget);
          await shot(tester, 'update-${entry.key}');
        }
      });

      if (!core) continue;

      xcVisual('orders list renders at ${size.name} $theme', (tester) async {
        await _pump(tester, size, brightness, XcOrdersPage(api: _ShotApi()));
        await shot(tester, 'orders-list');
      });

      final pages = <String, Widget Function(_ShotApi api)>{
        'account-devices': (api) => XcDevicesPage(
          api: api,
          onLogout: () async {},
          onRegister: () async {},
        ),
        'account-security': (api) => XcAccountSettingsPage(
          api: api,
          panelWebUrl: 'https://example.invalid',
          onSync: () async {},
          onRefreshUser: () async {},
        ),
        'account-telegram': (api) =>
            XcTelegramPage(api: api, panelWebUrl: 'https://example.invalid'),
        'traffic-log': (api) => XcTrafficLogPage(api: api),
        'traffic-cycle': (api) => XcTrafficCyclePage(api: api),
        'login-log': (api) => XcLoginLogPage(api: api),
        'sessions': (api) => XcSessionsPage(api: api),
        'notices': (api) => XcNoticesPage(api: api),
        'knowledge': (api) => XcKnowledgePage(api: api),
        'article': (api) => XcArticlePage(api: api, id: 1),
        'commission': (api) => XcCommissionPage(api: api),
        'giftcard-detail': (api) => XcGiftCardDetailPage(api: api, id: 1),
        'tickets-list': (api) => XcTicketsPage(api: api),
        'tickets-empty': (api) => XcTicketsPage(api: api..noTickets = true),
        'ticket-detail': (api) => XcTicketPage(api: api, id: 1),
        'invite-earned': (api) =>
            XcInvitePage(api: api, panelWebUrl: 'https://example.invalid'),
        'invite-none': (api) => XcInvitePage(
          api: api..earned = false,
          panelWebUrl: 'https://example.invalid',
        ),
      };
      xcVisual('account pages render at ${size.name} $theme', (tester) async {
        for (final entry in pages.entries) {
          await _pump(
            tester,
            size,
            brightness,
            KeyedSubtree(key: Key(entry.key), child: entry.value(_ShotApi())),
          );
          await shot(tester, entry.key);
        }
      });

      xcVisual('form validation renders at ${size.name} $theme', (
        tester,
      ) async {
        await _pump(tester, size, brightness, XcNewTicketPage(api: _ShotApi()));
        await shot(tester, 'ticket-new');
        await _reveal(tester, find.text('提交'));
        await tester.tap(find.text('提交'));
        await xcSettle(tester);
        expect(find.text('请填写主题'), findsOneWidget);
        await _reveal(tester, find.text('请填写主题'));
        await shot(tester, 'ticket-new-validation');
        await _pump(
          tester,
          size,
          brightness,
          XcChangePasswordPage(api: _ShotApi()),
        );
        await tester.tap(find.text('保存新密码'));
        await xcSettle(tester);
        await shot(tester, 'account-password-validation');
      });

      xcVisual('gift card states render at ${size.name} $theme', (
        tester,
      ) async {
        final api = _ShotApi();
        await _pump(
          tester,
          size,
          brightness,
          XcGiftCardsPage(api: api, onRedeemed: () async {}),
        );
        await tester.enterText(find.byType(TextField), 'GIFT8F2K29QD');
        await tester.tap(find.text('检查礼品卡'));
        await xcSettle(tester);
        expect(find.text('可以兑换'), findsOneWidget);
        await shot(tester, 'giftcard-preview');
        await tester.tap(find.text('确认兑换'));
        await xcSettle(tester);
        await tester.tap(find.text('确认'));
        await xcSettle(tester);
        expect(find.text('兑换成功'), findsOneWidget);
        await shot(tester, 'giftcard-success');
        api.giftError = const XbApiException(
          XbErrorKind.validation,
          message: '礼品卡已被使用或已过期',
        );
        await _pump(
          tester,
          size,
          brightness,
          XcGiftCardsPage(
            key: const Key('failed'),
            api: api,
            onRedeemed: () async {},
          ),
        );
        await tester.enterText(find.byType(TextField), 'GIFT0000USED');
        await tester.tap(find.text('检查礼品卡'));
        await xcSettle(tester);
        expect(find.text('礼品卡检查失败'), findsOneWidget);
        await shot(tester, 'giftcard-failed');
      });

      xcVisual('client host states render at ${size.name} $theme', (
        tester,
      ) async {
        await _pump(
          tester,
          size,
          brightness,
          XcAppHost(startupFailed: true, onRetry: () {}),
          overrides: [initProvider.overrideWithBuild((_, _) => false)],
        );
        expect(find.text('客户端初始化未完成'), findsOneWidget);
        await shot(tester, 'host-startup-failed');
        await _pump(
          tester,
          size,
          brightness,
          const Scaffold(body: XcClosingPanel()),
        );
        await shot(tester, 'host-closing');
        await _pump(
          tester,
          size,
          brightness,
          Scaffold(body: XcClosingPanel(onRetry: () {})),
        );
        await shot(tester, 'host-closing-retry');
        for (final phase in [
          PolicyCheckPhase.error,
          PolicyCheckPhase.checking,
        ]) {
          await _pump(
            tester,
            size,
            brightness,
            Column(
              children: [
                XcPolicyAdmissionBanner(
                  state: RemoteState(phase: phase),
                  onRetry: () {},
                ),
                Expanded(
                  child: XcHomeHarness(
                    data: xcHomeData(),
                    canConnect: false,
                    blockReason: '正在核验客户端版本',
                  ),
                ),
              ],
            ),
          );
          await shot(tester, 'host-policy-${phase.name}');
        }
        await _pump(
          tester,
          size,
          brightness,
          XcLoginPage(
            displayName: 'Example 加速器',
            panelWebUrl: Uri.parse('https://example.invalid'),
            footer: const XcExitAction(),
            onLogin: (_, _) async {},
          ),
          overrides: _clientOverrides,
        );
        expect(find.text('退出客户端'), findsOneWidget);
        await shot(tester, 'login-managed-exit');
      });
    }
  }

  xcVisual('motion: account page entrance', (tester) async {
    xcView(tester, XcShotSize.phone);
    await tester.pumpWidget(
      ProviderScope(
        overrides: _clientOverrides,
        child: xcFramed(xcApp(_account(_ShotApi()))),
      ),
    );
    var elapsed = 0;
    for (final ms in [0, 120, 300, 700]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(tester, 'motion-account-entrance-${ms}ms', XcShotSize.phone);
    }
    await xcSettle(tester);
  });

  xcVisual('motion: coupon verification swaps in', (tester) async {
    await _pump(
      tester,
      XcShotSize.phone,
      Brightness.light,
      XcPlanDetailPage(api: _ShotApi(), plan: _plans[1]),
    );
    await _reveal(tester, find.text('验证优惠码'));
    await tester.enterText(find.byType(TextField), 'WELCOME5');
    await tester.tap(find.text('验证优惠码'));
    var elapsed = 0;
    for (final ms in [40, 140, 260, 420]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(tester, 'motion-checkout-coupon-${ms}ms', XcShotSize.phone);
    }
    await xcSettle(tester);
    expect(find.text('优惠已生效'), findsOneWidget);
  });

  xcVisual('motion: order moves from pending to processing', (tester) async {
    final api = _ShotApi();
    await _pump(
      tester,
      XcShotSize.phone,
      Brightness.light,
      _commerce(XcOrderPage(api: api, tradeNo: _trade)),
    );
    api.orderStatus = OrderStatus.processing;
    await tester.pump(const Duration(milliseconds: 1000));
    var elapsed = 0;
    for (final ms in [16, 80, 180, 320]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(tester, 'motion-order-switch-${ms}ms', XcShotSize.phone);
    }
    await xcSettle(tester);
    expect(find.text('开通中'), findsWidgets);
    await _drain(tester);
  });

  xcVisual('motion: update download progress', (tester) async {
    final notifier = await _showUpdate(
      tester,
      XcShotSize.phone,
      Brightness.light,
      _updateStates['downloading']!,
    );
    notifier.value = const XcUpdateState(
      phase: XcUpdatePhase.downloading,
      decision: _notify,
      received: 37 * _mib,
      total: 41 * _mib,
    );
    var elapsed = 0;
    for (final ms in [0, 120, 260, 600]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(tester, 'motion-update-progress-${ms}ms', XcShotSize.phone);
    }
    expect(find.text('90%'), findsOneWidget);
  });
}
