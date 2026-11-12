import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/lifecycle.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

final _running = NotifierProvider<_Flag, bool>(_Flag.new);
final _mustStop = NotifierProvider<_Flag, bool>(_Flag.new);

class _Flag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

class _Runtime extends Fake implements XClientRuntime {
  final control = <bool>[];
  @override
  void setForeground(bool foreground) => control.add(foreground);
}

class _Probe extends Fake implements XcProbeRuntime {}

class _Setup extends SetupAction {
  final stops = <bool>[];
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    stops.add(running);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a pending real runtime Future cannot construct resources after terminal shutdown',
    () async {
      PackageInfo.setMockInitialValues(
        appName: 'Example',
        packageName: 'example.invalid',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      final workRoot = await Directory(
        '.dart_tool/xclient-engine-owner',
      ).create(recursive: true);
      final directory = await workRoot.createTemp('pending-runtime-');
      addTearDown(() => directory.delete(recursive: true));
      final gate = Completer<Directory>();
      AppPath.supportDirectory = () => gate.future;
      AppPath.temporaryDirectory = () async => directory;
      AppPath.cacheDirectory = () async => directory;
      AppPath.downloadDirectory = () async => directory;
      final rebinding = appPath.rebind();
      var connectors = 0;
      final container = ProviderContainer(
        overrides: [
          xcBrandConfigProvider.overrideWithValue(
            const BrandConfig(brandId: 'example', displayName: 'Example'),
          ),
          xcDirectConnectorProvider.overrideWith((_) {
            connectors++;
            return null;
          }),
        ],
      );
      addTearDown(container.dispose);
      final runtime = container.read(xcRuntimeProvider.future);
      final rejected = expectLater(runtime, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      container.read(xcRuntimeShutdownProvider).close();
      gate.complete(directory);
      await rebinding;
      await rejected;
      expect(connectors, 0);
      expect(container.exists(xcDirectConnectorProvider), isFalse);
    },
  );

  test(
    'NoView permission notification and update request survive without a frame',
    () async {
      const appChannel = MethodChannel('com.follow.clash/app');
      const updateChannel = MethodChannel('xclient/update');
      final notifications = <String>[];
      var queuedRequest = true;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(appChannel, (call) async {
        if (call.method == 'hasActivity') return false;
        if (call.method == 'consumeUpdateRequest') {
          final pending = queuedRequest;
          queuedRequest = false;
          return pending;
        }
        return null;
      });
      messenger.setMockMethodCallHandler(updateChannel, (call) async {
        notifications.add(
          call.method == 'notifyUpdateAction'
              ? (call.arguments as Map)['kind'] as String
              : call.method,
        );
        return false;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(appChannel, null);
        messenger.setMockMethodCallHandler(updateChannel, null);
      });
      final states = StreamController<XcUpdateState>();
      addTearDown(states.close);
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(true),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          isStartProvider.overrideWithValue(false),
          xcConnectionMustStopProvider.overrideWithValue(false),
          xcRuntimeProvider.overrideWith((_) async => _Runtime()),
          xcProbeRuntimeProvider.overrideWithValue(_Probe()),
          xcUpdateManagerProvider.overrideWithValue(null),
          xcUpdateStateProvider.overrideWith((_) => states.stream),
        ],
      );
      addTearDown(container.dispose);
      final anchor = mountXcLifecycle(container);
      addTearDown(anchor.close);
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(xcUpdateOpenRequestedProvider), isTrue);
      const decision = UpdateDecision(mode: UpdateMode.force, latest: '2.0.0');
      states.add(
        const XcUpdateState(
          phase: XcUpdatePhase.downloading,
          decision: decision,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      states.add(
        const XcUpdateState(
          phase: XcUpdatePhase.downloading,
          decision: decision,
          received: 9,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(notifications, ['required']);
      states.add(
        const XcUpdateState(
          phase: XcUpdatePhase.needsPermission,
          decision: decision,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, ['required', 'permission']);
      states.add(
        const XcUpdateState(
          phase: XcUpdatePhase.awaitingUser,
          decision: decision,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, ['required', 'permission', 'clearUpdateAction']);
      expect(container.read(appVisibleProvider), isFalse);
      expect(container.read(xcUpdateOpenRequestedProvider), isTrue);
    },
  );
  test(
    'terminal shutdown owns pending runtime candidates and cannot revive them',
    () {
      final shutdown = XcRuntimeShutdown();
      var disposed = 0;
      final untrack = shutdown.track(() => disposed++);
      shutdown.close();
      shutdown.close();
      expect(disposed, 1);
      untrack();
      shutdown.track(() => disposed++);
      expect(disposed, 2);
      expect(shutdown.isClosed, isTrue);
    },
  );
  for (final managed in [false, true]) {
    for (final visible in [false, true]) {
      for (final running in [false, true]) {
        test(
          'control activity managed=$managed visible=$visible run=$running',
          () {
            final container = ProviderContainer(
              overrides: [
                xcManagedAndroidProvider.overrideWithValue(managed),
                appVisibleProvider.overrideWithBuild((_, _) => visible),
                isStartProvider.overrideWithValue(running),
              ],
            );
            addTearDown(container.dispose);
            expect(container.read(appVisibleProvider), visible);
            expect(
              container.read(xcControlActiveProvider),
              visible || (managed && running),
            );
          },
        );
      }
    }
  }

  test(
    'NoView binding keeps active control and applies initial hard stop',
    () async {
      final runtime = _Runtime();
      final setup = _Setup();
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(true),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          isStartProvider.overrideWith((ref) => ref.watch(_running)),
          xcConnectionMustStopProvider.overrideWith(
            (ref) => ref.watch(_mustStop),
          ),
          xcRuntimeProvider.overrideWith((_) async => runtime),
          xcProbeRuntimeProvider.overrideWithValue(_Probe()),
          xcUpdateManagerProvider.overrideWithValue(null),
          setupActionProvider.overrideWith(() => setup),
        ],
      );
      addTearDown(container.dispose);
      container.read(_running.notifier).set(true);
      container.read(_mustStop.notifier).set(true);
      await container.read(xcRuntimeProvider.future);
      final subscription = mountXcLifecycle(container);
      addTearDown(subscription.close);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(appVisibleProvider), isFalse);
      expect(runtime.control, [true]);
      expect(setup.stops, [false]);
      container.read(appVisibleProvider.notifier).value = true;
      container.read(appVisibleProvider.notifier).value = false;
      await Future<void>.delayed(Duration.zero);
      expect(runtime.control, [true]);
      container.read(_running.notifier).set(false);
      await Future<void>.delayed(Duration.zero);
      expect(runtime.control, [true, false]);
      expect(setup.stops, [false]);
    },
  );

  test(
    'NoView hard admission arriving after startup stops the current run',
    () async {
      final setup = _Setup();
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(true),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          isStartProvider.overrideWith((ref) => ref.watch(_running)),
          xcConnectionMustStopProvider.overrideWith(
            (ref) => ref.watch(_mustStop),
          ),
          xcRuntimeProvider.overrideWith((_) async => _Runtime()),
          xcProbeRuntimeProvider.overrideWithValue(_Probe()),
          xcUpdateManagerProvider.overrideWithValue(null),
          setupActionProvider.overrideWith(() => setup),
        ],
      );
      addTearDown(container.dispose);
      container.read(_running.notifier).set(true);
      final subscription = mountXcLifecycle(container);
      addTearDown(subscription.close);
      await container.read(xcRuntimeProvider.future);
      container.read(_mustStop.notifier).set(true);
      await Future<void>.delayed(Duration.zero);
      expect(setup.stops, [false]);
      expect(container.read(appVisibleProvider), isFalse);
    },
  );
}
