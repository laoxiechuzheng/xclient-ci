import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/xboard/app_host.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:fl_clash/xboard/update/update_widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _NoticeManager extends Fake implements XcUpdateManager {
  final controller = StreamController<XcUpdateState>.broadcast();
  var shown = 0;
  @override
  XcUpdateState state = const XcUpdateState(
    noticeDue: true,
    decision: UpdateDecision(mode: UpdateMode.notify, latest: '2.0.0'),
  );
  @override
  Stream<XcUpdateState> get changes => controller.stream;
  @override
  Future<void> noticeShown() async {
    shown++;
    state = state.copyWith(noticeDue: false);
    controller.add(state);
  }
}

Future<void> _font(WidgetTester tester) async {
  final file = File(r'C:\Windows\Fonts\msyh.ttc');
  if (file.existsSync()) {
    final loader = FontLoader('LifecyclePreview');
    loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    await tester.runAsync(loader.load);
  }
}

Future<void> _capture(WidgetTester tester, GlobalKey key, String name) async {
  final boundary =
      key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final output = File('docs/handoff/$name-20261104.png');
    await output.parent.create(recursive: true);
    await output.writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  testWidgets(
    'a hidden ordinary notice is marked only after a visible dialog opens',
    (tester) async {
      final manager = _NoticeManager();
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(false),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          xcUpdateManagerProvider.overrideWithValue(manager),
          xcCurrentVersionProvider.overrideWithValue('1.0.0'),
        ],
      );
      addTearDown(() {
        container.dispose();
        unawaited(manager.controller.close());
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: ThemeData().withAppShapes,
            home: const XcUpdateHost(child: Scaffold(body: Text('Account'))),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(XcUpdateDialog), findsNothing);
      expect(manager.shown, 0);
      container.read(appVisibleProvider.notifier).value = true;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(XcUpdateDialog), findsOneWidget);
      expect(manager.shown, 1);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      expect(manager.shown, 1);
    },
  );

  testWidgets(
    'closing and install-permission feedback render without overflow',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 740));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _font(tester);
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: const Color(0xff4169e1),
            fontFamily: 'LifecyclePreview',
          ).withAppShapes,
          home: RepaintBoundary(
            key: key,
            child: const Scaffold(body: XcClosingPanel()),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('正在断开连接并退出'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, key, 'android-managed-closing');
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            brightness: Brightness.dark,
            colorSchemeSeed: const Color(0xff4169e1),
            fontFamily: 'LifecyclePreview',
          ).withAppShapes,
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Center(
                child: XcUpdatePanel(
                  state: const XcUpdateState(
                    phase: XcUpdatePhase.needsPermission,
                    decision: UpdateDecision(
                      mode: UpdateMode.force,
                      latest: '2.0.0',
                    ),
                  ),
                  currentVersion: '1.0.0',
                  onClose: () {},
                  onPermission: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('允许安装'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _capture(tester, key, 'android-hidden-update-permission');
      var retries = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'LifecyclePreview').withAppShapes,
          home: RepaintBoundary(
            key: key,
            child: Scaffold(body: XcClosingPanel(onRetry: () => retries++)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _capture(tester, key, 'android-managed-exit-retry');
      await tester.tap(find.text('重试退出'));
      await tester.pumpAndSettle();
      expect(retries, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
