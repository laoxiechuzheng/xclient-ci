import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/ui/account/account_pages.dart';
import 'package:fl_clash/xboard/ui/common/exit_action.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Exit extends SystemAction {
  int calls = 0;
  Future<void> Function()? onRequest;
  @override
  void build() {}
  @override
  Future<void> handleExit([bool needSave = true]) async {
    calls++;
    await onRequest?.call();
  }
}

class _Api extends Fake implements XboardApi {}

ProviderContainer _container(
  _Exit action, {
  bool managed = true,
  bool running = false,
}) => ProviderContainer(
  overrides: [
    xcManagedAndroidProvider.overrideWithValue(managed),
    isStartProvider.overrideWithValue(running),
    systemActionProvider.overrideWith(() => action),
    xcBrandConfigProvider.overrideWithValue(
      const BrandConfig(brandId: 'example', displayName: 'Example 加速器'),
    ),
    xcSessionProvider.overrideWith(
      (_) =>
          Stream.value(const XcSessionState(status: XcSessionStatus.loggedOut)),
    ),
  ],
);

Widget _app(Widget child, {GlobalKey<ScaffoldMessengerState>? messenger}) =>
    MaterialApp(
      scaffoldMessengerKey: messenger,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: Platform.isWindows ? 'XcExitQa' : null,
      ).withAppTypography.withAppShapes,
      home: child,
    );

Widget _scope(ProviderContainer container, Widget child) =>
    UncontrolledProviderScope(container: container, child: _app(child));

Future<void> _save(WidgetTester tester, GlobalKey key, String name) async {
  final directory = Platform.environment['XC_EXIT_UI_SCREENSHOTS'];
  if (directory == null) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void _phone(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(320, 760);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File(r'C:\Windows\Fonts\msyh.ttc');
    if (Platform.isWindows && file.existsSync()) {
      final font = FontLoader('XcExitQa')
        ..addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
      await font.load();
    }
  });

  testWidgets('managed Android can explicitly exit before logging in', (
    tester,
  ) async {
    _phone(tester);
    final action = _Exit();
    final container = _container(action);
    addTearDown(container.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      _scope(
        container,
        RepaintBoundary(
          key: boundary,
          child: const XcAuthGate(child: Text('Authenticated content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('xc-login-submit')), findsOneWidget);
    expect(find.text('退出客户端'), findsOneWidget);
    await tester.ensureVisible(find.text('退出客户端'));
    await _save(tester, boundary, 'android-login-exit-320');
    await tester.enterText(
      find.byKey(const Key('xc-login-email')),
      'demo@example.invalid',
    );
    await tester.enterText(
      find.byKey(const Key('xc-login-password')),
      'synthetic-password',
    );
    await tester.tap(find.text('退出客户端'));
    await tester.pumpAndSettle();
    expect(action.calls, 1);
    expect(find.text('Authenticated content'), findsNothing);
    expect(container.exists(xcRuntimeProvider), isFalse);
  });

  testWidgets('running clients describe the disconnect before exit', (
    tester,
  ) async {
    final action = _Exit();
    final container = _container(action, running: true);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _scope(container, const Scaffold(body: XcExitAction())),
    );
    expect(find.text('断开并退出'), findsOneWidget);
    await tester.tap(find.text('断开并退出'));
    await tester.pumpAndSettle();
    expect(action.calls, 1);
  });

  testWidgets(
    'pending activation blocks rapid taps and resets after completion',
    (tester) async {
      final pending = Completer<void>();
      final action = _Exit()..onRequest = () => pending.future;
      final container = _container(action);
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _scope(container, const Scaffold(body: XcExitAction())),
      );
      final button = tester.widget<TextButton>(
        find.byKey(const Key('xc-client-exit')),
      );
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(action.calls, 1);
      expect(find.text('正在退出…'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('xc-client-exit')))
            .onPressed,
        isNull,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('退出客户端'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the authoritative closing flag disables the visible action', (
    tester,
  ) async {
    final action = _Exit();
    final container = _container(action);
    addTearDown(container.dispose);
    container.read(xcClosingProvider.notifier).set(true);
    await tester.pumpWidget(
      _scope(container, const Scaffold(body: XcExitAction())),
    );
    expect(find.text('正在退出…'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('xc-client-exit')))
          .onPressed,
      isNull,
    );
    expect(action.calls, 0);
  });

  testWidgets('non-managed clients do not expose an Android exit action', (
    tester,
  ) async {
    final action = _Exit();
    final container = _container(action, managed: false);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _scope(container, const XcAuthGate(child: Text('Authenticated content'))),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('xc-login-submit')), findsOneWidget);
    expect(find.byKey(const Key('xc-client-exit')), findsNothing);
    expect(action.calls, 0);
  });

  testWidgets('stop failure preserves existing feedback and allows retry', (
    tester,
  ) async {
    _phone(tester);
    final messenger = GlobalKey<ScaffoldMessengerState>();
    final boundary = GlobalKey();
    final action = _Exit()
      ..onRequest = () async {
        messenger.currentState!.showSnackBar(
          const SnackBar(content: Text('暂未确认连接已停止，后台保护仍保留。')),
        );
        throw StateError('synthetic stop failure');
      };
    final container = _container(action);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: _app(
          RepaintBoundary(
            key: boundary,
            child: XcLoginPage(
              displayName: 'Example 加速器',
              onLogin: (_, _) async => fail('Exit must not submit login'),
              footer: const XcExitAction(),
            ),
          ),
          messenger: messenger,
        ),
      ),
    );
    await tester.tap(find.text('退出客户端'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('后台保护仍保留'), findsOneWidget);
    expect(find.text('操作失败，请稍后重试'), findsNothing);
    expect(find.text('退出客户端'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _save(tester, boundary, 'android-login-exit-stop-feedback-320');
    action.onRequest = null;
    await tester.tap(find.text('退出客户端'));
    await tester.pump();
    expect(action.calls, 2);
  });

  testWidgets(
    'account settings use the same exit action separately from logout',
    (tester) async {
      _phone(tester);
      final action = _Exit();
      final container = _container(action);
      addTearDown(container.dispose);
      final boundary = GlobalKey();
      var logouts = 0;
      await tester.pumpWidget(
        _scope(
          container,
          RepaintBoundary(
            key: boundary,
            child: Scaffold(
              body: XcAccountPage(
                api: _Api(),
                user: const {},
                panelWebUrl: 'https://example.invalid',
                onLogout: () async => logouts++,
                onSync: () async {},
                onRefreshUser: () async {},
                onRegisterDevice: () async {},
                settingsTiles: const [XcExitAction()],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(ListView), findsOneWidget);
      final accountScroll = find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        find.text('退出客户端'),
        300,
        scrollable: accountScroll,
      );
      await tester.pumpAndSettle();
      expect(find.text('客户端设置'), findsOneWidget);
      await _save(tester, boundary, 'android-settings-exit-320');
      await tester.tap(find.text('退出客户端'));
      await tester.pumpAndSettle();
      expect(action.calls, 1);
      expect(logouts, 0);
    },
  );

  testWidgets('disposing a pending action does not schedule another exit', (
    tester,
  ) async {
    final pending = Completer<void>();
    final action = _Exit()..onRequest = () => pending.future;
    final container = _container(action);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _scope(container, const Scaffold(body: XcExitAction())),
    );
    await tester.tap(find.text('退出客户端'));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pump();
    expect(action.calls, 1);
    expect(tester.takeException(), isNull);
  });
}
