import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/probe/probe_scheduler.dart';
import 'package:fl_clash/xboard/probe/region_failover.dart';
import 'package:flutter_test/flutter_test.dart';

class _NativeCore extends CoreHandlerInterface {
  _NativeCore(this.process, this.nonce) {
    lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (line == 'PASS' && closing) return;
          try {
            final frame = Map<String, dynamic>.from(jsonDecode(line) as Map);
            switch (frame['kind']) {
              case 'ready':
                if (frame['nonce'] != nonce) throw StateError('owner mismatch');
                ready.complete(
                  Map<String, dynamic>.from(frame['result'] as Map),
                );
              case 'event':
                final value = frame['value'] as Map;
                for (final event in coreEventsFromData(value['arguments'])) {
                  coreEventManager.sendEvent(event);
                }
              case 'response':
                final pending = requests.remove(frame['id']);
                if (frame['error'] != null) {
                  pending?.completeError(StateError('native RPC refused'));
                } else {
                  pending?.complete(frame['result']);
                }
              default:
                throw StateError('invalid fixture frame');
            }
          } on Object catch (error, stack) {
            failure ??= error;
            if (!ready.isCompleted) ready.completeError(error, stack);
            for (final request in requests.values) {
              if (!request.isCompleted) request.completeError(error, stack);
            }
            requests.clear();
          }
        });
    errors = process.stderr
        .transform(utf8.decoder)
        .listen((_) => stderrChunks++);
  }

  final Process process;
  final String nonce;
  final ready = Completer<Map<String, dynamic>>();
  final requests = <String, Completer<Object?>>{};
  late final StreamSubscription<String> lines;
  late final StreamSubscription<String> errors;
  Object? failure;
  var nextId = 0;
  var stderrChunks = 0;
  var closing = false;

  Future<Object?> call(String method, [Object? arguments]) {
    if (closing) throw StateError('native fixture closed');
    final id = '${++nextId}';
    final result = Completer<Object?>();
    requests[id] = result;
    process.stdin.writeln(
      jsonEncode({
        'nonce': nonce,
        'id': id,
        'method': method,
        'arguments': arguments,
      }),
    );
    return result.future.timeout(const Duration(seconds: 8));
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async => (await call(method.name, arguments)) as T?;

  Future<void> dispose() async {
    closing = true;
    await process.stdin.flush();
    await process.stdin.close();
    final code = await process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await lines.cancel();
    await errors.cancel();
    expect(code, 0, reason: 'owned Go process must close on EOF');
    expect(failure, isNull);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('unused lifecycle method');
}

class _NativeLogListener with CoreEventListener {
  _NativeLogListener(this.deliver);
  final void Function(Log) deliver;
  @override
  void onLog(Log log) => deliver(log);
}

Future<void> _until(
  bool Function() condition,
  Duration timeout, {
  String reason = 'real native failover did not converge',
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final binary = Platform.environment['XC_FAILOVER_TEST_BINARY'] ?? '';
  test(
    'real native failures switch only to a confirmed same-region node',
    () async {
      expect(File(binary).isAbsolute, isTrue);
      expect(await File(binary).exists(), isTrue);
      final random = Random.secure();
      final nonce = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final native = _NativeCore(
        await Process.start(
          binary,
          const [
            '-test.run=^TestXClientFailoverHarness\$',
            '-test.paniconexit0=false',
          ],
          environment: {
            'XC_FAILOVER_TEST_BRIDGE': '1',
            'XC_FAILOVER_TEST_NONCE': nonce,
          },
        ),
        nonce,
      );
      ProbeScheduler? scheduler;
      RegionFailover? recovery;
      _NativeLogListener? listener;
      final observations = <String, Object?>{};
      try {
        final fixture = await native.ready.future.timeout(
          const Duration(seconds: 15),
        );
        final url = fixture['url'] as String;
        expect(Uri.parse(url).host, '127.0.0.1');
        final core = CoreController.scoped(native);
        final targets = [
          for (final name in ['JP-A', 'JP-B', 'JP-C', 'US-A'])
            ProbeTarget(name: name, identity: '$nonce:$name', url: url),
        ];
        final before = await core.getDelay(
          url,
          'US-A',
          const Duration(seconds: 3),
        );
        expect(
          before?.value,
          greaterThan(0),
          reason: 'the excluded region must really be available',
        );
        var phase = 'normal';
        var normalActive = 0, emergencyActive = 0;
        var normalMaximum = 0, emergencyMaximum = 0;
        final samples = <String>[];
        final completed = <ProbeRecord>[];
        scheduler = ProbeScheduler(
          randomInt: (_) => 0,
          probe: (target) async {
            final current = phase;
            samples.add('$current:${target.name}');
            if (current == 'normal') {
              normalMaximum = max(normalMaximum, ++normalActive);
            } else {
              emergencyMaximum = max(emergencyMaximum, ++emergencyActive);
            }
            try {
              return (await core.getDelay(
                    target.url,
                    target.name,
                    const Duration(seconds: 3),
                  ))?.value ??
                  -1;
            } finally {
              if (current == 'normal') {
                normalActive--;
              } else {
                emergencyActive--;
              }
            }
          },
          onResult: completed.add,
        );
        final notices = <String>[];
        var actualSelection = 'JP-A';
        recovery = RegionFailover(
          scheduler: scheduler,
          randomInt: (_) => 0,
          selections: () => [
            FailoverSelection(
              group: 'JP-Group',
              target: targets.first,
              candidates: targets,
            ),
          ],
          changeProxy: (group, target) async {
            final result = await core.changeProxy(
              ChangeProxyParams(groupName: group, proxyName: target.name),
            );
            expect(result.message, isEmpty);
            final live = await native.call('getProxies') as Map;
            actualSelection =
                ((live['proxies'] as Map)[group] as Map)['now'] as String;
            return actualSelection == target.name;
          },
          closeOldConnections: (name) async {
            for (final connection in await core.getConnections()) {
              if (connection.chains.contains(name)) {
                await core.closeConnection(connection.id);
              }
            }
          },
          notify: notices.add,
        );
        var relevantLogs = 0;
        var refusedLogs = 0;
        final negative =
            Platform.environment['XC_FAILOVER_TEST_NEGATIVE_CONTROL'] == '1';
        listener = _NativeLogListener((log) {
          if (log.payload.contains('JP-Group') &&
              log.payload.contains('error')) {
            relevantLogs++;
            if (log.payload.toLowerCase().contains('refused')) {
              refusedLogs++;
            }
          }
          if (relevantLogs >= 3) phase = 'emergency';
          if (!negative) recovery!.observeLog(log.payload);
        });
        coreEventManager.addListener(listener);
        scheduler.setTargets([targets.first]);
        scheduler.setRunning(true);
        await _until(
          () => completed.any((record) => record.latency > 0),
          const Duration(seconds: 6),
        );
        final original = await native.call('fixtureRequest') as Map;
        expect(original, containsPair('node', 'JP-A'));
        final initialStats = await native.call('fixtureStats') as Map;
        expect(await native.call('fixtureStopA'), isTrue);
        for (var index = 0; index < 3 && relevantLogs < 3; index++) {
          final response = await native.call('fixtureRequest') as Map;
          if (response['status'] == 200) {
            expect(response['node'], 'JP-B');
          }
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        try {
          await _until(
            () => relevantLogs >= 3,
            const Duration(seconds: 3),
            reason: 'No native failure logs at the production error threshold',
          );
          expect(refusedLogs, greaterThanOrEqualTo(3));
          await _until(
            () => actualSelection == 'JP-B',
            const Duration(seconds: 8),
            reason: 'No recovery after $relevantLogs native failures',
          );
        } on Object {
          final live = await native.call('getProxies') as Map;
          final stats = await native.call('fixtureStats') as Map;
          // ignore: avoid_print
          print(
            'NATIVE_FAILOVER_FAILURE ${jsonEncode({'selected': ((live['proxies'] as Map)['JP-Group'] as Map)['now'], 'nativeLogs': relevantLogs, 'nativeRefusedLogs': refusedLogs, 'dials': stats['dials']})}',
          );
          rethrow;
        }
        final after = await native.call('fixtureRequest') as Map;
        expect(after, containsPair('status', 200));
        expect(after, containsPair('node', 'JP-B'));
        final applied = await native.call('getProxies') as Map;
        expect(((applied['proxies'] as Map)['JP-Group'] as Map)['now'], 'JP-B');
        final stats = await native.call('fixtureStats') as Map;
        final dials = stats['dials'] as Map;
        expect(
          (dials['JP-A'] as int) -
              ((initialStats['dials'] as Map)['JP-A'] as int),
          greaterThanOrEqualTo(3),
        );
        expect(dials['US-A'], (initialStats['dials'] as Map)['US-A']);
        expect(
          samples.where((sample) => sample.startsWith('emergency:')),
          containsAll(['emergency:JP-A', 'emergency:JP-B', 'emergency:JP-C']),
        );
        expect(samples, isNot(contains('emergency:US-A')));
        expect(normalMaximum, 1);
        expect(emergencyMaximum, 2);
        expect(stats['maximum'], lessThanOrEqualTo(2));
        expect(notices, contains('已切换到同地区可用节点'));
        observations.addAll({
          'selected': actualSelection,
          'httpViaB': true,
          'nativeLogs': relevantLogs,
          'nativeRefusedLogs': refusedLogs,
          'dials': dials,
          'normalMaximum': normalMaximum,
          'emergencyMaximum': emergencyMaximum,
          'nativeMaximum': stats['maximum'],
        });
        // ignore: avoid_print
        print('NATIVE_FAILOVER ${jsonEncode(observations)}');
      } finally {
        if (listener != null) coreEventManager.removeListener(listener);
        recovery?.dispose();
        scheduler?.dispose();
        await native.dispose();
      }
    },
    skip: binary.isEmpty
        ? 'Requires an explicitly built local xclient Go test harness.'
        : false,
    timeout: const Timeout(Duration(seconds: 45)),
  );
}
