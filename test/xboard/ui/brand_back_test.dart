import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart' as app;
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/pop_scope.dart';
import 'package:fl_clash/xboard/app_host.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/ui/login.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Api extends Fake implements XboardApi {
  @override
  Future<Map<String, dynamic>> commConfig() async => {};
}

class _ConfigErrorApi extends _Api {
  @override
  Future<Map<String, dynamic>> commConfig() async =>
      throw StateError('synthetic config error');
}

class _Actions extends Fake implements XcActions {
  @override
  Future<void> login(String email, String password) async =>
      throw const XbApiException(XbErrorKind.rateLimited);
}

class _CloseAction extends app.SystemAction {
  final calls = <String>[];
  Completer<void>? saving;
  @override
  Future<void> savePreferences() async {
    calls.add('save');
    await saving?.future;
  }

  @override
  Future<void> cleanupExitResources(bool needSave) async =>
      calls.add('cleanup');
  @override
  Future<void> closeWindow() async => calls.add('window');
  @override
  Future<void> closeCore() async => calls.add('core');
  @override
  Future<void> exitApplication() async => calls.add('exit');
}

class _Window extends Fake implements WindowPort {
  final List<String> calls;
  _Window(this.calls);
  @override
  Future<void> hide() async => calls.add('hide');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var qaFont = false;
  setUpAll(() async {
    final font = File(r'C:\Windows\Fonts\msyh.ttc');
    if (Platform.environment['XC_BACK_SCREENSHOT'] != null &&
        Platform.isWindows &&
        font.existsSync()) {
      await (FontLoader('XcBackQa')..addFont(
            Future.value(ByteData.sublistView(font.readAsBytesSync())),
          ))
          .load();
      qaFont = true;
    }
  });
  late _CloseAction action;
  late List<String> platformPops;
  late WindowPort? previousWindow;
  setUp(() {
    action = _CloseAction();
    platformPops = [];
    previousWindow = windowPort;
    windowPort = _Window(action.calls);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') {
            platformPops.add(call.method);
          }
          return null;
        });
  });
  tearDown(() {
    windowPort = previousWindow;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> mount(
    WidgetTester tester, {
    bool minimize = true,
    Stream<XcSessionState>? session,
    bool startup = false,
    bool failed = false,
    bool waiting = false,
    XboardApi? api,
    GlobalKey? captureKey,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          app.systemActionProvider.overrideWith(() => action),
          app.appSettingProvider.overrideWithBuild(
            (_, _) => AppSettingProps(minimizeOnExit: minimize),
          ),
          app.initProvider.overrideWithBuild((_, _) => !startup),
          xcApiProvider.overrideWithValue(api ?? _Api()),
          xcActionsProvider.overrideWithValue(_Actions()),
          xcSessionProvider.overrideWith(
            (_) =>
                session ??
                Stream.value(
                  const XcSessionState(status: XcSessionStatus.loggedIn),
                ),
          ),
        ],
        child: MaterialApp(
          theme: ThemeData(
            fontFamily: qaFont ? 'XcBackQa' : null,
          ).withAppTypography.withAppShapes,
          home: RepaintBoundary(
            key: captureKey,
            child: startup
                ? XcAppHost(startupFailed: failed)
                : const XcAuthGate(child: _AccountRoot()),
          ),
        ),
      ),
    );
    if ((startup && !failed) || waiting) {
      await tester.pump();
    } else {
      await tester.pumpAndSettle();
    }
  }

  Future<void> back(WidgetTester tester, {bool settle = true}) async {
    await tester.binding.handlePopRoute();
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
    }
  }

  testWidgets(
    'branded account root back minimizes once without finishing the engine',
    (tester) async {
      await mount(tester);
      await back(tester);
      expect(action.calls, ['save', 'hide']);
      expect(platformPops, isEmpty);
    },
  );
  testWidgets(
    'root back with minimize disabled closes Core before application exit',
    (tester) async {
      await mount(tester, minimize: false);
      await back(tester);
      expect(action.calls, ['cleanup', 'window', 'core', 'exit']);
      expect(platformPops, isEmpty);
    },
  );
  testWidgets('one account child back never also closes the root', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Open account'));
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('Account child'), findsNothing);
    expect(find.text('Open account'), findsOneWidget);
    expect(action.calls, isEmpty);
    expect(platformPops, isEmpty);
    await back(tester);
    expect(action.calls, ['save', 'hide']);
  });
  for (final rootDialog in [false, true]) {
    testWidgets(
      'dialog root=$rootDialog pops one layer before account and root',
      (tester) async {
        await mount(tester);
        await tester.tap(find.text('Open account'));
        await tester.pumpAndSettle();
        await tester.tap(
          find.text(rootDialog ? 'Root dialog' : 'Inner dialog'),
        );
        await tester.pumpAndSettle();
        await back(tester);
        expect(find.text('Pending dialog'), findsNothing);
        expect(find.text('Account child'), findsOneWidget);
        expect(action.calls, isEmpty);
        expect(platformPops, isEmpty);
        await back(tester);
        expect(find.text('Account child'), findsNothing);
        expect(action.calls, isEmpty);
        await back(tester);
        expect(action.calls, ['save', 'hide']);
      },
    );
  }
  testWidgets('inner local back layer consumes once without root close', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.text('Open account'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open layer'));
    await tester.pumpAndSettle();
    expect(find.text('Inner layer'), findsOneWidget);
    await back(tester);
    expect(find.text('Inner layer'), findsNothing);
    expect(find.text('Account child'), findsOneWidget);
    expect(action.calls, isEmpty);
    expect(platformPops, isEmpty);
  });
  for (final state in [
    const XcSessionState(status: XcSessionStatus.loggedOut),
    const XcSessionState(
      status: XcSessionStatus.error,
      message: 'Login failed',
    ),
  ]) {
    testWidgets('login root status=${state.status.name} follows close policy', (
      tester,
    ) async {
      await mount(tester, session: Stream.value(state));
      await back(tester);
      expect(action.calls, ['save', 'hide']);
      expect(platformPops, isEmpty);
    });
  }
  testWidgets('session initialization error root uses close policy', (
    tester,
  ) async {
    await mount(
      tester,
      session: Stream.error(StateError('synthetic startup error')),
    );
    await back(tester);
    expect(action.calls, ['save', 'hide']);
    expect(platformPops, isEmpty);
  });
  testWidgets('session loading root also minimizes without a native pop', (
    tester,
  ) async {
    final pending = StreamController<XcSessionState>();
    addTearDown(pending.close);
    await mount(tester, session: pending.stream, waiting: true);
    await back(tester, settle: false);
    expect(action.calls, ['save', 'hide']);
    expect(platformPops, isEmpty);
  });
  testWidgets('commerce initialization error retains the root close policy', (
    tester,
  ) async {
    await mount(tester, api: _ConfigErrorApi());
    await back(tester);
    expect(action.calls, ['save', 'hide']);
    expect(platformPops, isEmpty);
  });
  testWidgets(
    'pending root close consumes repeated back without duplicate close',
    (tester) async {
      action.saving = Completer<void>();
      await mount(tester);
      await back(tester);
      await back(tester);
      expect(action.calls, ['save']);
      action.saving!.complete();
      await tester.pumpAndSettle();
      expect(action.calls, ['save', 'hide']);
      expect(platformPops, isEmpty);
    },
  );
  for (final failed in [false, true]) {
    testWidgets(
      'native startup failed=$failed root never falls through to SystemNavigator',
      (tester) async {
        await mount(tester, startup: true, failed: failed);
        await back(tester, settle: failed);
        expect(action.calls, ['save', 'hide']);
        expect(platformPops, isEmpty);
      },
    );
  }
  testWidgets('a rejected login still keeps the root back policy', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await mount(
      tester,
      captureKey: boundary,
      session: Stream.value(
        const XcSessionState(status: XcSessionStatus.loggedOut),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('xc-login-email')),
      'qa@example.invalid',
    );
    await tester.enterText(
      find.byKey(const Key('xc-login-password')),
      'synthetic-only-password',
    );
    await tester.tap(find.byKey(const Key('xc-login-submit')));
    await tester.pumpAndSettle();
    await back(tester);
    expect(action.calls, ['save', 'hide']);
    expect(platformPops, isEmpty);
    expect(find.byKey(const Key('xc-login-submit')), findsOneWidget);
    final output = Platform.environment['XC_BACK_SCREENSHOT'];
    if (output != null) {
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final frame = await render.toImage(pixelRatio: 1.5);
        final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
        await File(output).writeAsBytes(bytes!.buffer.asUint8List());
        frame.dispose();
      });
    }
  });
}

class _AccountRoot extends StatelessWidget {
  const _AccountRoot();
  @override
  Widget build(BuildContext context) => Scaffold(
    body: Center(
      child: TextButton(
        onPressed: () => Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => const _AccountChild())),
        child: const Text('Open account'),
      ),
    ),
  );
}

class _AccountChild extends StatefulWidget {
  const _AccountChild();
  @override
  State<_AccountChild> createState() => _AccountChildState();
}

class _AccountChildState extends State<_AccountChild> {
  bool layer = false;
  @override
  Widget build(BuildContext context) {
    Widget page = Scaffold(
      body: Column(
        children: [
          const Text('Account child'),
          for (final root in [false, true])
            TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                useRootNavigator: root,
                builder: (_) =>
                    const AlertDialog(title: Text('Pending dialog')),
              ),
              child: Text(root ? 'Root dialog' : 'Inner dialog'),
            ),
          TextButton(
            onPressed: () => setState(() => layer = true),
            child: const Text('Open layer'),
          ),
          if (layer) const Text('Inner layer'),
        ],
      ),
    );
    if (layer) {
      page = BackLayerScope(
        onBack: () => setState(() => layer = false),
        child: page,
      );
    }
    return page;
  }
}
