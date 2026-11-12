import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/app_host.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final file = File(r'C:\Windows\Fonts\msyh.ttc');
    if (Platform.isWindows && file.existsSync()) {
      await (FontLoader('XcStartupQa')..addFont(
            Future.value(ByteData.sublistView(file.readAsBytesSync())),
          ))
          .load();
    }
  });
  testWidgets(
    'failed native startup offers a retry while connection stays gated',
    (tester) async {
      var retries = 0;
      final boundaryKey = GlobalKey();
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [initProvider.overrideWithBuild((_, _) => false)],
          child: MaterialApp(
            theme: ThemeData(
              fontFamily: Platform.isWindows ? 'XcStartupQa' : null,
            ).withAppTypography.withAppShapes,
            home: RepaintBoundary(
              key: boundaryKey,
              child: XcAppHost(startupFailed: true, onRetry: () => retries++),
            ),
          ),
        ),
      );
      expect(find.byType(CommonCircleLoading), findsNothing);
      expect(find.text('客户端初始化未完成'), findsOneWidget);
      expect(find.textContaining('系统设置'), findsOneWidget);
      final path = Platform.environment['XC_STARTUP_SCREENSHOT'];
      if (path != null) {
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
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
      await tester.tap(find.text('重新初始化'));
      expect(retries, 1);
    },
  );
}
