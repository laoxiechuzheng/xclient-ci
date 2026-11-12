import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/update_widgets.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'forced update progress keeps background account access available',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(460, 780));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fontFile = File(r'C:\Windows\Fonts\msyh.ttc');
      if (fontFile.existsSync()) {
        final loader = FontLoader('UpdatePreview');
        loader.addFont(
          Future.value(ByteData.sublistView(fontFile.readAsBytesSync())),
        );
        await tester.runAsync(loader.load);
      }
      var closed = false;
      final key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            colorSchemeSeed: const Color(0xff4169e1),
            fontFamily: 'UpdatePreview',
          ).withAppShapes,
          home: RepaintBoundary(
            key: key,
            child: Scaffold(
              body: Center(
                child: XcUpdatePanel(
                  state: const XcUpdateState(
                    phase: XcUpdatePhase.downloading,
                    decision: UpdateDecision(
                      mode: UpdateMode.force,
                      latest: '1.2.0',
                      notes: '改善连接稳定性与账号体验。',
                    ),
                    received: 50 * 1048576,
                    total: 100 * 1048576,
                  ),
                  currentVersion: '1.0.0',
                  onClose: () => closed = true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('需要更新客户端'), findsOneWidget);
      expect(find.text('后台更新'), findsOneWidget);
      expect(find.text('50.0 / 100.0 MB'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final boundary =
          key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final output = File('docs/handoff/update-progress-20261104.png');
        await output.parent.create(recursive: true);
        await output.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
      await tester.tap(find.text('后台更新'));
      expect(closed, isTrue);
    },
  );
}
