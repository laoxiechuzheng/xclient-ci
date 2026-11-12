import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/app_host.dart';
import 'package:fl_clash/xboard/core/sync/state_poller.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File(r'C:\Windows\Fonts\msyh.ttc');
    if (Platform.isWindows && file.existsSync()) {
      await (FontLoader('XcPolicyQa')..addFont(
            Future.value(ByteData.sublistView(file.readAsBytesSync())),
          ))
          .load();
    }
  });
  testWidgets(
    'policy waiting keeps account content and exposes retry without granting connect',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var retried = 0;
      final key = GlobalKey();
      Future<void> show(PolicyCheckPhase phase) => tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            fontFamily: Platform.isWindows ? 'XcPolicyQa' : null,
          ).withAppTypography.withAppShapes,
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Column(
                children: [
                  XcPolicyAdmissionBanner(
                    state: RemoteState(phase: phase),
                    onRetry: () => retried++,
                  ),
                  const Expanded(child: Center(child: Text('账号、套餐和工单仍可使用'))),
                ],
              ),
            ),
          ),
        ),
      );
      await show(PolicyCheckPhase.error);
      expect(find.textContaining('策略核验失败'), findsOneWidget);
      await tester.tap(find.text('重试版本核验'));
      expect(retried, 1);
      await tester.pumpAndSettle();
      final path = Platform.environment['XC_POLICY_SCREENSHOT'];
      if (path != null) {
        await tester.runAsync(() async {
          final boundary =
              key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
          final rendered = await boundary.toImage(pixelRatio: 1.5);
          final bytes = await rendered.toByteData(
            format: ui.ImageByteFormat.png,
          );
          final file = File(path);
          await file.parent.create(recursive: true);
          await file.writeAsBytes(bytes!.buffer.asUint8List());
          rendered.dispose();
        });
      }
      await show(PolicyCheckPhase.checking);
      await tester.tap(find.text('重试版本核验'));
      expect(retried, 1);
      expect(find.textContaining('账号、套餐'), findsOneWidget);
    },
  );
}
