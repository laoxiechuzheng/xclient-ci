import 'dart:async';
import 'dart:math';

import 'probe_scheduler.dart';
import 'region_classifier.dart';

class FailoverSelection {
  const FailoverSelection({
    required this.group,
    required this.target,
    required this.candidates,
  });

  final String group;
  final ProbeTarget target;
  final List<ProbeTarget> candidates;

  String get key => '$group\u0000${target.key}';
}

class _FailureWindow {
  final List<DateTime> failures = [];
  DateTime? lastProgress;
  DateTime? lastDemand;
  num? lastBytes;
}

class RegionFailover {
  RegionFailover({
    required this.scheduler,
    required this.selections,
    required this.changeProxy,
    required this.closeOldConnections,
    required this.notify,
    DateTime Function()? now,
    Future<void> Function(Duration)? sleep,
    int Function(int)? randomInt,
  }) : now = now ?? DateTime.now,
       sleep = sleep ?? Future<void>.delayed,
       randomInt = randomInt ?? Random.secure().nextInt;

  final ProbeScheduler scheduler;
  final List<FailoverSelection> Function() selections;
  final Future<bool> Function(String group, ProbeTarget target) changeProxy;
  final Future<void> Function(String name) closeOldConnections;
  final void Function(String message) notify;
  final DateTime Function() now;
  final Future<void> Function(Duration) sleep;
  final int Function(int) randomInt;
  final Map<String, _FailureWindow> _signals = {};
  final Map<String, DateTime> _cooldowns = {};
  bool enabled = true;
  bool allowCrossRegion = false;
  bool _recovering = false;
  bool _disposed = false;
  int _selectionGeneration = 0;

  static final _failure = RegExp(
    r'(dial|connect|handshake|连接|拨号).*(error|failed|failure|timeout|timed out|超时|失败)',
    caseSensitive: false,
  );

  void selectionChanged() {
    _selectionGeneration++;
    _signals.clear();
  }

  void observeLog(String payload) {
    if (!enabled ||
        _disposed ||
        !scheduler.running ||
        !_failure.hasMatch(payload)) {
      return;
    }
    final date = now();
    for (final selection in selections()) {
      if (!payload.contains(selection.target.name) &&
          !payload.contains(selection.group)) {
        continue;
      }
      final window = _signals.putIfAbsent(selection.key, _FailureWindow.new);
      window.failures.removeWhere(
        (time) => date.difference(time) > const Duration(seconds: 20),
      );
      window.failures.add(date);
      if (window.failures.length >= 3) unawaited(confirmAndRecover(selection));
    }
  }

  void observeTraffic(
    FailoverSelection selection, {
    required num totalBytes,
    required int activeConnections,
    bool hasNewConnections = false,
  }) {
    if (!enabled || _disposed || !scheduler.running) return;
    final date = now();
    final window = _signals.putIfAbsent(selection.key, _FailureWindow.new);
    if (hasNewConnections) window.lastDemand = date;
    if (activeConnections == 0 || window.lastBytes != totalBytes) {
      window.lastProgress = date;
      window.lastBytes = totalBytes;
      return;
    }
    window.lastProgress ??= date;
    final hasFailure = window.failures.any(
      (time) => date.difference(time) <= const Duration(seconds: 20),
    );
    final hasDemand =
        window.lastDemand != null &&
        date.difference(window.lastDemand!) <= const Duration(seconds: 20);
    if ((hasFailure || hasDemand) &&
        date.difference(window.lastProgress!) >= const Duration(seconds: 15)) {
      unawaited(confirmAndRecover(selection));
    }
  }

  bool _current(FailoverSelection selection, int generation) =>
      !_disposed &&
      enabled &&
      scheduler.running &&
      generation == _selectionGeneration &&
      selections().any((current) => current.key == selection.key);

  Future<void> confirmAndRecover(FailoverSelection selection) async {
    final date = now();
    final cooldown = _cooldowns[selection.key];
    if (_recovering ||
        !enabled ||
        _disposed ||
        !scheduler.running ||
        (cooldown != null && date.isBefore(cooldown))) {
      return;
    }
    final generation = _selectionGeneration;
    if (!_current(selection, generation)) return;
    _recovering = true;
    _cooldowns[selection.key] = date.add(const Duration(minutes: 5));
    try {
      await scheduler.emergency<void>((probe) async {
        final confirmation = await probe(selection.target);
        if (!_current(selection, generation) ||
            confirmation == null ||
            confirmation > 0) {
          return;
        }
        final region = classifyRegion(selection.target.name);
        final sameRegion = selection.candidates
            .where(
              (target) =>
                  target != selection.target &&
                  region != null &&
                  classifyRegion(target.name) == region,
            )
            .toList();
        final candidates = _ordered(sameRegion);
        if (allowCrossRegion) {
          candidates.addAll(
            _ordered(
              selection.candidates
                  .where(
                    (target) =>
                        target != selection.target &&
                        !sameRegion.contains(target),
                  )
                  .toList(),
            ),
          );
        }
        var recovered = false;
        final active = <Future<void>>[];
        var cursor = 0;
        Future<void> switchTail = Future<void>.value();
        Future<void> check(ProbeTarget target) async {
          final result = await probe(target);
          if (result == null ||
              result <= 0 ||
              recovered ||
              !_current(selection, generation)) {
            return;
          }
          final previous = switchTail;
          final completion = Completer<void>();
          switchTail = completion.future;
          try {
            await previous;
            if (recovered || !_current(selection, generation)) return;
            bool switched;
            try {
              switched = await changeProxy(selection.group, target);
            } on Object {
              return;
            }
            if (!switched || _disposed) return;
            recovered = true;
            try {
              await closeOldConnections(selection.target.name);
            } on Object {
              notify('已切换节点，部分旧连接未能清理');
              return;
            }
            notify(
              classifyRegion(target.name) == region
                  ? '已切换到同地区可用节点'
                  : '已切换到其他地区可用节点',
            );
          } finally {
            completion.complete();
          }
        }

        while (cursor < candidates.length &&
            !recovered &&
            _current(selection, generation)) {
          if (active.length >= 2) await Future.any(active);
          if (recovered || !_current(selection, generation)) break;
          final target = candidates[cursor++];
          late final Future<void> work;
          work = check(target).whenComplete(() => active.remove(work));
          active.add(work);
          if (cursor < candidates.length) {
            await sleep(Duration(milliseconds: 300 + randomInt(501)));
          }
        }
        await Future.wait(active.toList());
        if (recovered) {
          scheduler.request(candidates.skip(cursor));
        } else if (_current(selection, generation)) {
          notify('当前地区暂时没有可用节点，已保留原选择');
        }
      });
    } on Object {
      if (_current(selection, generation)) notify('故障转移未完成，已保留原选择');
    } finally {
      _recovering = false;
    }
  }

  List<ProbeTarget> _ordered(List<ProbeTarget> candidates) {
    for (var index = candidates.length - 1; index > 0; index--) {
      final other = randomInt(index + 1);
      final value = candidates[index];
      candidates[index] = candidates[other];
      candidates[other] = value;
    }
    candidates.sort((a, b) {
      final aa = scheduler.cached(a)?.lastSuccessAt;
      final bb = scheduler.cached(b)?.lastSuccessAt;
      if (aa == null) return bb == null ? 0 : 1;
      return bb == null ? -1 : bb.compareTo(aa);
    });
    return candidates;
  }

  void dispose() {
    _disposed = true;
    _selectionGeneration++;
    _signals.clear();
  }
}
