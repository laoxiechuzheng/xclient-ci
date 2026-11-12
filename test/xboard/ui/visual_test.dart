import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/color.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:fl_clash/xboard/ui/nodes_view.dart';
import 'package:fl_clash/xboard/ui/restriction_notice.dart';
import 'package:fl_clash/xboard/ui/shell.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

const _seed = Color(0xff007aff);
final _now = DateTime(2026, 11, 12, 20, 30);
const _gib = 1024 * 1024 * 1024;

enum _Size {
  phone(Size(390, 844), 1.5),
  small(Size(360, 740), 1.5),
  desktop(Size(1280, 800), 1),
  wide(Size(1920, 1080), 1);

  const _Size(this.size, this.ratio);
  final Size size;
  final double ratio;
}

ThemeData _theme(Brightness brightness, {Color seed = _seed}) {
  final scheme = seededColorScheme(seedColor: seed, brightness: brightness);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    fontFamily: Platform.isWindows ? 'XcQa' : null,
    extensions: [
      if (brightness == Brightness.dark) ElevatedColorScheme(scheme.elevated),
    ],
  ).withAppShapes.withAppSurfaces.withAppTypography;
}

Widget _app(
  Widget child, {
  Brightness brightness = Brightness.light,
  Color seed = _seed,
  bool reduceMotion = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  themeAnimationStyle: AnimationStyle.noAnimation,
  theme: _theme(brightness, seed: seed),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
    child: child!,
  ),
  home: child,
);

int _epoch(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

XcHomeData _data({
  double usedGb = 12,
  double totalGb = 100,
  int daysLeft = 73,
  List<int> stats = const [0, 0, 0],
  bool plan = true,
}) => XcHomeData(
  user: const {'email': 'lin.demo@example.invalid', 'balance': 2000},
  summary: {
    if (plan) 'plan': {'name': '安心专线 · 月付', 'reset_traffic_price': 9.9},
    if (plan) 'plan_id': 1,
    'u': usedGb * 0.18 * _gib,
    'd': usedGb * 0.82 * _gib,
    'transfer_enable': totalGb * _gib,
    'expired_at': _epoch(_now.add(Duration(days: daysLeft))),
    'next_reset_at': _epoch(_now.add(const Duration(days: 6, hours: 2))),
    'online_count': 1,
    'device_limit': 3,
    'speed_limit': 300,
  },
  stats: stats,
  notices: const [
    {
      'title': '春节线路升级完成',
      'content': '<p>香港、日本线路已完成扩容，晚高峰更稳定。如遇问题请提交工单，我们会第一时间处理。</p>',
    },
  ],
);

class _HomeHarness extends StatefulWidget {
  const _HomeHarness({
    this.data,
    this.error,
    this.running = false,
    this.canConnect = true,
    this.phase = SyncPhase.ok,
    this.blockReason,
    this.banner,
    this.onConnect,
    this.onOrders,
  });
  final XcHomeData? data;
  final Object? error;
  final bool running;
  final bool canConnect;
  final SyncPhase phase;
  final String? blockReason;
  final Widget? banner;
  final VoidCallback? onConnect;
  final VoidCallback? onOrders;
  @override
  State<_HomeHarness> createState() => _HomeHarnessState();
}

class _HomeHarnessState extends State<_HomeHarness> {
  int index = 0;
  @override
  Widget build(BuildContext context) => XcShellLayout(
    title: 'Example 加速器',
    selectedIndex: index,
    onSelected: (value) => setState(() => index = value),
    banner: widget.banner,
    pageTitle: index == 2 ? '选购套餐' : null,
    pageSubtitle: index == 2 ? '支付成功后自动生效，可随时续费或升级' : null,
    child: index == 2
        ? const Center(child: Text('套餐列表'))
        : XcHomePanel(
            data: widget.data,
            error: widget.error,
            onRetry: () {},
            running: widget.running,
            canConnect: widget.canConnect,
            blockReason: widget.blockReason,
            syncPhase: widget.phase,
            selectedNodes: const {'节点选择': '日本 东京 01 · IEPL'},
            syncMessage: widget.blockReason ?? '节点已安全同步',
            sessionTimer: const Text('01:24:36'),
            now: () => _now,
            onConnect: widget.onConnect ?? () {},
            onPlans: () {},
            onNodes: () {},
            onSync: () async {},
            onOrders: widget.onOrders ?? () {},
            onTickets: () {},
            onNotices: () {},
            onCycle: () {},
            onResetPackage: () async {},
          ),
  );
}

const _blocked = SyncStatus(
  phase: SyncPhase.blocked,
  blockedCode: 'subscription_restricted',
  message: '当前网络触发订阅风控，请关闭其他代理或更换网络后重新检查。',
);

Future<void> _font(String family, String path) async {
  final file = File(path);
  if (!Platform.isWindows || !file.existsSync()) return;
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
  await loader.load();
}

void _view(WidgetTester tester, _Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size.size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _shot(WidgetTester tester, String name, _Size size) async {
  expect(tester.takeException(), isNull, reason: name);
  final path = Platform.environment['XC_UI_SCREENSHOTS'];
  if (path == null) return;
  await tester.runAsync(() async {
    final boundary =
        tester.renderObject(find.byKey(_frame)) as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: size.ratio);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$path/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

const _frame = Key('xc-visual-frame');

/// flutter_test paints shadows solid unless told otherwise; the screenshots
/// show them as the app does, and the flag is restored before the binding
/// checks its debug variables.
void _visual(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    });

Widget _framed(Widget child) => RepaintBoundary(key: _frame, child: child);

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await _font('XcQa', r'C:\Windows\Fonts\msyh.ttc');
    await _font('XcQa', r'C:\Windows\Fonts\msyhbd.ttc');
  });

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    for (final size in _Size.values) {
      _visual('login states render at ${size.name} $theme', (tester) async {
        _view(tester, size);
        var fail = true;
        await tester.pumpWidget(
          _framed(
            _app(
              brightness: brightness,
              XcLoginPage(
                displayName: 'Example 加速器',
                panelWebUrl: Uri.parse('https://example.invalid'),
                onLogin: (_, _) async {
                  await Future<void>.delayed(const Duration(seconds: 1));
                  if (fail) {
                    throw const XbApiException(XbErrorKind.validation);
                  }
                },
              ),
            ),
          ),
        );
        await _settle(tester);
        expect(find.text('登录'), findsOneWidget);
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel(RegExp(r'^\s*登录\s*$')), findsOneWidget);
        expect(find.byType(EditableText), findsNWidgets(2));
        semantics.dispose();
        await _shot(tester, '${size.name}-$theme-login-empty', size);
        await tester.tap(find.byKey(const Key('xc-login-submit')));
        await _settle(tester);
        expect(find.text('请输入邮箱'), findsOneWidget);
        expect(find.text('请输入密码'), findsOneWidget);
        await _shot(tester, '${size.name}-$theme-login-validation', size);
        await tester.enterText(
          find.byKey(const Key('xc-login-email')),
          'lin.demo@example.invalid',
        );
        await tester.enterText(
          find.byKey(const Key('xc-login-password')),
          'password123',
        );
        await _settle(tester);
        await _shot(tester, '${size.name}-$theme-login-typing', size);
        await tester.tap(find.byKey(const Key('xc-login-submit')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('正在登录'), findsOneWidget);
        await _shot(tester, '${size.name}-$theme-login-loading', size);
        await tester.pump(const Duration(seconds: 1));
        await _settle(tester);
        expect(find.text('操作失败，请稍后重试'), findsOneWidget);
        await _shot(tester, '${size.name}-$theme-login-error', size);
        fail = false;
      });

      final states = <String, Widget Function()>{
        'off': () => _HomeHarness(data: _data()),
        'connecting': () => _HomeHarness(data: _data()),
        'on': () => _HomeHarness(data: _data(), running: true),
        'low': () => _HomeHarness(data: _data(usedGb: 92, daysLeft: 3)),
        'pending': () => _HomeHarness(data: _data(stats: const [1, 1, 0])),
        'restricted': () => _HomeHarness(
          data: _data(),
          canConnect: false,
          phase: SyncPhase.blocked,
          blockReason: '订阅受限：当前网络暂时无法获取节点',
          banner: XcRestrictionNotice(
            status: _blocked,
            onCheck: () async {},
            onPlans: () {},
            onTickets: () {},
          ),
        ),
        'loading': () => const _HomeHarness(phase: SyncPhase.syncing),
        'error': () =>
            const _HomeHarness(error: XbApiException(XbErrorKind.network)),
        'noplan': () => _HomeHarness(data: _data(plan: false, totalGb: 0)),
      };
      for (final entry in states.entries) {
        _visual('home ${entry.key} renders at ${size.name} $theme', (
          tester,
        ) async {
          _view(tester, size);
          await tester.pumpWidget(
            _framed(_app(brightness: brightness, entry.value())),
          );
          await _settle(tester);
          if (entry.key == 'restricted') {
            expect(find.text('我知道了'), findsOneWidget);
            await _shot(tester, '${size.name}-$theme-restriction-prompt', size);
            await tester.tap(find.text('我知道了'));
            await _settle(tester);
          }
          if (entry.key == 'connecting') {
            await tester.tap(find.bySemanticsLabel('连接'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            expect(find.text('正在连接…'), findsOneWidget);
            expect(find.text('未连接'), findsNothing);
          }
          await _shot(tester, '${size.name}-$theme-home-${entry.key}', size);
        });
      }

      _visual('nodes renders at ${size.name} $theme', (tester) async {
        _view(tester, size);
        final container = _nodesContainer(size.size);
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: _framed(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh', 'CN'),
                theme: _theme(brightness),
                localizationsDelegates: const [
                  AppLocalizations.delegate,
                  AppUiLocalizations.delegate,
                  ...GlobalMaterialLocalizations.delegates,
                ],
                supportedLocales: AppLocalizations.delegate.supportedLocales,
                builder: (context, child) => wrapAppScopes(context, child!),
                home: XcShellLayout(
                  title: 'Example 加速器',
                  selectedIndex: 1,
                  onSelected: (_) {},
                  child: const XcNodesView(),
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await _shot(tester, '${size.name}-$theme-nodes', size);
      });

      _visual('restricted nodes render at ${size.name} $theme', (tester) async {
        _view(tester, size);
        await tester.pumpWidget(
          _framed(
            _app(
              brightness: brightness,
              XcShellLayout(
                title: 'Example 加速器',
                selectedIndex: 1,
                onSelected: (_) {},
                child: XcRestrictedNodesView(
                  status: _blocked,
                  onCheck: () async {},
                ),
              ),
            ),
          ),
        );
        await _settle(tester);
        await _shot(tester, '${size.name}-$theme-nodes-restricted', size);
      });
    }
  }

  _visual('three brand seeds keep the same structure', (tester) async {
    _view(tester, _Size.phone);
    for (final (name, seed) in const [
      ('teal', Color(0xff0f8b8d)),
      ('violet', Color(0xff6c4cf5)),
      ('amber', Color(0xffd9822b)),
    ]) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          _framed(
            _app(
              seed: seed,
              brightness: brightness,
              _HomeHarness(data: _data(usedGb: 86), running: true),
            ),
          ),
        );
        await _settle(tester);
        await _shot(
          tester,
          'brand-$name-${brightness.name}-home-on',
          _Size.phone,
        );
      }
    }
  });

  _visual('connect orb animates through connecting and settles on', (
    tester,
  ) async {
    _view(tester, _Size.phone);
    var running = false;
    var taps = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      _framed(
        _app(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return _HomeHarness(
                data: _data(),
                running: running,
                onConnect: () => taps++,
              );
            },
          ),
        ),
      ),
    );
    await _settle(tester);
    await tester.tap(find.bySemanticsLabel('连接'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('正在连接'), warnIfMissed: false);
    expect(taps, 1);
    for (final ms in [0, 350, 700]) {
      await tester.pump(Duration(milliseconds: ms == 0 ? 16 : 350));
      expect(find.text('正在连接…'), findsOneWidget);
      await _shot(tester, 'motion-connect-1-connecting-${ms}ms', _Size.phone);
    }
    rebuild(() => running = true);
    await tester.pump();
    var elapsed = 0;
    for (final ms in [120, 450, 900]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await _shot(tester, 'motion-connect-2-connected-${ms}ms', _Size.phone);
    }
    await tester.pumpAndSettle();
    expect(find.text('已安全连接'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await _shot(tester, 'motion-connect-3-settled', _Size.phone);
  });

  _visual('pending connect gives up after twenty seconds', (tester) async {
    _view(tester, _Size.phone);
    await tester.pumpWidget(_app(_HomeHarness(data: _data())));
    await _settle(tester);
    await tester.tap(find.bySemanticsLabel('连接'));
    await tester.pump();
    expect(find.text('正在连接…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('未连接'), findsOneWidget);
  });

  _visual('reduced motion leaves nothing animating', (tester) async {
    _view(tester, _Size.phone);
    await tester.pumpWidget(
      _app(reduceMotion: true, _HomeHarness(data: _data())),
    );
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
    await tester.tap(find.bySemanticsLabel('连接'));
    await tester.pump();
    expect(find.text('正在连接…'), findsOneWidget);
    // Material's own ink highlight still fades; the orbit must not start.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('正在连接…'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  _visual('home entrance staggers in and settles', (tester) async {
    _view(tester, _Size.phone);
    await tester.pumpWidget(_framed(_app(_HomeHarness(data: _data()))));
    var elapsed = 0;
    for (final ms in [0, 120, 300, 700]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await _shot(tester, 'motion-entrance-${ms}ms', _Size.phone);
    }
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  _visual('page switch fades through and settles', (tester) async {
    _view(tester, _Size.phone);
    await tester.pumpWidget(_framed(_app(_HomeHarness(data: _data()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('套餐'));
    var elapsed = 0;
    for (final ms in [60, 160, 300, 460]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await _shot(tester, 'motion-page-switch-${ms}ms', _Size.phone);
    }
    await tester.pumpAndSettle();
    expect(find.text('套餐列表'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  _visual('suggestions point at the next step', (tester) async {
    _view(tester, _Size.phone);
    var orders = 0;
    await tester.pumpWidget(
      _app(
        _HomeHarness(
          data: _data(usedGb: 92, stats: const [2, 0, 0]),
          onOrders: () => orders++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('有 2 笔订单待支付'), findsOneWidget);
    expect(find.text('本期流量已用 92%'), findsOneWidget);
    await tester.tap(find.text('去支付'));
    expect(orders, 1);
  });
}

ProviderContainer _nodesContainer(Size size) {
  final regions = [
    '香港 01 · 专线',
    '香港 02 · 专线',
    '日本 东京 01 · IEPL',
    '日本 大阪 02',
    '新加坡 01',
    '台湾 01',
    '美国 洛杉矶 01',
    '英国 伦敦 01',
  ];
  final proxies = [
    for (final name in regions) Proxy(name: name, type: 'Vless'),
  ];
  final group = Group(
    name: '节点选择',
    type: GroupType.Selector,
    hidden: false,
    now: regions[2],
    all: proxies,
  );
  final profile = Profile.normal().copyWith(
    currentGroupName: group.name,
    selectedMap: {group.name: regions[2]},
    unfoldSet: {group.name},
  );
  final container = ProviderContainer(
    overrides: [
      profilesProvider.overrideWith(() => TestProfiles([profile])),
      currentProfileIdProvider.overrideWithBuild((_, _) => profile.id),
      currentGroupsStateProvider.overrideWithValue(GroupsState(value: [group])),
      groupsProvider.overrideWithValue([group]),
    ],
  );
  globalState.container = container;
  container.read(viewSizeProvider.notifier).update((_) => size);
  container.listen(proxiesStyleSettingProvider, (_, _) {});
  container
      .read(proxiesStyleSettingProvider.notifier)
      .update((state) => state.copyWith(type: ProxiesType.tab));
  return container;
}
