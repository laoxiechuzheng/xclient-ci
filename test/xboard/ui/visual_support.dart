import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/ui/color.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/surface.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/ui/shell.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';

const xcSeed = Color(0xff007aff);

enum XcShotSize {
  phone(Size(390, 844), 1.5),
  small(Size(360, 740), 1.5),
  desktop(Size(1280, 800), 1),
  wide(Size(1920, 1080), 1);

  const XcShotSize(this.size, this.ratio);
  final Size size;
  final double ratio;

  static const core = [phone, desktop];
}

ThemeData xcTheme(Brightness brightness, {Color seed = xcSeed}) {
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

Widget xcApp(
  Widget child, {
  Brightness brightness = Brightness.light,
  Color seed = xcSeed,
  bool reduceMotion = false,
  bool localized = false,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  themeAnimationStyle: AnimationStyle.noAnimation,
  theme: xcTheme(brightness, seed: seed),
  locale: localized ? const Locale('zh', 'CN') : null,
  localizationsDelegates: localized
      ? const [
          AppLocalizations.delegate,
          AppUiLocalizations.delegate,
          ...GlobalMaterialLocalizations.delegates,
        ]
      : null,
  supportedLocales: localized
      ? AppLocalizations.delegate.supportedLocales
      : const [Locale('en', 'US')],
  builder: (context, child) {
    final scoped = MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
      child: child!,
    );
    return localized ? wrapAppScopes(context, scoped) : scoped;
  },
  home: child,
);

Future<void> xcLoadFonts() async {
  for (final path in [
    r'C:\Windows\Fonts\msyh.ttc',
    r'C:\Windows\Fonts\msyhbd.ttc',
  ]) {
    final file = File(path);
    if (!Platform.isWindows || !file.existsSync()) continue;
    final loader = FontLoader('XcQa')
      ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await loader.load();
  }
}

void xcView(WidgetTester tester, XcShotSize size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size.size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

const _frame = Key('xc-visual-frame');

Widget xcFramed(Widget child) => RepaintBoundary(key: _frame, child: child);

Future<void> xcShot(WidgetTester tester, String name, XcShotSize size) async {
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

/// flutter_test paints shadows solid unless told otherwise; the screenshots
/// show them as the app does, and the flag is restored before the binding
/// checks its debug variables.
void xcVisual(String description, WidgetTesterCallback body) =>
    testWidgets(description, (tester) async {
      debugDisableShadows = false;
      try {
        await body(tester);
      } finally {
        debugDisableShadows = true;
      }
    });

Future<void> xcSettle(WidgetTester tester) async {
  for (var frame = 0; frame < 4; frame++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

final xcNow = DateTime(2026, 11, 12, 20, 30);
const _gib = 1024 * 1024 * 1024;

int _epoch(DateTime time) => time.millisecondsSinceEpoch ~/ 1000;

XcHomeData xcHomeData({
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
    'expired_at': _epoch(xcNow.add(Duration(days: daysLeft))),
    'next_reset_at': _epoch(xcNow.add(const Duration(days: 6, hours: 2))),
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

class XcHomeHarness extends StatefulWidget {
  const XcHomeHarness({
    super.key,
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
  State<XcHomeHarness> createState() => _XcHomeHarnessState();
}

class _XcHomeHarnessState extends State<XcHomeHarness> {
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
            now: () => xcNow,
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
