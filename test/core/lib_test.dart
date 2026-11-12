import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/lib.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/l10n/l10n.dart';
import 'package:fl_clash/state.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/test_profiles.dart';

class _FakeService implements Service {
  _FakeService();

  final calls = <String>[];
  final listeners = <ServiceListener>[];
  var attached = 0;
  var detached = 0;

  @override
  void addListener(ServiceListener listener) {
    attached++;
    listeners.add(listener);
  }

  @override
  void removeListener(ServiceListener listener) {
    if (listeners.remove(listener)) detached++;
  }

  String initError = '';
  String syncError = '';
  bool shutdownResult = true;
  bool startResult = true;
  bool stopResult = true;
  CoreMethodResponse? Function(CoreMethodCall call)? onInvokeMethod;

  final invokedCalls = <CoreMethodCall>[];

  @override
  Future<String> init() async {
    calls.add('init');
    return initError;
  }

  @override
  Future<String> syncState(SharedState state) async {
    calls.add('syncState');
    return syncError;
  }

  @override
  Future<bool> shutdown() async {
    calls.add('shutdown');
    return shutdownResult;
  }

  @override
  Future<bool> start() async {
    calls.add('start');
    return startResult;
  }

  @override
  Future<bool> stop() async {
    calls.add('stop');
    return stopResult;
  }

  @override
  Future<CoreMethodResponse?> invokeMethod(CoreMethodCall call) async {
    calls.add('invokeMethod:${call.method.name}');
    invokedCalls.add(call);
    return onInvokeMethod?.call(call);
  }

  @override
  Future<DateTime?> getRunTime() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CoreLogRecorder with CoreEventListener {
  final payloads = <String>[];
  @override
  void onLog(Log log) => payloads.add(log.payload);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'managed Core owns native event routing without a View and detaches exactly once',
    () async {
      final native = _FakeService();
      final managed = CoreLib.scoped(native, confirmedStops: true);
      final recorder = _CoreLogRecorder();
      coreEventManager.addListener(recorder);
      addTearDown(() => coreEventManager.removeListener(recorder));
      expect(native.listeners, hasLength(1));
      native.listeners.single.onServiceEvent(
        const CoreEvent(
          type: CoreEventType.log,
          data: {'LogLevel': 'warning', 'Payload': 'NoView owned failure'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(recorder.payloads, ['NoView owned failure']);
      await managed.stop();
      expect(native.attached, 1);
      expect(native.listeners, hasLength(1));
      await managed.close();
      await managed.close();
      expect(native.detached, 1);
      expect(native.listeners, isEmpty);
    },
  );

  for (final answered in [false, true]) {
    test(
      'managed native stop owns listeners without a stale duplicate RPC; answered=$answered',
      () async {
        final native = _FakeService()..stopResult = answered;
        final managed = CoreLib.scoped(native, confirmedStops: true);
        expect(await managed.stopListener(), answered);
        expect(native.calls, ['stop']);
        expect(native.invokedCalls, isEmpty);
      },
    );
  }

  late ProviderContainer container;
  late _FakeService service;
  late CoreLib lib;

  setUpAll(() async {
    await AppLocalizations.load(const Locale('en'));
  });

  setUp(() {
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(TestProfiles.new)],
    );
    globalState.container = container;
    service = _FakeService();
    lib = CoreLib.scoped(service);
  });

  tearDown(() {
    container.dispose();
    CoreLib.resetInstance();
  });

  group('start', () {
    test('initializes, connects and syncs shared state', () async {
      final result = await lib.start();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      expect(result.revision, 1);
      expect(service.calls, ['init', 'syncState']);
    });

    test('coalesces a second start while already connected', () async {
      await lib.start();
      service.calls.clear();

      final result = await lib.start();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
      expect(result.revision, 2);
      expect(service.calls, isEmpty);
    });

    test('an initialization error leaves the handler unconnected', () async {
      service.initError = 'init boom';

      await expectLater(
        lib.start(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'init boom'),
        ),
      );
      expect(service.calls, ['init']);

      service.initError = '';
      final retry = await lib.start();
      expect(retry.outcome, CoreLifecycleOutcome.applied);
    });

    test('a sync error shuts the service down and reopens the gate', () async {
      service.syncError = 'sync boom';

      await expectLater(
        lib.start(),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'sync boom'),
        ),
      );
      expect(service.calls, ['init', 'syncState', 'shutdown']);

      service.syncError = '';
      service.calls.clear();
      final retry = await lib.start();

      expect(retry.outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['init', 'syncState']);
    });
  });

  group('stop', () {
    test('coalesces when there is nothing connected', () async {
      final result = await lib.stop();

      expect(result.outcome, CoreLifecycleOutcome.coalesced);
      expect(service.calls, isEmpty);
    });

    test('shuts the service down once connected', () async {
      await lib.start();
      service.calls.clear();

      final result = await lib.stop();

      expect(result.outcome, CoreLifecycleOutcome.applied);
      expect(service.calls, ['shutdown']);
    });

    test('a failed shutdown throws but still closes the gate', () async {
      await lib.start();
      service.shutdownResult = false;

      await expectLater(lib.stop(), throwsA(isA<StateError>()));

      service.shutdownResult = true;
      final again = await lib.stop();
      expect(again.outcome, CoreLifecycleOutcome.coalesced);
    });
  });

  test('restart stops before starting again', () async {
    await lib.start();
    service.calls.clear();

    final result = await lib.restart();

    expect(result.outcome, CoreLifecycleOutcome.applied);
    expect(service.calls, ['shutdown', 'init', 'syncState']);
  });

  group('close', () {
    test('is terminal and rejects later lifecycle intents', () async {
      await lib.start();

      final result = await lib.close();
      expect(result.outcome, CoreLifecycleOutcome.applied);

      await expectLater(lib.start(), throwsA(isA<StateError>()));
      await expectLater(lib.stop(), throwsA(isA<StateError>()));
    });

    test('runs the shutdown once no matter how often it is called', () async {
      await lib.start();
      service.calls.clear();

      final first = lib.close();
      final second = lib.close();

      expect(identical(first, second), isTrue);
      await first;
      await second;

      expect(service.calls, ['shutdown']);
    });
  });

  group('listeners', () {
    test('a listener start is answered by the service', () async {
      await lib.start();
      service.onInvokeMethod = (_) =>
          const CoreMethodResponse(id: '1', result: true);

      expect(await lib.startListener(), isTrue);

      service.startResult = false;
      expect(await lib.startListener(), isFalse);

      service.startResult = true;
      service.onInvokeMethod = (_) => null;
      expect(await lib.startListener(), isTrue);
      expect(service.calls.last, 'start');
    });

    test('a listener stop is answered by the service', () async {
      await lib.start();
      service.onInvokeMethod = (_) => null;

      expect(await lib.stopListener(), isTrue);

      service.stopResult = false;
      expect(await lib.stopListener(), isFalse);
    });

    test('stopListener stops the service before the core listener', () async {
      await lib.start();
      service.onInvokeMethod = (_) =>
          const CoreMethodResponse(id: '1', result: true);
      service.calls.clear();

      expect(await lib.stopListener(), isTrue);
      expect(service.calls, ['stop', 'invokeMethod:stopListener']);
    });
  });

  group('invokeMethod', () {
    test('assigns an increasing call id per request', () async {
      await lib.start();
      service.onInvokeMethod = (call) =>
          CoreMethodResponse(id: call.id, result: 'ok');

      await lib.invokeMethod<String>(method: CoreMethod.getProxies);
      await lib.invokeMethod<String>(method: CoreMethod.getProxies);

      expect(service.invokedCalls.map((call) => call.id), ['1', '2']);
    });

    test('unwraps the response payload', () async {
      await lib.start();
      service.onInvokeMethod = (call) =>
          CoreMethodResponse(id: call.id, result: 'payload');

      expect(
        await lib.invokeMethod<String>(method: CoreMethod.getProxies),
        'payload',
      );
    });

    test('resolves to null when the service answers nothing', () async {
      await lib.start();
      service.onInvokeMethod = (_) => null;

      expect(
        await lib.invokeMethod<String>(method: CoreMethod.getProxies),
        isNull,
      );
    });

    testWidgets('gives up instead of hanging when no connection arrives', (
      tester,
    ) async {
      Object? result = 'unset';
      final pending = lib
          .invokeMethod<String>(method: CoreMethod.getProxies)
          .then((value) => result = value);

      await tester.pump(const Duration(seconds: 11));
      await pending;

      expect(result, isNull);
      expect(service.calls, isEmpty);
    });
  });
}
