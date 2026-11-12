import '../../brand/brand_config.dart';

class EndpointHealth {
  final ApiEndpointSpec spec;
  int consecutiveFailures = 0;

  double? latencyMs;
  DateTime? lastSuccess;
  DateTime? downUntil;

  EndpointHealth(this.spec);

  String get url => spec.url;

  bool isDown(DateTime now) => downUntil != null && now.isBefore(downUntil!);

  double get score => spec.weight / (1 + (latencyMs ?? 300) / 300);
}

typedef PoolEvent = void Function();

/// Sticky until two consecutive connect, TLS or server failures.
class EndpointPool {
  static const failuresToSwitch = 2;
  static const downFor = Duration(minutes: 2);

  final DateTime Function() _now;

  PoolEvent? onFailover;

  PoolEvent? onExhausted;

  List<EndpointHealth> _endpoints = [];
  int _current = 0;

  EndpointPool({
    List<ApiEndpointSpec> endpoints = const [],
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    replace(endpoints);
  }

  List<EndpointHealth> get endpoints => List.unmodifiable(_endpoints);

  bool get isEmpty => _endpoints.isEmpty;

  Set<String> get hosts => {
    for (final endpoint in _endpoints)
      if (Uri.tryParse(endpoint.url)?.host case final host?)
        if (host.isNotEmpty) host,
  };

  /// Preserves surviving endpoint health and the current selection.
  void replace(List<ApiEndpointSpec> specs) {
    final previous = {for (final e in _endpoints) e.url: e};
    final currentUrl = _endpoints.isEmpty ? null : current?.url;
    final seen = <String>{};
    final next = <EndpointHealth>[];
    for (final spec in specs) {
      if (!seen.add(spec.url)) continue;
      final old = previous[spec.url];
      final health = EndpointHealth(spec);
      if (old != null) {
        health
          ..consecutiveFailures = old.consecutiveFailures
          ..latencyMs = old.latencyMs
          ..lastSuccess = old.lastSuccess
          ..downUntil = old.downUntil;
      }
      next.add(health);
    }
    _endpoints = _ranked(next);
    final keep = _endpoints.indexWhere((e) => e.url == currentUrl);
    _current = keep == -1 ? _firstUp() : keep;
  }

  List<EndpointHealth> _ranked(List<EndpointHealth> list) {
    final indexed = list.indexed.toList()
      ..sort((a, b) {
        final byScore = b.$2.score.compareTo(a.$2.score);
        return byScore != 0 ? byScore : a.$1.compareTo(b.$1);
      });
    return [for (final (_, e) in indexed) e];
  }

  int _firstUp() {
    final now = _now();
    final index = _endpoints.indexWhere((e) => !e.isDown(now));
    return index == -1 ? 0 : index;
  }

  EndpointHealth? get current =>
      _endpoints.isEmpty ? null : _endpoints[_current];

  bool get allDown {
    final now = _now();
    return _endpoints.every((e) => e.isDown(now));
  }

  List<EndpointHealth> attemptOrder() {
    if (_endpoints.isEmpty) return const [];
    final now = _now();
    final rotated = [
      ..._endpoints.sublist(_current),
      ..._endpoints.sublist(0, _current),
    ];
    return [
      ...rotated.where((e) => !e.isDown(now)),
      ...rotated.where((e) => e.isDown(now)),
    ];
  }

  void reportSuccess(String url, Duration latency) {
    final endpoint = _find(url);
    if (endpoint == null) return;
    final ms = latency.inMicroseconds / 1000;
    endpoint
      ..consecutiveFailures = 0
      ..downUntil = null
      ..lastSuccess = _now()
      ..latencyMs = endpoint.latencyMs == null
          ? ms
          : endpoint.latencyMs! * 0.7 + ms * 0.3;
    if (current?.isDown(_now()) ?? false) {
      _current = _endpoints.indexOf(endpoint);
    }
  }

  bool reportFailure(String url) {
    final endpoint = _find(url);
    if (endpoint == null) return false;
    endpoint.consecutiveFailures++;
    if (endpoint.consecutiveFailures < failuresToSwitch) return false;
    endpoint.downUntil = _now().add(downFor);
    if (current?.url != url) return false;
    final now = _now();
    final next = _nextUpAfter(_current, now);
    if (next == null) {
      onExhausted?.call();
      return false;
    }
    _current = next;
    onFailover?.call();
    return true;
  }

  int? _nextUpAfter(int index, DateTime now) {
    for (var step = 1; step < _endpoints.length; step++) {
      final candidate = (index + step) % _endpoints.length;
      if (!_endpoints[candidate].isDown(now)) return candidate;
    }
    return null;
  }

  EndpointHealth? _find(String url) {
    for (final endpoint in _endpoints) {
      if (endpoint.url == url) return endpoint;
    }
    return null;
  }

  void rerank() => replace([for (final e in _endpoints) e.spec]);
}
