import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../core/sync/update_docs.dart';
import 'version.dart';

enum UpdateMode {
  none,

  /// Dismissible notices are throttled per version to once per 24h.
  notify,

  /// force or min_supported initiates updating and keeps connections gated until completion.
  force,
}

class UpdateDecision {
  final UpdateMode mode;

  final String latest;
  final String notes;

  final bool belowMinSupported;
  final XcPolicy? policy;

  const UpdateDecision({
    required this.mode,
    this.latest = '',
    this.notes = '',
    this.belowMinSupported = false,
    this.policy,
  });

  static const none = UpdateDecision(mode: UpdateMode.none);

  bool get isForced => mode == UpdateMode.force;

  bool get hasUpdate => mode != UpdateMode.none;
}

/// Malformed policy versions count as absent, preventing an impossible forced update.
UpdateDecision decideUpdate(XcPolicy? policy, AppVersion current) {
  if (policy == null) return UpdateDecision.none;
  final latest = AppVersion.tryParse(policy.latest);
  final minSupported = AppVersion.tryParse(policy.minSupported);
  final newer = latest != null && latest.compareTo(current) > 0;
  final below = minSupported != null && current.compareTo(minSupported) < 0;
  final mode = (policy.force && newer) || below
      ? UpdateMode.force
      : newer
      ? UpdateMode.notify
      : UpdateMode.none;
  return UpdateDecision(
    mode: mode,
    latest: policy.latest,
    notes: policy.notes,
    belowMinSupported: below && !(policy.force && newer),
    policy: policy,
  );
}

abstract class UpdateNoticeStore {
  Future<Map<String, int>> read();

  Future<void> write(Map<String, int> value);
}

class PrefsUpdateNoticeStore implements UpdateNoticeStore {
  static const prefsKey = 'xc.update.notified';

  const PrefsUpdateNoticeStore();

  @override
  Future<Map<String, int>> read() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(prefsKey);
      if (raw == null) return {};
      final json = jsonDecode(raw);
      if (json is! Map) return {};
      return {
        for (final MapEntry(:key, :value) in json.entries)
          if (value is int) '$key': value,
      };
    } catch (_) {
      return {};
    }
  }

  @override
  Future<void> write(Map<String, int> value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(prefsKey, jsonEncode(value));
  }
}

class MemoryUpdateNoticeStore implements UpdateNoticeStore {
  Map<String, int> value = {};

  @override
  Future<Map<String, int>> read() async => {...value};

  @override
  Future<void> write(Map<String, int> value) async => this.value = {...value};
}

class UpdateNoticeThrottle {
  static const interval = Duration(hours: 24);

  final UpdateNoticeStore store;
  final DateTime Function() now;

  UpdateNoticeThrottle(this.store, {DateTime Function()? now})
    : now = now ?? DateTime.now;

  int get _nowSeconds => now().millisecondsSinceEpoch ~/ 1000;

  Future<bool> shouldNotify(String version) async {
    final last = (await store.read())[version];
    if (last == null) return true;
    final elapsed = _nowSeconds - last;
    // A clock set back makes elapsed negative; remind rather than go quiet.
    return elapsed < 0 || elapsed >= interval.inSeconds;
  }

  Future<void> markNotified(String version) async {
    final map = await store.read();
    map[version] = _nowSeconds;
    final keep = map.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    await store.write({
      for (final entry in keep.take(5)) entry.key: entry.value,
    });
  }
}
