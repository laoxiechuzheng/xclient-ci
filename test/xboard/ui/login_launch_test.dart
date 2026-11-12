import 'dart:async';
import 'dart:math' as math;

import 'package:fl_clash/providers/providers.dart' show initProvider;
import 'package:fl_clash/xboard/app_host.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/ui/account/account_pages.dart';
import 'package:fl_clash/xboard/ui/account/support_pages.dart';
import 'package:fl_clash/xboard/ui/common/components.dart';
import 'package:fl_clash/xboard/ui/common/gradient.dart';
import 'package:fl_clash/xboard/ui/common/motion.dart';
import 'package:fl_clash/xboard/ui/common/tokens.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'visual_support.dart';

class _Api extends Fake implements XboardApi {}

const _brand = 'Example 加速器';

Widget _login() => XcLoginPage(
  displayName: _brand,
  panelWebUrl: Uri.parse('https://example.invalid'),
  onLogin: (_, _) async {},
);

void _size(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Iterable<double> _entranceOpacities(WidgetTester tester) => tester
    .widgetList<Opacity>(
      find.descendant(
        of: find.byType(XcEntrance),
        matching: find.byType(Opacity),
      ),
    )
    .map((opacity) => opacity.opacity);

/// The painted button; Android pads a small one's hit area to 48 dp.
double _buttonHeight(WidgetTester tester, Key key) => tester
    .getSize(
      find.descendant(of: find.byKey(key), matching: find.byType(Material)),
    )
    .height;

Future<void> _onPlatform(
  TargetPlatform platform,
  Future<void> Function() body,
) async {
  debugDefaultTargetPlatformOverride = platform;
  try {
    await body();
  } finally {
    debugDefaultTargetPlatformOverride = null;
  }
}

void main() {
  group('desktop density', () {
    testWidgets('brand controls keep their sizes on every platform', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      final fields = <TargetPlatform, double>{};
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.windows,
        TargetPlatform.macOS,
      ]) {
        await _onPlatform(platform, () async {
          await tester.pumpWidget(
            KeyedSubtree(key: UniqueKey(), child: xcApp(_login())),
          );
          await xcSettle(tester);
          expect(
            _buttonHeight(tester, const Key('xc-login-submit')),
            XcButtonSize.large.height,
            reason: '$platform',
          );
          fields[platform] = tester
              .getSize(find.byKey(const Key('xc-login-email')))
              .height;
          await tester.pumpWidget(
            xcApp(
              Scaffold(
                body: Column(
                  children: [
                    for (final size in XcButtonSize.values)
                      for (final variant in XcButtonVariant.values)
                        XcButton(
                          buttonKey: Key('${size.name}-${variant.name}'),
                          label: '按钮',
                          size: size,
                          variant: variant,
                          onPressed: () {},
                        ),
                  ],
                ),
              ),
            ),
          );
          for (final size in XcButtonSize.values) {
            for (final variant in XcButtonVariant.values) {
              expect(
                _buttonHeight(tester, Key('${size.name}-${variant.name}')),
                variant == XcButtonVariant.primary
                    ? math.max(size.height, 44)
                    : size.height,
                reason: '$platform ${size.name} ${variant.name}',
              );
            }
          }
        });
      }
      expect(fields.values.toSet(), hasLength(1), reason: '$fields');
    });
  });

  group('form validation', () {
    testWidgets('an empty submit keeps its errors until a field changes', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(xcApp(_login()));
      await xcSettle(tester);
      await tester.tap(find.byKey(const Key('xc-login-submit')));
      await xcSettle(tester);
      expect(find.text('请输入邮箱'), findsOneWidget);
      expect(find.text('请输入密码'), findsOneWidget);

      tester.view.physicalSize = const Size(400, 800);
      await xcSettle(tester);
      expect(find.text('请输入邮箱'), findsOneWidget);
      expect(find.text('请输入密码'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('xc-login-email')),
        'lin.demo',
      );
      await tester.pump();
      expect(find.text('请输入邮箱'), findsNothing);
      expect(find.text('邮箱格式不正确'), findsOneWidget);
      expect(find.text('请输入密码'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('xc-login-email')),
        'lin.demo@example.invalid',
      );
      await tester.enterText(
        find.byKey(const Key('xc-login-password')),
        'password123',
      );
      await tester.pump();
      expect(find.text('邮箱格式不正确'), findsNothing);
      expect(find.text('请输入密码'), findsNothing);
    });

    testWidgets('no field validates before the first submit', (tester) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(xcApp(_login()));
      await xcSettle(tester);
      await tester.enterText(find.byKey(const Key('xc-login-email')), 'lin');
      await tester.pump();
      expect(find.text('邮箱格式不正确'), findsNothing);
    });

    testWidgets('the password and ticket forms clear a corrected field', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(xcApp(XcChangePasswordPage(api: _Api())));
      await xcSettle(tester);
      await tester.tap(find.text('保存新密码'));
      await xcSettle(tester);
      expect(find.text('请输入密码'), findsNWidgets(2));
      await tester.enterText(find.byType(TextFormField).first, 'password123');
      await tester.pump();
      expect(find.text('请输入密码'), findsOneWidget);

      await tester.pumpWidget(xcApp(XcNewTicketPage(api: _Api())));
      await xcSettle(tester);
      await tester.ensureVisible(find.text('提交'));
      await tester.tap(find.text('提交'));
      await xcSettle(tester);
      expect(find.text('请填写主题'), findsOneWidget);
      await tester.enterText(find.byType(TextFormField).first, '无法连接');
      await tester.pump();
      expect(find.text('请填写主题'), findsNothing);
      expect(find.text('请描述您的问题'), findsOneWidget);
    });
  });

  group('entrance', () {
    testWidgets('starts once the first frame has been rasterized', (
      tester,
    ) async {
      await tester.pumpWidget(
        xcApp(const Scaffold(body: XcEntrance(child: Text('内容')))),
      );
      expect(_entranceOpacities(tester).single, 1 / 255);
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_entranceOpacities(tester).single, 1 / 255);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_entranceOpacities(tester).single, 1 / 255);
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_entranceOpacities(tester).single, greaterThan(0.5));
      await tester.pumpAndSettle();
      expect(_entranceOpacities(tester).single, 1);
    });

    testWidgets('crossing the 900 dp breakpoint shows the page at rest', (
      tester,
    ) async {
      _size(tester, const Size(1280, 800));
      await tester.pumpWidget(xcApp(_login()));
      await xcSettle(tester);
      for (final width in [880.0, 1280.0]) {
        tester.view.physicalSize = Size(width, 800);
        await tester.pump();
        expect(_entranceOpacities(tester), everyElement(1), reason: '$width');
        expect(tester.hasRunningAnimations, isFalse, reason: '$width');
      }
    });

    testWidgets('a first wide layout still plays its entrance', (tester) async {
      _size(tester, const Size(1280, 800));
      await tester.pumpWidget(xcApp(_login()));
      expect(_entranceOpacities(tester), everyElement(1 / 255));
    });
  });

  group('wide layout', () {
    const pitch = '一键连接，\n安心畅游网络';

    Future<({double pitch, Rect panel, double form, double status})> measure(
      WidgetTester tester,
      Size size,
    ) async {
      _size(tester, size);
      await tester.pumpWidget(xcApp(_login()));
      await xcSettle(tester);
      final panel = tester.getRect(
        find.ancestor(
          of: find.text(pitch),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is XcGradientDecoration,
          ),
        ),
      );
      final shown = (
        pitch: tester.getTopLeft(find.text(pitch)).dx,
        panel: panel,
        form: tester.getCenter(find.byKey(const Key('xc-login-submit'))).dx,
      );
      await tester.pumpWidget(
        xcApp(const XcLaunchView(displayName: _brand), key: UniqueKey()),
      );
      await xcSettle(tester);
      final status = tester
          .getCenter(
            find
                .ancestor(
                  of: find.text('正在准备安全连接…'),
                  matching: find.byType(Row),
                )
                .first,
          )
          .dx;
      await tester.pumpWidget(const SizedBox.shrink());
      return (
        pitch: shown.pitch,
        panel: shown.panel,
        form: shown.form,
        status: status,
      );
    }

    testWidgets('the default window splits the panel and the form 5 to 6', (
      tester,
    ) async {
      final shown = await measure(tester, const Size(1264, 871));
      expect(shown.panel.left, 0);
      expect(shown.panel.width, moreOrLessEquals(1264 * 5 / 11));
      expect(shown.pitch, XcSpace.huge);
      expect(shown.form, moreOrLessEquals((shown.panel.right + 1264) / 2));
      expect(shown.status, moreOrLessEquals(shown.form));
    });

    testWidgets(
      'a wider window centres the 1440 dp stage, colour to the edge',
      (tester) async {
        final stage = await measure(tester, const Size(1440, 900));
        for (final window in const [Size(1920, 1080), Size(2544, 1383)]) {
          final shown = await measure(tester, window);
          final shift = (window.width - 1440) / 2;
          final reason = '${window.width} dp';
          expect(shown.panel.left, 0, reason: reason);
          expect(
            shown.panel.right,
            moreOrLessEquals(stage.panel.right + shift),
            reason: reason,
          );
          expect(
            shown.pitch,
            moreOrLessEquals(stage.pitch + shift),
            reason: reason,
          );
          expect(
            shown.form,
            moreOrLessEquals(stage.form + shift),
            reason: reason,
          );
          expect(shown.status, moreOrLessEquals(shown.form), reason: reason);
        }
      },
    );
  });

  group('launch view', () {
    testWidgets('says what it is doing, then that the network is slow', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(xcApp(const XcLaunchView(displayName: _brand)));
      await xcSettle(tester);
      expect(find.text(_brand), findsOneWidget);
      expect(find.text('正在准备安全连接…'), findsOneWidget);
      expect(find.text('无需操作，准备好后会自动继续。'), findsNothing);
      await tester.pump(XcLaunchView.slowAfter);
      await xcSettle(tester);
      expect(find.text('网络较慢，仍在尝试…'), findsOneWidget);
      expect(find.text('无需操作，准备好后会自动继续。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the wait counts from when no route covers the view', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      await tester.pumpWidget(xcApp(const XcLaunchView(displayName: _brand)));
      await xcPrime(tester);
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('免责声明')),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('免责声明'), findsOneWidget);
      await tester.pump(const Duration(seconds: 9));

      navigator.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('免责声明'), findsNothing);
      expect(find.text('正在准备安全连接…'), findsOneWidget);
      expect(find.text('网络较慢，仍在尝试…'), findsNothing);
      await tester.pump(
        XcLaunchView.slowAfter - const Duration(milliseconds: 600),
      );
      await xcPrime(tester);
      expect(find.text('网络较慢，仍在尝试…'), findsNothing);
      await tester.pump(const Duration(milliseconds: 200));
      await xcSettle(tester);
      expect(find.text('正在准备安全连接…'), findsNothing);
      expect(find.text('网络较慢，仍在尝试…'), findsOneWidget);
      expect(find.text('无需操作，准备好后会自动继续。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('a wide window keeps the brand panel without its pitch', (
      tester,
    ) async {
      _size(tester, const Size(1280, 800));
      await tester.pumpWidget(xcApp(const XcLaunchView(displayName: _brand)));
      await xcSettle(tester);
      expect(find.text(_brand), findsOneWidget);
      expect(find.text('一键连接，\n安心畅游网络'), findsNothing);
      expect(find.text('正在准备安全连接…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('one state carries its clock from startup to the session', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      final startup = ValueNotifier(true);
      addTearDown(startup.dispose);
      await tester.pumpWidget(
        xcApp(
          ValueListenableBuilder(
            valueListenable: startup,
            builder: (_, starting, _) => starting
                ? XcLaunchView(key: XcLaunchView.handoff, displayName: _brand)
                : Column(
                    children: [
                      Expanded(
                        child: XcLaunchView(
                          key: XcLaunchView.handoff,
                          displayName: _brand,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      );
      await xcSettle(tester);
      final before = tester.state(find.byType(XcLaunchView));
      startup.value = false;
      await tester.pump();
      expect(tester.state(find.byType(XcLaunchView)), same(before));
      await tester.pump(XcLaunchView.slowAfter - const Duration(seconds: 2));
      await xcSettle(tester);
      expect(find.text('网络较慢，仍在尝试…'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('the auth gate shows it until the session is known', (
      tester,
    ) async {
      _size(tester, const Size(390, 844));
      final session = StreamController<XcSessionState>();
      addTearDown(session.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            xcSessionProvider.overrideWith((ref) => session.stream),
            xcApiProvider.overrideWithValue(_Api()),
          ],
          child: xcApp(const XcAuthGate(child: Text('shell'))),
        ),
      );
      await xcSettle(tester);
      expect(find.byType(XcLaunchView), findsOneWidget);
      session.add(const XcSessionState(status: XcSessionStatus.loggedOut));
      await xcSettle(tester);
      expect(find.byType(XcLaunchView), findsNothing);
      expect(find.byType(XcLoginPage), findsOneWidget);
    });
  });

  test('a brand page fills the window until the shell shows', () async {
    final session = StreamController<XcSessionState>();
    addTearDown(session.close);
    var init = false;
    final container = ProviderContainer(
      overrides: [
        initProvider.overrideWithBuild((_, _) => init),
        xcSessionProvider.overrideWith((ref) => session.stream),
      ],
    );
    addTearDown(container.dispose);
    final seen = <bool>[];
    container.listen(
      xcFullWindowPageProvider,
      (_, next) => seen.add(next),
      fireImmediately: true,
    );
    expect(seen.last, isTrue);
    init = true;
    container.invalidate(initProvider);
    await pumpEventQueue();
    expect(seen.last, isTrue);
    session.add(const XcSessionState(status: XcSessionStatus.loggedOut));
    await pumpEventQueue();
    expect(seen.last, isTrue);
    session.add(const XcSessionState(status: XcSessionStatus.loggedIn));
    await pumpEventQueue();
    expect(seen.last, isFalse);
    container.read(xcClosingProvider.notifier).set(true);
    await pumpEventQueue();
    expect(seen.last, isTrue);
  });
}
