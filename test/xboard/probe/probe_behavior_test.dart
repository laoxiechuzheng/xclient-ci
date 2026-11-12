import 'dart:async';
import 'dart:io';

import 'package:fl_clash/xboard/probe/probe_scheduler.dart';
import 'package:fl_clash/xboard/probe/region_failover.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = ProbeTarget(
  name: 'JP-1',
  identity: 'a',
  url: 'https://test.example',
);
const _b = ProbeTarget(
  name: 'JP-2',
  identity: 'b',
  url: 'https://test.example',
);
const _c = ProbeTarget(
  name: 'US-1',
  identity: 'c',
  url: 'https://test.example',
);

void main() {
  testWidgets('changing a test URL cannot bypass a per-node probe budget', (
    tester,
  ) async {
    var calls = 0;
    final scheduler = ProbeScheduler(
      probe: (_) async {
        calls++;
        return 30;
      },
      now: () => tester.binding.clock.now(),
      randomInt: (_) => 0,
    );
    scheduler.setTargets([_a]);
    scheduler.setRunning(true);
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    scheduler.request([
      const ProbeTarget(
        name: 'JP-1',
        identity: 'a',
        url: 'https://other.example',
      ),
    ]);
    await tester.pump(const Duration(minutes: 19));
    expect(calls, 1);
    scheduler.dispose();
  });

  testWidgets(
    'stopping the core discards an in-flight result and cancels timers',
    (tester) async {
      final pending = Completer<int>();
      final scheduler = ProbeScheduler(
        probe: (_) => pending.future,
        randomInt: (_) => 0,
      );
      scheduler.setTargets([_a]);
      scheduler.setRunning(true);
      await tester.pump(const Duration(seconds: 2));
      scheduler.setRunning(false);
      pending.complete(40);
      await tester.pump();
      expect(scheduler.cached(_a), isNull);
      scheduler.dispose();
    },
  );

  test('emergency probing stays within two concurrent calls', () async {
    var active = 0;
    var maximum = 0;
    final started = <String>[];
    final pending = <Completer<int>>[];
    final scheduler = ProbeScheduler(
      probe: (target) {
        active++;
        if (active > maximum) maximum = active;
        started.add(target.name);
        final result = Completer<int>();
        pending.add(result);
        return result.future.whenComplete(() => active--);
      },
    );
    scheduler.setRunning(true);
    final work = scheduler.emergency(
      (probe) => Future.wait([probe(_a), probe(_b), probe(_c)]),
    );
    await Future<void>.delayed(Duration.zero);
    expect(started.length, 2);
    pending.first.complete(40);
    await Future<void>.delayed(Duration.zero);
    expect(started.length, 3);
    pending[1].complete(30);
    pending[2].complete(-1);
    await work;
    expect(maximum, 2);
    scheduler.dispose();
  });

  test(
    'cache is restored atomically and tolerates malformed records',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'xclient-probe-cache-test-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/cache.json');
      final cache = ProbeCacheFile(file);
      final record = ProbeRecord(
        target: _a,
        latency: 75,
        checkedAt: DateTime.utc(2026),
        nextProbeAt: DateTime.utc(2026).add(const Duration(minutes: 20)),
      );
      await cache.save([record]);
      expect((await cache.load()).single.latency, 75);
      expect(await File('${file.path}.pending').exists(), isFalse);
      await file.writeAsString('[{"name":true}]');
      expect(await cache.load(), isEmpty);
    },
  );

  testWidgets(
    'three matching failures in twenty seconds trigger exactly one confirmation',
    (tester) async {
      var calls = 0;
      final scheduler = ProbeScheduler(
        probe: (_) async {
          calls++;
          return 40;
        },
        randomInt: (_) => 0,
      );
      scheduler.setRunning(true);
      const selection = FailoverSelection(
        group: 'Proxy',
        target: _a,
        candidates: [_b],
      );
      final failover = RegionFailover(
        scheduler: scheduler,
        selections: () => [selection],
        changeProxy: (_, _) async => true,
        closeOldConnections: (_) async {},
        notify: (_) {},
        now: () => tester.binding.clock.now(),
      );
      failover.observeLog('dial JP-2 error: timeout');
      failover.observeLog('dial JP-1 error: timeout');
      failover.observeLog('dial JP-1 error: timeout');
      await tester.pump();
      expect(calls, 0);
      failover.observeLog('dial JP-1 error: timeout');
      await tester.pump();
      expect(calls, 1);
      for (var i = 0; i < 10; i++) {
        failover.observeLog('dial JP-1 error: timeout');
      }
      await tester.pump();
      expect(calls, 1);
      failover.dispose();
      scheduler.dispose();
    },
  );

  testWidgets('stalled new demand confirms once; idle connections do not', (
    tester,
  ) async {
    var calls = 0;
    final scheduler = ProbeScheduler(
      probe: (_) async {
        calls++;
        return 40;
      },
      randomInt: (_) => 0,
    );
    scheduler.setRunning(true);
    const selection = FailoverSelection(
      group: 'Proxy',
      target: _a,
      candidates: [_b],
    );
    final failover = RegionFailover(
      scheduler: scheduler,
      selections: () => [selection],
      changeProxy: (_, _) async => true,
      closeOldConnections: (_) async {},
      notify: (_) {},
      now: () => tester.binding.clock.now(),
    );
    failover.observeTraffic(selection, totalBytes: 100, activeConnections: 1);
    await tester.pump(const Duration(seconds: 16));
    failover.observeTraffic(selection, totalBytes: 100, activeConnections: 1);
    await tester.pump();
    expect(calls, 0);
    failover.observeTraffic(
      selection,
      totalBytes: 100,
      activeConnections: 2,
      hasNewConnections: true,
    );
    await tester.pump();
    expect(calls, 1);
    failover.dispose();
    scheduler.dispose();
  });

  test(
    'same-region all down preserves selection and never probes a foreign candidate',
    () async {
      final probes = <String>[];
      final messages = <String>[];
      var changes = 0;
      final scheduler = ProbeScheduler(
        probe: (target) async {
          probes.add(target.name);
          return -1;
        },
      );
      scheduler.setRunning(true);
      const selection = FailoverSelection(
        group: 'Proxy',
        target: _a,
        candidates: [_b, _c],
      );
      final failover = RegionFailover(
        scheduler: scheduler,
        selections: () => [selection],
        changeProxy: (_, _) async {
          changes++;
          return true;
        },
        closeOldConnections: (_) async {},
        notify: messages.add,
        sleep: (_) async {},
      );
      await failover.confirmAndRecover(selection);
      expect(probes, ['JP-1', 'JP-2']);
      expect(changes, 0);
      expect(messages.single, contains('已保留原选择'));
      failover.dispose();
      scheduler.dispose();
    },
  );
}
