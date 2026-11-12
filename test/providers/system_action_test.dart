import 'dart:async';

import 'package:fl_clash/common/app_ports.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/common/preferences.dart';
import 'package:fl_clash/models/config.dart';
import 'package:fl_clash/providers/actions/system_exit.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/lifecycle.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

import '../helpers/preferences.dart';

class TestSystemAction extends SystemAction {
  final List<String> calls = [];
  final List<bool> cleanupNeedSave = [];
  Completer<void>? closeCoreGate;
  Object? cleanupError;
  Duration watchdog = const Duration(hours: 1);

  @override
  Duration get exitWatchdogDuration => watchdog;

  @override
  Future<void> cleanupExitResources(bool needSave) async {
    calls.add('cleanup');
    cleanupNeedSave.add(needSave);
    final error = cleanupError;
    if (error != null) {
      Error.throwWithStackTrace(error, StackTrace.current);
    }
  }

  @override
  Future<void> closeWindow() async => calls.add('window');

  @override
  Future<void> closeCore() async {
    calls.add('core');
    final gate = closeCoreGate;
    if (gate != null) {
      await gate.future;
    }
  }

  @override
  Future<void> exitApplication() async => calls.add('exit');
}

class _PersistenceSystemAction extends SystemAction {
  Future<void> persist() => savePreferences();
}

class _ControlRuntime extends Fake implements XClientRuntime {
  final control = <bool>[];
  @override
  void setForeground(bool foreground) => control.add(foreground);
}

class _ControlProbe extends Fake implements XcProbeRuntime {
  @override
  void dispose() {}
}

class _GeometryWindowPort implements WindowPort {
  final WindowProps geometry;
  final Error? error;

  _GeometryWindowPort(this.geometry, {this.error});

  @override
  Future<WindowProps?> captureNormalGeometry(WindowProps current) async {
    final failure = error;
    if (failure != null) {
      throw failure;
    }
    return geometry;
  }

  @override
  Future<double?> setBlur({
    required bool enabled,
    required Brightness brightness,
    required Color tint,
  }) async => null;

  @override
  Future<void> close() async {}

  @override
  void forceExit() {}

  @override
  Future<void> hide() async {}

  @override
  Future<void> toggle() async {}

  @override
  Future<void> show() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unconfirmed managed stop preserves real isStart and hidden control until retry',
    () async {
      const appChannel = MethodChannel('$packageName/app');
      const serviceChannel = MethodChannel('$packageName/service');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var confirmed = false;
      messenger.setMockMethodCallHandler(
        appChannel,
        (call) async => switch (call.method) {
          'beginManagedExit' => 3,
          'completeManagedExit' => true,
          'abortManagedExit' => false,
          _ => false,
        },
      );
      messenger.setMockMethodCallHandler(
        serviceChannel,
        (_) async => confirmed,
      );
      addTearDown(() {
        messenger.setMockMethodCallHandler(appChannel, null);
        messenger.setMockMethodCallHandler(serviceChannel, null);
      });
      final runtime = _ControlRuntime();
      final action = TestSystemAction();
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(true),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          runTimeProvider.overrideWithBuild(
            (_, _) => DateTime.utc(2026).millisecondsSinceEpoch,
          ),
          xcConnectionMustStopProvider.overrideWithValue(false),
          xcRuntimeProvider.overrideWith((_) async => runtime),
          xcProbeRuntimeProvider.overrideWithValue(_ControlProbe()),
          xcUpdateManagerProvider.overrideWithValue(null),
          systemActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      mountXcLifecycle(container);
      await container.read(xcRuntimeProvider.future);
      await expectLater(
        container.read(systemActionProvider.notifier).handleExit(),
        throwsStateError,
      );
      expect(action.calls, isEmpty);
      expect(container.read(isStartProvider), isTrue);
      expect(container.read(appVisibleProvider), isFalse);
      expect(container.read(xcControlActiveProvider), isTrue);
      expect(runtime.control, [true]);
      expect(container.read(xcClosingProvider), isTrue);
      expect(container.read(xcExitRetryProvider), isTrue);
      confirmed = true;
      await container.read(systemActionProvider.notifier).handleExit();
      expect(action.calls, ['cleanup', 'core']);
    },
  );

  test(
    'managed Android exit bypasses desktop watchdog and does not create a runtime',
    () async {
      final native = <String>[];
      final gate = Completer<bool>();
      const appChannel = MethodChannel('$packageName/app');
      const serviceChannel = MethodChannel('$packageName/service');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(appChannel, (call) async {
        native.add(call.method);
        return call.method == 'beginManagedExit' ? 3 : true;
      });
      messenger.setMockMethodCallHandler(serviceChannel, (call) async {
        native.add(call.method);
        return gate.future;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(appChannel, null);
        messenger.setMockMethodCallHandler(serviceChannel, null);
      });
      final action = TestSystemAction()
        ..watchdog = const Duration(milliseconds: 1);
      final container = ProviderContainer(
        overrides: [
          xcManagedAndroidProvider.overrideWithValue(true),
          systemActionProvider.overrideWith(() => action),
        ],
      );
      addTearDown(container.dispose);
      final closing = container
          .read(systemActionProvider.notifier)
          .handleExit(false);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(action.calls, isEmpty);
      expect(native, ['beginManagedExit', 'stopForExit']);
      expect(container.exists(xcRuntimeProvider), isFalse);
      gate.complete(true);
      await closing;
      expect(action.calls, ['cleanup', 'core']);
      expect(action.cleanupNeedSave, [false]);
      expect(native, [
        'beginManagedExit',
        'stopForExit',
        'completeManagedExit',
      ]);
      expect(container.exists(xcRuntimeProvider), isFalse);
      expect(container.read(xcClosingProvider), isTrue);
    },
  );

  test('coalesces repeated exit requests and runs cleanup once', () async {
    final closeCoreCompleter = Completer<void>();
    final calls = <String>[];
    final coordinator = SystemExitCoordinator(
      watchdogDuration: const Duration(hours: 1),
      closeWindow: () async => calls.add('window'),
      closeCore: () async {
        calls.add('core');
        await closeCoreCompleter.future;
      },
      exitApplication: () async => calls.add('exit'),
    );

    final first = coordinator.exit(cleanup: () async => calls.add('cleanup'));
    final second = coordinator.exit(
      cleanup: () async => calls.add('unexpected cleanup'),
    );
    await Future<void>.delayed(Duration.zero);

    expect(identical(first, second), isTrue);
    expect(calls, ['cleanup', 'window', 'core']);

    closeCoreCompleter.complete();
    await Future.wait([first, second]);

    expect(calls, ['cleanup', 'window', 'core', 'exit']);
  });

  test('watchdog and normal completion share one application exit', () async {
    final closeCoreCompleter = Completer<void>();
    var exitCount = 0;
    final coordinator = SystemExitCoordinator(
      watchdogDuration: const Duration(milliseconds: 1),
      closeWindow: () async {},
      closeCore: () => closeCoreCompleter.future,
      exitApplication: () async => exitCount++,
    );

    final operation = coordinator.exit(cleanup: () async {});
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(exitCount, 1);
    closeCoreCompleter.complete();
    await operation;
    expect(exitCount, 1);
  });

  test('cleanup failure does not skip window or Core shutdown', () async {
    final calls = <String>[];
    final coordinator = SystemExitCoordinator(
      watchdogDuration: const Duration(hours: 1),
      closeWindow: () async => calls.add('window'),
      closeCore: () async => calls.add('core'),
      exitApplication: () async => calls.add('exit'),
    );

    await expectLater(
      coordinator.exit(
        cleanup: () async {
          calls.add('cleanup');
          throw StateError('cleanup failed');
        },
      ),
      throwsStateError,
    );

    expect(calls, ['cleanup', 'window', 'core', 'exit']);
  });

  group('SystemAction exit orchestration', () {
    late TestSystemAction action;
    late ProviderContainer container;

    setUp(() {
      action = TestSystemAction();
      container = ProviderContainer(
        overrides: [systemActionProvider.overrideWith(() => action)],
      );
      globalState.container = container;
      container.read(systemActionProvider.notifier);
    });

    tearDown(() {
      final gate = action.closeCoreGate;
      if (gate != null && !gate.isCompleted) {
        gate.complete();
      }
      container.dispose();
    });

    SystemAction notifier() => container.read(systemActionProvider.notifier);

    test('runs cleanup, window, Core and application exit in order', () async {
      await notifier().handleExit();

      expect(action.calls, ['cleanup', 'window', 'core', 'exit']);
      expect(action.cleanupNeedSave, [true]);
    });

    test('forwards an explicit save opt-out to resource cleanup', () async {
      await notifier().handleExit(false);

      expect(action.cleanupNeedSave, [false]);
    });

    test('concurrent exit requests share one shutdown', () async {
      action.closeCoreGate = Completer<void>();

      final first = notifier().handleExit();
      final second = notifier().handleExit(true);
      await Future<void>.delayed(Duration.zero);

      expect(action.calls, ['cleanup', 'window', 'core']);

      action.closeCoreGate!.complete();
      await Future.wait([first, second]);

      expect(action.calls, ['cleanup', 'window', 'core', 'exit']);
      expect(action.cleanupNeedSave, [true]);
    });

    test('a later exit request never restarts a finished shutdown', () async {
      await notifier().handleExit();
      await notifier().handleExit();

      expect(action.calls, ['cleanup', 'window', 'core', 'exit']);
    });

    test(
      'the watchdog exits the application when Core shutdown hangs',
      () async {
        action.watchdog = const Duration(milliseconds: 1);
        action.closeCoreGate = Completer<void>();

        final operation = notifier().handleExit();
        await Future<void>.delayed(const Duration(milliseconds: 20));

        expect(action.calls, ['cleanup', 'window', 'core', 'exit']);

        action.closeCoreGate!.complete();
        await operation;

        expect(
          action.calls.where((call) => call == 'exit').length,
          1,
          reason: 'the watchdog and normal completion share one exit',
        );
      },
    );

    test('a cleanup failure still closes the window, Core and app', () async {
      action.cleanupError = StateError('cleanup failed');

      await expectLater(notifier().handleExit(), throwsStateError);

      expect(action.calls, ['cleanup', 'window', 'core', 'exit']);
    });
  });

  test(
    'saving preferences captures the latest normal window geometry',
    () async {
      await mockPreferences();
      const geometry = WindowProps(width: 1180, height: 760, left: 72, top: 48);
      windowPort = _GeometryWindowPort(geometry);
      final action = _PersistenceSystemAction();
      final container = ProviderContainer(
        overrides: [systemActionProvider.overrideWith(() => action)],
      );
      globalState.container = container;
      addTearDown(() {
        windowPort = null;
        container.dispose();
      });

      container.read(systemActionProvider.notifier);
      await action.persist();

      expect(container.read(windowSettingProvider), geometry);
      expect((await preferences.getConfig())?.windowProps, geometry);
    },
  );

  test(
    'a geometry failure does not prevent saving the current config',
    () async {
      await mockPreferences();
      const current = WindowProps(width: 900, height: 640, left: 24, top: 16);
      windowPort = _GeometryWindowPort(
        const WindowProps(),
        error: StateError('window unavailable'),
      );
      final action = _PersistenceSystemAction();
      final container = ProviderContainer(
        overrides: [
          windowSettingProvider.overrideWithBuild((_, _) => current),
          systemActionProvider.overrideWith(() => action),
        ],
      );
      globalState.container = container;
      addTearDown(() {
        windowPort = null;
        container.dispose();
      });

      container.read(systemActionProvider.notifier);
      await action.persist();

      expect((await preferences.getConfig())?.windowProps, current);
    },
  );

  group('SystemAction setting toggles', () {
    late ProviderContainer container;

    setUp(() {
      container = ProviderContainer();
      globalState.container = container;
    });

    tearDown(() => container.dispose());

    test('updateTun flips the patched Core tun flag', () {
      final before = container.read(patchClashConfigProvider).tun.enable;

      container.read(systemActionProvider.notifier).updateTun();

      expect(container.read(patchClashConfigProvider).tun.enable, !before);
    });

    test('updateSystemProxy flips the system proxy flag', () {
      final before = container.read(networkSettingProvider).systemProxy;

      container.read(systemActionProvider.notifier).updateSystemProxy();

      expect(container.read(networkSettingProvider).systemProxy, !before);
    });

    test('updateAutoLaunch flips the auto launch flag', () {
      final before = container.read(appSettingProvider).autoLaunch;

      container.read(systemActionProvider.notifier).updateAutoLaunch();

      expect(container.read(appSettingProvider).autoLaunch, !before);
    });
  });
}
