import 'dart:math' as math;

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/manager/window_manager.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/config.dart';
import 'package:fl_clash/providers/database.dart';
import 'package:fl_clash/providers/state.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/navigator.dart';
import 'package:fl_clash/views/disclaimer.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/ui/common/motion.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:fl_clash/xboard/ui/nodes_view.dart';
import 'package:fl_clash/xboard/ui/restriction_notice.dart';
import 'package:fl_clash/xboard/ui/shell.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';
import 'visual_support.dart';

const _blocked = SyncStatus(
  phase: SyncPhase.blocked,
  blockedCode: 'subscription_restricted',
  message: '当前网络触发订阅风控，请关闭其他代理或更换网络后重新检查。',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(xcLoadFonts);

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    for (final size in XcShotSize.values) {
      xcVisual('login states render at ${size.name} $theme', (tester) async {
        xcView(tester, size);
        var fail = true;
        await tester.pumpWidget(
          xcFramed(
            xcApp(
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
        await xcSettle(tester);
        expect(find.text('登录'), findsOneWidget);
        final semantics = tester.ensureSemantics();
        expect(find.bySemanticsLabel(RegExp(r'^\s*登录\s*$')), findsOneWidget);
        expect(find.byType(EditableText), findsNWidgets(2));
        semantics.dispose();
        await xcShot(tester, '${size.name}-$theme-login-empty', size);
        await tester.tap(find.byKey(const Key('xc-login-submit')));
        await xcSettle(tester);
        expect(find.text('请输入邮箱'), findsOneWidget);
        expect(find.text('请输入密码'), findsOneWidget);
        await xcShot(tester, '${size.name}-$theme-login-validation', size);
        await tester.enterText(
          find.byKey(const Key('xc-login-email')),
          'lin.demo@example.invalid',
        );
        await xcSettle(tester);
        expect(find.text('请输入邮箱'), findsNothing);
        expect(find.text('请输入密码'), findsOneWidget);
        await xcShot(tester, '${size.name}-$theme-login-corrected', size);
        await tester.enterText(
          find.byKey(const Key('xc-login-password')),
          'password123',
        );
        await xcSettle(tester);
        await xcShot(tester, '${size.name}-$theme-login-typing', size);
        await tester.tap(find.byKey(const Key('xc-login-submit')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.text('正在登录'), findsOneWidget);
        await xcShot(tester, '${size.name}-$theme-login-loading', size);
        await tester.pump(const Duration(seconds: 1));
        await xcSettle(tester);
        expect(find.text('操作失败，请稍后重试'), findsOneWidget);
        await xcShot(tester, '${size.name}-$theme-login-error', size);
        fail = false;
      });

      xcVisual('launch states render at ${size.name} $theme', (tester) async {
        xcView(tester, size);
        await tester.pumpWidget(
          xcFramed(
            xcApp(
              brightness: brightness,
              const XcLaunchView(displayName: 'Example 加速器'),
            ),
          ),
        );
        await xcSettle(tester);
        expect(find.text('正在准备安全连接…'), findsOneWidget);
        await xcShot(tester, '${size.name}-$theme-launch', size);
        await tester.pump(XcLaunchView.slowAfter);
        await xcSettle(tester);
        expect(find.text('网络较慢，仍在尝试…'), findsOneWidget);
        await xcShot(tester, '${size.name}-$theme-launch-slow', size);
        await tester.pumpWidget(const SizedBox.shrink());
      });

      if (size.platform != null) {
        xcVisual('the title bar lets the sign-in backdrop through at '
            '${size.name} $theme', (tester) async {
          xcView(tester, size);
          final caption = ValueNotifier(const WindowCaptionState());
          addTearDown(caption.dispose);
          for (final (name, overlaid, page) in [
            ('login-titlebar-opaque', false, _titlebarLogin),
            ('login-titlebar', true, _titlebarLogin),
            ('launch-titlebar', true, _titlebarLaunch),
          ]) {
            await tester.pumpWidget(
              xcFramed(
                xcApp(
                  key: ValueKey(name),
                  brightness: brightness,
                  localized: true,
                  _windowHeader(caption, overlaid: overlaid, child: page()),
                ),
              ),
            );
            await xcSettle(tester);
            await xcShot(tester, '${size.name}-$theme-$name', size);
          }
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }

      final states = <String, Widget Function()>{
        'off': () => XcHomeHarness(data: xcHomeData()),
        'connecting': () => XcHomeHarness(data: xcHomeData()),
        'on': () => XcHomeHarness(data: xcHomeData(), running: true),
        'low': () => XcHomeHarness(data: xcHomeData(usedGb: 92, daysLeft: 3)),
        'pending': () =>
            XcHomeHarness(data: xcHomeData(stats: const [1, 1, 0])),
        'restricted': () => XcHomeHarness(
          data: xcHomeData(),
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
        'loading': () => const XcHomeHarness(phase: SyncPhase.syncing),
        'error': () =>
            const XcHomeHarness(error: XbApiException(XbErrorKind.network)),
        'noplan': () =>
            XcHomeHarness(data: xcHomeData(plan: false, totalGb: 0)),
      };
      for (final entry in states.entries) {
        xcVisual('home ${entry.key} renders at ${size.name} $theme', (
          tester,
        ) async {
          xcView(tester, size);
          await tester.pumpWidget(
            xcFramed(xcApp(brightness: brightness, entry.value())),
          );
          await xcSettle(tester);
          if (entry.key == 'restricted') {
            expect(find.text('我知道了'), findsOneWidget);
            await xcShot(
              tester,
              '${size.name}-$theme-restriction-prompt',
              size,
            );
            await tester.tap(find.text('我知道了'));
            await xcSettle(tester);
          }
          if (entry.key == 'connecting') {
            await tester.tap(find.bySemanticsLabel('连接'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 600));
            expect(find.text('正在连接…'), findsOneWidget);
            expect(find.text('未连接'), findsNothing);
          }
          await xcShot(tester, '${size.name}-$theme-home-${entry.key}', size);
        });
      }

      xcVisual('nodes renders at ${size.name} $theme', (tester) async {
        xcView(tester, size);
        final container = _nodesContainer(size.size);
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: xcFramed(
              MaterialApp(
                debugShowCheckedModeBanner: false,
                locale: const Locale('zh', 'CN'),
                theme: xcTheme(brightness),
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
        await xcSettle(tester);
        await xcShot(tester, '${size.name}-$theme-nodes', size);
      });

      xcVisual('restricted nodes render at ${size.name} $theme', (
        tester,
      ) async {
        xcView(tester, size);
        await tester.pumpWidget(
          xcFramed(
            xcApp(
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
        await xcSettle(tester);
        await xcShot(tester, '${size.name}-$theme-nodes-restricted', size);
      });
    }
  }

  xcVisual('three brand seeds keep the same structure', (tester) async {
    xcView(tester, XcShotSize.phone);
    for (final (name, seed) in const [
      ('teal', Color(0xff0f8b8d)),
      ('violet', Color(0xff6c4cf5)),
      ('amber', Color(0xffd9822b)),
    ]) {
      for (final brightness in Brightness.values) {
        await tester.pumpWidget(
          xcFramed(
            xcApp(
              seed: seed,
              brightness: brightness,
              XcHomeHarness(data: xcHomeData(usedGb: 86), running: true),
            ),
          ),
        );
        await xcSettle(tester);
        await xcShot(
          tester,
          'brand-$name-${brightness.name}-home-on',
          XcShotSize.phone,
        );
      }
    }
  });

  xcVisual('connect orb animates through connecting and settles on', (
    tester,
  ) async {
    xcView(tester, XcShotSize.phone);
    var running = false;
    var taps = 0;
    late StateSetter rebuild;
    await tester.pumpWidget(
      xcFramed(
        xcApp(
          StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return XcHomeHarness(
                data: xcHomeData(),
                running: running,
                onConnect: () => taps++,
              );
            },
          ),
        ),
      ),
    );
    await xcSettle(tester);
    await tester.tap(find.bySemanticsLabel('连接'));
    await tester.pump();
    await tester.tap(find.bySemanticsLabel('正在连接'), warnIfMissed: false);
    expect(taps, 1);
    for (final ms in [0, 350, 700]) {
      await tester.pump(Duration(milliseconds: ms == 0 ? 16 : 350));
      expect(find.text('正在连接…'), findsOneWidget);
      await xcShot(
        tester,
        'motion-connect-1-connecting-${ms}ms',
        XcShotSize.phone,
      );
    }
    rebuild(() => running = true);
    await tester.pump();
    var elapsed = 0;
    for (final ms in [120, 450, 900]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(
        tester,
        'motion-connect-2-connected-${ms}ms',
        XcShotSize.phone,
      );
    }
    await tester.pumpAndSettle();
    expect(find.text('已安全连接'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
    await xcShot(tester, 'motion-connect-3-settled', XcShotSize.phone);
  });

  xcVisual('pending connect gives up after twenty seconds', (tester) async {
    xcView(tester, XcShotSize.phone);
    await tester.pumpWidget(xcApp(XcHomeHarness(data: xcHomeData())));
    await xcSettle(tester);
    await tester.tap(find.bySemanticsLabel('连接'));
    await tester.pump();
    expect(find.text('正在连接…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 21));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('未连接'), findsOneWidget);
  });

  xcVisual('reduced motion leaves nothing animating', (tester) async {
    xcView(tester, XcShotSize.phone);
    await tester.pumpWidget(
      xcApp(reduceMotion: true, XcHomeHarness(data: xcHomeData())),
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

  xcVisual('home entrance staggers in and settles', (tester) async {
    xcView(tester, XcShotSize.phone);
    await tester.pumpWidget(xcFramed(xcApp(XcHomeHarness(data: xcHomeData()))));
    await xcPrime(tester);
    var elapsed = 0;
    for (final ms in [0, 120, 300, 700]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(tester, 'motion-entrance-${ms}ms', XcShotSize.phone);
    }
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  xcVisual('the sign-in page crosses 900 dp at rest', (tester) async {
    xcView(tester, XcShotSize.desktop);
    tester.view.physicalSize = const Size(890, 760);
    await tester.pumpWidget(
      xcFramed(
        xcApp(
          XcLoginPage(
            displayName: 'Example 加速器',
            panelWebUrl: Uri.parse('https://example.invalid'),
            onLogin: (_, _) async {},
          ),
        ),
      ),
    );
    await xcSettle(tester);
    await xcShot(tester, 'breakpoint-890-before', XcShotSize.desktop);
    for (final width in [910, 890]) {
      tester.view.physicalSize = Size(width.toDouble(), 760);
      await tester.pump();
      final entrances = tester.widgetList<Opacity>(
        find.descendant(
          of: find.byType(XcEntrance),
          matching: find.byType(Opacity),
        ),
      );
      expect(entrances.map((e) => e.opacity), everyElement(1));
      await xcShot(tester, 'breakpoint-$width-switched', XcShotSize.desktop);
    }
  });

  for (final brightness in Brightness.values) {
    final theme = brightness.name;
    for (final window in _windows) {
      final width = window.width.toInt();
      xcVisual('the sign-in backdrop stays composed at $width dp $theme', (
        tester,
      ) async {
        xcView(tester, XcShotSize.desktop);
        tester.view.physicalSize = window;
        final caption = ValueNotifier(const WindowCaptionState());
        addTearDown(caption.dispose);
        for (final (name, page) in [
          ('login', _titlebarLogin),
          ('launch', _titlebarLaunch),
        ]) {
          await tester.pumpWidget(
            xcFramed(
              xcApp(
                key: ValueKey(name),
                brightness: brightness,
                localized: true,
                _windowHeader(caption, overlaid: true, child: page()),
              ),
            ),
          );
          await xcSettle(tester);
          await xcShot(tester, 'window$width-$theme-$name', XcShotSize.desktop);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    xcVisual('first run: the launch clock starts when the disclaimer closes '
        '$theme', (tester) async {
      final signedOut = await _pumpStartup(tester, brightness);
      final consent = requestDisclaimerConsent();
      await _frames(tester, 1000);
      expect(find.byType(DisclaimerView), findsOneWidget);
      await xcShot(tester, 'firstrun-$theme-0-disclaimer', XcShotSize.desktop);
      await tester.pump(const Duration(seconds: 9));
      rootNavigatorKey.currentState!.pop(true);
      await _shootLaunch(tester, 'firstrun-$theme', first: 1, const [
        (150, null),
        (600, false),
        (3900, false),
        (4500, true),
      ]);
      expect(await consent, isTrue);
      signedOut.value = true;
      await xcSettle(tester);
      await xcShot(tester, 'firstrun-$theme-5-login', XcShotSize.desktop);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    xcVisual('cold start: preparing, then slow, then the sign-in page $theme', (
      tester,
    ) async {
      final signedOut = await _pumpStartup(tester, brightness);
      await _shootLaunch(tester, 'coldstart-$theme', const [
        (100, null),
        (700, false),
        (3900, false),
        (4500, true),
      ]);
      signedOut.value = true;
      await xcSettle(tester);
      await xcShot(tester, 'coldstart-$theme-4-login', XcShotSize.desktop);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  xcVisual('page switch fades through and settles', (tester) async {
    xcView(tester, XcShotSize.phone);
    await tester.pumpWidget(xcFramed(xcApp(XcHomeHarness(data: xcHomeData()))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('套餐'));
    var elapsed = 0;
    for (final ms in [60, 160, 300, 460]) {
      await tester.pump(Duration(milliseconds: ms - elapsed));
      elapsed = ms;
      await xcShot(tester, 'motion-page-switch-${ms}ms', XcShotSize.phone);
    }
    await tester.pumpAndSettle();
    expect(find.text('套餐列表'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse);
  });

  xcVisual('suggestions point at the next step', (tester) async {
    xcView(tester, XcShotSize.phone);
    var orders = 0;
    await tester.pumpWidget(
      xcApp(
        XcHomeHarness(
          data: xcHomeData(usedGb: 92, stats: const [2, 0, 0]),
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
    const Proxy(name: '自动选择', type: 'URLTest'),
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
  container.read(delayDataSourceProvider.notifier).setDelays([
    for (final (name, value) in [
      ('香港 01 · 专线', 38),
      ('香港 02 · 专线', 120),
      ('日本 东京 01 · IEPL', 64),
      ('日本 大阪 02', 420),
      ('新加坡 01', -1),
      ('美国 洛杉矶 01', 190),
    ])
      Delay(name: name, url: defaultTestUrl, value: value),
  ]);
  return container;
}

Widget _titlebarLogin() => XcLoginPage(
  displayName: 'Example 加速器',
  panelWebUrl: Uri.parse('https://example.invalid'),
  onLogin: (_, _) async {},
);

Widget _titlebarLaunch() => const XcLaunchView(displayName: 'Example 加速器');

/// Window sizes from the native review: the default window, the widest a
/// 1512 dp display allows, a full HD screen, and a maximised QHD screen.
const _windows = [
  Size(1264, 871),
  Size(1514, 956),
  Size(1920, 1080),
  Size(2544, 1383),
];

Widget _windowHeader(
  ValueNotifier<WindowCaptionState> caption, {
  required bool overlaid,
  required Widget child,
}) => WindowHeaderLayout(
  height: 32,
  overlaid: overlaid,
  header: WindowHeaderBar(
    height: 32,
    backdropOpacity: overlaid ? 0 : null,
    divider: !overlaid,
    onDragStart: () {},
    onDoubleTap: () {},
    actions: WindowHeaderActions(
      state: caption,
      onPin: () {},
      onMinimize: () {},
      onMaximize: () {},
      onClose: () {},
    ),
  ),
  child: child,
);

/// The startup path of a branded window: the launch view as the root page,
/// where the disclaimer is pushed, until [ValueNotifier.value] signs out.
Future<ValueNotifier<bool>> _pumpStartup(
  WidgetTester tester,
  Brightness brightness,
) async {
  final window = _windows.first;
  xcView(tester, XcShotSize.desktop);
  tester.view.physicalSize = window;
  final container = ProviderContainer();
  addTearDown(container.dispose);
  globalState.container = container;
  container.read(viewSizeProvider.notifier).update((_) => window);
  final signedOut = ValueNotifier(false);
  addTearDown(signedOut.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: xcFramed(
        xcApp(
          brightness: brightness,
          localized: true,
          navigatorKey: rootNavigatorKey,
          ValueListenableBuilder(
            valueListenable: signedOut,
            builder: (_, out, _) => out
                ? _titlebarLogin()
                : XcLaunchView(
                    key: XcLaunchView.handoff,
                    displayName: 'Example 加速器',
                  ),
          ),
        ),
      ),
    ),
  );
  return signedOut;
}

Future<void> _frames(WidgetTester tester, int ms) async {
  for (var left = ms; left > 0; left -= 50) {
    await tester.pump(Duration(milliseconds: math.min(50, left)));
  }
}

Future<void> _shootLaunch(
  WidgetTester tester,
  String prefix,
  List<(int, bool?)> frames, {
  int first = 0,
}) async {
  var elapsed = 0;
  for (final (index, (ms, slow)) in frames.indexed) {
    await _frames(tester, ms - elapsed);
    elapsed = ms;
    if (slow != null) {
      expect(
        find.text('网络较慢，仍在尝试…'),
        slow ? findsOneWidget : findsNothing,
        reason: '$prefix $ms ms',
      );
      expect(
        find.text('正在准备安全连接…'),
        slow ? findsNothing : findsOneWidget,
        reason: '$prefix $ms ms',
      );
    }
    await xcShot(
      tester,
      '$prefix-${first + index}-${ms}ms',
      XcShotSize.desktop,
    );
  }
}
