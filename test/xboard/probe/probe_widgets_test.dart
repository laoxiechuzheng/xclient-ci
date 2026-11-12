import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/ui/ui.dart';
import 'package:fl_clash/views/proxies/card.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/probe/display_delay.dart';
import 'package:fl_clash/xboard/probe/settings_tile.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_app.dart';
import '../../helpers/test_profiles.dart';

const _url = 'https://test.example/generate_204';
const _render = bool.fromEnvironment('XC_RENDER_PREVIEW');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final width in [400.0, 1000.0]) {
    testWidgets(
      'real proxy cards show bounded delay and red failure at $width dp',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (_render) {
          final font = File(r'C:\Windows\Fonts\msyh.ttc');
          if (font.existsSync()) {
            await tester.runAsync(() async {
              final bytes = await font.readAsBytes();
              final loader = FontLoader('PreviewCJK')
                ..addFont(Future.value(ByteData.sublistView(bytes)));
              await loader.load();
            });
          }
        }
        final container = ProviderContainer(
          overrides: [
            profilesProvider.overrideWith(TestProfiles.new),
            delayDataSourceProvider.overrideWithBuild(
              (_, _) => {
                _url: {
                  'JP Tokyo 01': 200,
                  'JP Osaka 02': 65535,
                  'JP Tokyo 03': -1,
                },
              },
            ),
          ],
        );
        addTearDown(container.dispose);
        globalState.container = container;
        container.read(viewSizeProvider.notifier).value = Size(width, 640);
        final key = GlobalKey();
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: TestApp(
              theme: ThemeData(
                fontFamily: _render ? 'PreviewCJK' : null,
              ).withAppShapes,
              locale: const Locale('zh', 'CN'),
              homeBuilder: (child) => Scaffold(body: child),
              child: RepaintBoundary(
                key: key,
                child: Material(
                  color: const Color(0xfffaf8ff),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text('节点连通状态'),
                        for (final name in [
                          'JP Tokyo 01',
                          'JP Osaka 02',
                          'JP Tokyo 03',
                        ])
                          SizedBox(
                            height: 112,
                            child: ProxyCard(
                              groupName: 'Proxy',
                              testUrl: _url,
                              proxy: Proxy(name: name, type: 'Shadowsocks'),
                              groupType: GroupType.Selector,
                              type: ProxyCardType.standard,
                            ),
                          ),
                        const XcProbeSettingsTile(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.text(
            BrandConfig.isBranded ? '${displayDelay(200)} ms' : '200 ms',
          ),
          findsOneWidget,
        );
        expect(
          find.text(BrandConfig.isBranded ? '109 ms' : '65535 ms'),
          findsOneWidget,
        );
        if (BrandConfig.isBranded) {
          final timeout = tester.widget<Text>(find.text(xcDelayTimeoutText));
          final context = tester.element(find.text(xcDelayTimeoutText));
          expect(timeout.style?.color, Theme.of(context).colorScheme.error);
        }
        expect(tester.takeException(), isNull);
        if (_render) {
          await tester.runAsync(() async {
            final boundary =
                key.currentContext!.findRenderObject()!
                    as RenderRepaintBoundary;
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File(
              'docs/handoff/probe-preview-${width.toInt()}-20261104.png',
            );
            await file.writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
