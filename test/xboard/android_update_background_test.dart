import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:fl_clash/xboard/lifecycle.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:fl_clash/xboard/update/version.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'update/update_test.dart' as fixture;

class _Runtime extends Fake implements XClientRuntime {
  @override
  void setForeground(bool foreground) {}
}

class _Probe extends Fake implements XcProbeRuntime {}

class _NeedsPermission extends fixture.FakeInstaller {
  @override
  Future<bool> canInstall() async => false;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'NoView forced update verifies release and package before permission notification',
    () async {
      final signed = await fixture.signedRelease();
      final workRoot = await Directory(
        '.dart_tool/xclient-engine-owner',
      ).create(recursive: true);
      final dir = await workRoot.createTemp('update-');
      addTearDown(() => dir.delete(recursive: true));
      final installer = _NeedsPermission();
      final http = fixture.FakeHttp(
        (uri) async => fixture.bytesResponse(
          uri.path.endsWith('.json')
              ? utf8.encode(jsonEncode(signed.doc))
              : [1, 2, 3],
        ),
      );
      final manager = XcUpdateManager(
        brand: BrandConfig(
          brandId: 'example',
          displayName: 'Example',
          relPubKeys: {
            for (final kid in signed.keys.kids)
              kid: b64uEncode(signed.keys[kid]!),
          },
        ),
        current: const AppVersion(1, 0, 0),
        platform: XcPlatform.android,
        arch: 'arm64-v8a',
        http: http,
        installer: installer,
        throttle: UpdateNoticeThrottle(MemoryUpdateNoticeStore()),
        workDir: () async => dir,
      );
      addTearDown(manager.dispose);
      final actions = <String>[];
      const nativeApp = MethodChannel('com.follow.clash/app');
      const nativeUpdate = MethodChannel('xclient/update');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(nativeApp, (_) async => false);
      messenger.setMockMethodCallHandler(nativeUpdate, (call) async {
        if (call.method == 'notifyUpdateAction') {
          actions.add((call.arguments as Map)['kind'] as String);
        }
        return true;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(nativeApp, null);
        messenger.setMockMethodCallHandler(nativeUpdate, null);
      });
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(true),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          isStartProvider.overrideWithValue(false),
          xcConnectionMustStopProvider.overrideWithValue(false),
          xcRuntimeProvider.overrideWith((_) async => _Runtime()),
          xcProbeRuntimeProvider.overrideWithValue(_Probe()),
          xcUpdateManagerProvider.overrideWithValue(manager),
        ],
      );
      addTearDown(container.dispose);
      mountXcLifecycle(container);
      await Future<void>.delayed(Duration.zero);
      await manager.onPolicy(fixture.policy(force: true));
      await manager.start();
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(manager.state.phase, XcUpdatePhase.needsPermission);
      expect(manager.state.isForced, isTrue);
      expect(manager.state.manifest, isNotNull);
      expect(manager.state.received, 3);
      expect(http.requests.map((uri) => uri.path), [
        '/manifest.json',
        '/app.apk',
      ]);
      expect(installer.installs, 0);
      expect(actions, contains('permission'));
      expect(container.read(appVisibleProvider), isFalse);
      final files = await dir
          .list()
          .where((entry) => entry is File)
          .cast<File>()
          .toList();
      expect(files, hasLength(1));
      expect(await files.single.readAsBytes(), [1, 2, 3]);
    },
  );
}
