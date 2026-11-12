import 'dart:async';

import 'package:fl_clash/xboard/probe/display_delay.dart';
import 'package:fl_clash/xboard/probe/probe_scheduler.dart';
import 'package:fl_clash/xboard/probe/region_classifier.dart';
import 'package:fl_clash/xboard/probe/region_failover.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('display mapping is stable, bounded and monotonic', () {
    var previous = 10;
    for (var raw = 1; raw <= 65535; raw++) {
      final shown = displayDelay(raw);
      expect(shown, inInclusiveRange(10, 109));
      expect(shown, greaterThanOrEqualTo(previous));
      previous = shown;
    }
    expect(displayDelayText(-1), '超时');
    expect(displayDelayText(-2), '超时');
    expect(displayDelayText(null), isNull);
  });

  test('classifier recognises flags, Chinese, English and delimited ISO', () {
    for (final name in [
      '🇯🇵 日本 01',
      '[anytls]日本_03',
      'JP-Tokyo',
      'Japan 01',
    ]) {
      expect(classifyRegion(name), 'JP', reason: name);
    }
    expect(classifyRegion('Hong Kong 02'), 'HK');
    expect(classifyRegion('🇹🇼 Taiwan'), 'TW');
    expect(classifyRegion('新加坡_01'), 'SG');
    expect(classifyRegion('AUS-01'), 'AU');
    expect(classifyRegion('Just a proxy'), isNull);
    expect(classifyRegion('Singapore'), 'SG');
  });

  testWidgets('user requests cannot burst or override the minimum interval', (
    tester,
  ) async {
    final calls = <Duration>[];
    final origin = tester.binding.clock.now();
    final scheduler = ProbeScheduler(
      probe: (target) async {
        calls.add(tester.binding.clock.now().difference(origin));
        return 123;
      },
      now: () => tester.binding.clock.now(),
      randomInt: (_) => 0,
    );
    const a = ProbeTarget(
      name: 'JP-1',
      identity: 'server-a',
      url: 'https://test.example',
    );
    const b = ProbeTarget(
      name: 'JP-2',
      identity: 'server-b',
      url: 'https://test.example',
    );
    scheduler.setTargets([a, b]);
    scheduler.request([a, b]);
    await tester.pump(const Duration(seconds: 10));
    expect(calls, isEmpty);
    scheduler.setRunning(true);
    await tester.pump(const Duration(milliseconds: 1999));
    expect(calls, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(calls, [const Duration(seconds: 12)]);
    for (var i = 0; i < 100; i++) {
      scheduler.request([a, b]);
    }
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(calls.length, 2);
    expect(calls[1] - calls[0], const Duration(seconds: 2));
    await tester.pump(const Duration(minutes: 19));
    expect(calls.length, 2);
    scheduler.setRunning(false);
    await tester.pump(const Duration(hours: 2));
    expect(calls.length, 2);
    scheduler.dispose();
  });

  test('server identity changes invalidate a cached node name', () async {
    const a = ProbeTarget(
      name: 'JP-1',
      identity: 'server-a',
      url: 'https://test.example',
    );
    const b = ProbeTarget(
      name: 'JP-1',
      identity: 'server-b',
      url: 'https://test.example',
    );
    final record = ProbeRecord(
      target: a,
      latency: 88,
      checkedAt: DateTime.utc(2026),
      nextProbeAt: DateTime.utc(2027),
    );
    final scheduler = ProbeScheduler(
      probe: (_) async => 1,
      initialRecords: [record],
    );
    expect(scheduler.cached(a)?.latency, 88);
    expect(scheduler.cached(b), isNull);
    scheduler.dispose();
  });

  test(
    'failover confirms failure, prefers last success, switches and closes only the old route',
    () async {
      const old = ProbeTarget(
        name: 'JP-1',
        identity: 'a',
        url: 'https://test.example',
      );
      const good = ProbeTarget(
        name: 'JP-2',
        identity: 'b',
        url: 'https://test.example',
      );
      const bad = ProbeTarget(
        name: 'JP-3',
        identity: 'c',
        url: 'https://test.example',
      );
      const foreign = ProbeTarget(
        name: 'US-1',
        identity: 'd',
        url: 'https://test.example',
      );
      var selection = const FailoverSelection(
        group: 'Proxy',
        target: old,
        candidates: [bad, foreign, good],
      );
      final events = <String>[];
      final scheduler = ProbeScheduler(
        probe: (target) async {
          events.add('probe:${target.name}');
          return target == good ? 52 : -1;
        },
        initialRecords: [
          ProbeRecord(
            target: good,
            latency: 40,
            checkedAt: DateTime.now().subtract(const Duration(hours: 1)),
            nextProbeAt: DateTime.now(),
          ),
        ],
        randomInt: (_) => 0,
      );
      scheduler.setRunning(true);
      final failover = RegionFailover(
        scheduler: scheduler,
        selections: () => [selection],
        changeProxy: (group, target) async {
          events.add('switch:${target.name}');
          selection = FailoverSelection(
            group: group,
            target: target,
            candidates: selection.candidates,
          );
          return true;
        },
        closeOldConnections: (name) async => events.add('close:$name'),
        notify: events.add,
        sleep: (_) async {},
        randomInt: (_) => 0,
      );
      await failover.confirmAndRecover(selection);
      expect(events.take(2), ['probe:JP-1', 'probe:JP-2']);
      expect(events, containsAllInOrder(['switch:JP-2', 'close:JP-1']));
      expect(events, isNot(contains('probe:US-1')));
      failover.dispose();
      scheduler.dispose();
    },
  );

  test(
    'a user selection made during confirmation supersedes failover',
    () async {
      const old = ProbeTarget(
        name: 'JP-1',
        identity: 'a',
        url: 'https://test.example',
      );
      const good = ProbeTarget(
        name: 'JP-2',
        identity: 'b',
        url: 'https://test.example',
      );
      final pending = Completer<int>();
      var selection = const FailoverSelection(
        group: 'Proxy',
        target: old,
        candidates: [good],
      );
      var changes = 0;
      final scheduler = ProbeScheduler(probe: (_) => pending.future);
      scheduler.setRunning(true);
      final failover = RegionFailover(
        scheduler: scheduler,
        selections: () => [selection],
        changeProxy: (_, _) async {
          changes++;
          return true;
        },
        closeOldConnections: (_) async {},
        notify: (_) {},
        sleep: (_) async {},
      );
      final recovery = failover.confirmAndRecover(selection);
      await Future<void>.delayed(Duration.zero);
      selection = const FailoverSelection(
        group: 'Proxy',
        target: good,
        candidates: [old],
      );
      pending.complete(-1);
      await recovery;
      expect(changes, 0);
      failover.dispose();
      scheduler.dispose();
    },
  );
  test(
    'failed switch continues to the next healthy candidate without parallel switches',
    () async {
      const old = ProbeTarget(
        name: 'JP-1',
        identity: 'a',
        url: 'https://test.example',
      );
      const a = ProbeTarget(
        name: 'JP-2',
        identity: 'b',
        url: 'https://test.example',
      );
      const b = ProbeTarget(
        name: 'JP-3',
        identity: 'c',
        url: 'https://test.example',
      );
      const selection = FailoverSelection(
        group: 'Proxy',
        target: old,
        candidates: [a, b],
      );
      final changes = <String>[];
      var active = 0;
      var maxActive = 0;
      final scheduler = ProbeScheduler(
        probe: (target) async => target == old ? -1 : 50,
      );
      scheduler.setRunning(true);
      final failover = RegionFailover(
        scheduler: scheduler,
        selections: () => [selection],
        changeProxy: (_, target) async {
          active++;
          if (active > maxActive) maxActive = active;
          changes.add(target.name);
          await Future<void>.delayed(Duration.zero);
          active--;
          return changes.length > 1;
        },
        closeOldConnections: (_) async {},
        notify: (_) {},
        sleep: (_) async {},
        randomInt: (max) => max - 1,
      );
      await failover.confirmAndRecover(selection);
      expect(changes, ['JP-2', 'JP-3']);
      expect(maxActive, 1);
      failover.dispose();
      scheduler.dispose();
    },
  );

  test('longer country aliases win over embedded country names', () {
    expect(classifyRegion('印度尼西亚 01'), 'ID');
    expect(classifyRegion('印度 01'), 'IN');
    expect(classifyRegion('notJapan'), isNull);
  });
}
