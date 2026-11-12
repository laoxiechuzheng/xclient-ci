import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

class ProbeTarget {
  const ProbeTarget({
    required this.name,
    required this.identity,
    required this.url,
  });

  final String name;
  final String identity;
  final String url;

  String get key => '$name\u0000$identity';

  @override
  bool operator ==(Object other) => other is ProbeTarget && key == other.key;

  @override
  int get hashCode => key.hashCode;
}

class ProbeRecord {
  const ProbeRecord({
    required this.target,
    required this.latency,
    required this.checkedAt,
    required this.nextProbeAt,
    this.lastSuccessAt,
  });

  final ProbeTarget target;
  final int latency;
  final DateTime checkedAt;
  final DateTime nextProbeAt;
  final DateTime? lastSuccessAt;

  Map<String, Object?> toJson() => {
    'name': target.name,
    'identity': target.identity,
    'url': target.url,
    'latency': latency,
    'checked_at': checkedAt.millisecondsSinceEpoch,
    'next_probe_at': nextProbeAt.millisecondsSinceEpoch,
    'last_success_at': lastSuccessAt?.millisecondsSinceEpoch,
  };

  factory ProbeRecord.fromJson(Map<String, dynamic> json) => ProbeRecord(
    target: ProbeTarget(
      name: json['name'] as String,
      identity: json['identity'] as String,
      url: json['url'] as String,
    ),
    latency: json['latency'] as int,
    checkedAt: DateTime.fromMillisecondsSinceEpoch(json['checked_at'] as int),
    nextProbeAt: DateTime.fromMillisecondsSinceEpoch(
      json['next_probe_at'] as int,
    ),
    lastSuccessAt: json['last_success_at'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['last_success_at'] as int),
  );
}

class ProbeCacheFile {
  ProbeCacheFile(this.file);

  final File file;
  Future<void> _writes = Future<void>.value();

  Future<List<ProbeRecord>> load() async {
    try {
      if (!await file.exists() || await file.length() > 4 * 1024 * 1024) {
        return [];
      }
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return [];
      final records = <ProbeRecord>[];
      for (final value in data.take(10000)) {
        try {
          records.add(
            ProbeRecord.fromJson(Map<String, dynamic>.from(value as Map)),
          );
        } on Object {
          continue;
        }
      }
      return records;
    } on Object {
      return [];
    }
  }

  Future<void> save(Iterable<ProbeRecord> records) {
    final data = jsonEncode(
      records.take(10000).map((record) => record.toJson()).toList(),
    );
    _writes = _writes
        .then((_) async {
          await file.parent.create(recursive: true);
          final pending = File('${file.path}.pending');
          await pending.writeAsString(data, flush: true);
          await pending.rename(file.path);
        })
        .catchError((Object _) {});
    return _writes;
  }
}

typedef EmergencyProbe = Future<int?> Function(ProbeTarget target);

class ProbeScheduler {
  ProbeScheduler({
    required this.probe,
    DateTime Function()? now,
    int Function(int)? randomInt,
    Iterable<ProbeRecord> initialRecords = const [],
    this.onResult,
    this.save,
  }) : now = now ?? DateTime.now,
       randomInt = randomInt ?? Random.secure().nextInt,
       _records = {
         for (final record in initialRecords) record.target.key: record,
       };

  final Future<int> Function(ProbeTarget target) probe;
  final DateTime Function() now;
  final int Function(int) randomInt;
  final void Function(ProbeRecord record)? onResult;
  final Future<void> Function(Iterable<ProbeRecord>)? save;
  final Map<String, ProbeRecord> _records;
  final LinkedHashMap<String, ProbeTarget> _targets = LinkedHashMap();
  Timer? _timer;
  Future<void>? _normalJob;
  bool _running = false;
  bool _disposed = false;
  bool _emergency = false;
  int _generation = 0;
  DateTime? _nextGlobal;

  bool get running => _running && !_disposed;
  Iterable<ProbeRecord> get records => _records.values;

  ProbeRecord? cached(ProbeTarget target) => _records[target.key];

  void restore(Iterable<ProbeRecord> records) {
    for (final record in records) {
      final existing = _records[record.target.key];
      if (existing == null || existing.checkedAt.isBefore(record.checkedAt)) {
        _records[record.target.key] = record;
        if (_targets.containsKey(record.target.key)) onResult?.call(record);
      }
    }
    _schedule();
  }

  void setTargets(Iterable<ProbeTarget> targets) {
    _targets
      ..clear()
      ..addEntries(targets.map((target) => MapEntry(target.key, target)));
    _records.removeWhere((key, _) => !_targets.containsKey(key));
    for (final target in _targets.values) {
      final record = cached(target);
      if (record != null) onResult?.call(record);
    }
    _schedule();
  }

  void setRunning(bool value) {
    if (_running == value || _disposed) return;
    _running = value;
    _generation++;
    _timer?.cancel();
    _timer = null;
    if (value) {
      _nextGlobal = now().add(_gap());
      _schedule();
    }
  }

  void request(Iterable<ProbeTarget> targets) {
    if (_disposed) return;
    for (final target in targets) {
      _targets.putIfAbsent(target.key, () => target);
    }
    _schedule();
  }

  Duration _gap() => Duration(milliseconds: 2000 + randomInt(6001));

  DateTime _eligible(ProbeTarget target) {
    final record = cached(target);
    var date = record?.nextProbeAt ?? now();
    final global = _nextGlobal;
    if (global != null && date.isBefore(global)) date = global;
    return date;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!running || _normalJob != null || _emergency || _targets.isEmpty) {
      return;
    }
    DateTime? earliest;
    for (final target in _targets.values) {
      final eligible = _eligible(target);
      if (earliest == null || eligible.isBefore(earliest)) earliest = eligible;
    }
    if (earliest == null) return;
    final delay = earliest.difference(now());
    _timer = Timer(delay.isNegative ? Duration.zero : delay, () {
      _timer = null;
      _normalJob = _runNext();
      unawaited(
        _normalJob!.whenComplete(() {
          _normalJob = null;
          _schedule();
        }),
      );
    });
  }

  Future<void> _runNext() async {
    if (!running || _emergency) return;
    final date = now();
    ProbeTarget? next;
    for (final target in _targets.values) {
      if (!_eligible(target).isAfter(date)) {
        next = target;
        break;
      }
    }
    if (next == null) return;
    await _execute(next);
    _nextGlobal = now().add(_gap());
  }

  Future<int?> _execute(ProbeTarget target) async {
    if (!running) return null;
    final generation = _generation;
    int latency;
    try {
      latency = await probe(target).timeout(const Duration(seconds: 5));
      if (latency <= 0) latency = -1;
    } on Object {
      latency = -1;
    }
    if (!running || generation != _generation) return null;
    final date = now();
    final record = ProbeRecord(
      target: target,
      latency: latency,
      checkedAt: date,
      nextProbeAt: date.add(
        Duration(milliseconds: 1200000 + randomInt(1200001)),
      ),
      lastSuccessAt: latency > 0 ? date : cached(target)?.lastSuccessAt,
    );
    _records[target.key] = record;
    onResult?.call(record);
    final persist = save;
    if (persist != null) unawaited(persist(_records.values.toList()));
    return latency;
  }

  Future<T?> emergency<T>(
    Future<T> Function(EmergencyProbe probe) action,
  ) async {
    if (!running || _emergency) return null;
    _emergency = true;
    _timer?.cancel();
    _timer = null;
    var active = 0;
    final waiters = Queue<Completer<void>>();
    Future<int?> boundedProbe(ProbeTarget target) async {
      if (active >= 2) {
        final waiter = Completer<void>();
        waiters.add(waiter);
        await waiter.future;
      }
      active++;
      try {
        return await _execute(target);
      } finally {
        active--;
        if (waiters.isNotEmpty) waiters.removeFirst().complete();
      }
    }

    try {
      await _normalJob;
      if (!running) return null;
      return await action(boundedProbe);
    } finally {
      _emergency = false;
      _nextGlobal = now().add(_gap());
      _schedule();
    }
  }

  void dispose() {
    _disposed = true;
    _running = false;
    _generation++;
    _timer?.cancel();
    _timer = null;
  }
}
