import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/core/core.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';

import '../brand/brand_config.dart';
import 'probe_scheduler.dart';
import 'probe_routes.dart';
import 'region_failover.dart';

class XcProbeSettings {
  const XcProbeSettings({this.enabled = true, this.allowCrossRegion = false});

  final bool enabled;
  final bool allowCrossRegion;
}

final xcProbeSettingsProvider =
    NotifierProvider<XcProbeSettingsNotifier, XcProbeSettings>(
      XcProbeSettingsNotifier.new,
    );

class XcProbeSettingsNotifier extends Notifier<XcProbeSettings> {
  var _revision = 0;

  @override
  XcProbeSettings build() {
    unawaited(_restore());
    return const XcProbeSettings();
  }

  Future<void> _restore() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (ref.mounted && revision == _revision) {
        state = XcProbeSettings(
          enabled: prefs.getBool('xc.probe.failover') ?? true,
          allowCrossRegion: prefs.getBool('xc.probe.cross_region') ?? false,
        );
      }
    } on Object {
      return;
    }
  }

  Future<void> update({bool? enabled, bool? allowCrossRegion}) async {
    _revision++;
    state = XcProbeSettings(
      enabled: enabled ?? state.enabled,
      allowCrossRegion: allowCrossRegion ?? state.allowCrossRegion,
    );
    final snapshot = state;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('xc.probe.failover', snapshot.enabled);
      await prefs.setBool('xc.probe.cross_region', snapshot.allowCrossRegion);
    } on Object {
      return;
    }
  }
}

final xcProbeRuntimeProvider = Provider<XcProbeRuntime>((ref) {
  final runtime = XcProbeRuntime(ref);
  ref.onDispose(runtime.dispose);
  runtime.start();
  return runtime;
});

Map<String, String> _identities(List<dynamic> definitions) => {
  for (final definition in definitions.whereType<Map>())
    if (definition['name'] is String)
      definition['name'] as String: sha256
          .convert(utf8.encode(jsonEncode(definition)))
          .toString(),
};

class XcProbeRuntime with CoreEventListener {
  XcProbeRuntime(this.ref) {
    scheduler = ProbeScheduler(
      probe: (target) async =>
          (await ref
                  .read(coreHandlerProvider)
                  .getDelay(
                    target.url,
                    target.name,
                    const Duration(seconds: 5),
                  ))
              ?.value ??
          -1,
      onResult: _publish,
      save: (records) async {
        await _cache?.save(records);
      },
    );
    failover = RegionFailover(
      scheduler: scheduler,
      selections: _selections,
      changeProxy: _changeProxy,
      closeOldConnections: _closeOldConnections,
      notify: (message) => dialogs.showNotifier(message),
    );
  }

  final Ref ref;
  late final ProbeScheduler scheduler;
  late final RegionFailover failover;
  ProbeCacheFile? _cache;
  final Map<String, ProbeTarget> _byName = {};
  final Map<String, Set<String>> _urlsByName = {};
  Map<String, String> _identityByName = {};
  String? _identityProfile;
  int _refreshGeneration = 0;
  int _intentRevision = 0;
  bool _disposed = false;
  bool _switching = false;
  bool _observingTraffic = false;
  Set<String> _connectionIds = {};
  Timer? _trafficTimer;
  Future<void>? _refreshing;
  bool _refreshAgain = false;
  List<Group>? _snapshotGroups;
  Map<String, String>? _snapshotSelected;
  List<FailoverSelection> _snapshotSelections = [];
  int _targetsVersion = 0;
  int _snapshotTargetsVersion = -1;

  void start() {
    if (!BrandConfig.isBranded || ref.read(safeModeProvider)) {
      return;
    }
    coreEventManager.addListener(this);
    ref.listen(
      coreStatusProvider,
      (_, _) => _syncRunning(),
      fireImmediately: true,
    );
    ref.listen(isStartProvider, (_, _) => _syncRunning());
    ref.listen(groupsProvider, (_, _) => unawaited(refreshTargets()));
    ref.listen(currentProfileProvider, (previous, next) {
      if (previous?.selectedMap != next?.selectedMap && !_switching) {
        failover.selectionChanged();
      }
      if (previous?.id != next?.id ||
          previous?.lastUpdateDate != next?.lastUpdateDate) {
        _refreshGeneration++;
        _identityProfile = null;
        userSelectionChanged();
        unawaited(refreshTargets());
      }
    });
    ref.listen(xcProbeSettingsProvider, (previous, next) {
      if (previous != null &&
          (previous.enabled != next.enabled ||
              previous.allowCrossRegion != next.allowCrossRegion)) {
        userSelectionChanged();
      }
      failover.enabled = next.enabled;
      failover.allowCrossRegion = next.allowCrossRegion;
    }, fireImmediately: true);
    _trafficTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => unawaited(_observeTraffic()),
    );
    unawaited(_restoreCache());
    unawaited(refreshTargets());
  }

  void userSelectionChanged() {
    _intentRevision++;
    failover.selectionChanged();
  }

  void _syncRunning() {
    if (_disposed) {
      return;
    }
    scheduler.setRunning(
      ref.read(coreStatusProvider) == CoreStatus.connected &&
          ref.read(isStartProvider) &&
          !ref.read(safeModeProvider),
    );
    if (!scheduler.running) {
      _connectionIds.clear();
      userSelectionChanged();
    }
    if (scheduler.running) {
      unawaited(refreshTargets());
    }
  }

  Future<void> _restoreCache() async {
    try {
      final home = await appPath.homeDirPath;
      if (_disposed) {
        return;
      }
      _cache = ProbeCacheFile(
        File(path.join(home, 'xclient', 'probe-cache.json')),
      );
      final records = await _cache!.load();
      if (!_disposed) {
        scheduler.restore(records);
      }
    } on Object {
      return;
    }
  }

  void _publish(ProbeRecord record) {
    if (_disposed ||
        _byName[record.target.name]?.identity != record.target.identity) {
      return;
    }
    ref.read(delayDataSourceProvider.notifier).setDelays([
      Delay(
        name: record.target.name,
        url: record.target.url,
        value: record.latency,
      ),
    ]);
  }

  Future<void> refreshTargets() {
    if (_disposed || !BrandConfig.isBranded || ref.read(safeModeProvider)) {
      return Future<void>.value();
    }
    _refreshAgain = true;
    return _refreshing ??= _refreshLoop().whenComplete(
      () => _refreshing = null,
    );
  }

  Future<void> _refreshLoop() async {
    while (_refreshAgain && !_disposed) {
      _refreshAgain = false;
      await _refreshTargets();
    }
  }

  Future<void> _refreshTargets() async {
    final generation = ++_refreshGeneration;
    final profile = ref.read(currentProfileProvider);
    if (profile == null) {
      _byName.clear();
      _urlsByName.clear();
      _targetsVersion++;
      scheduler.setTargets([]);
      unawaited(_cache?.save([]) ?? Future<void>.value());
      return;
    }
    final profileKey =
        '${profile.id}:${profile.lastUpdateDate?.millisecondsSinceEpoch}';
    if (_identityProfile != profileKey) {
      try {
        final config = await ref
            .read(coreHandlerProvider)
            .getConfig(profile.id);
        final definitions = config['proxies'];
        if (definitions is! List) {
          return;
        }
        final identities = await compute(_identities, definitions);
        if (_disposed ||
            generation != _refreshGeneration ||
            ref.read(currentProfileProvider)?.id != profile.id) {
          return;
        }
        _identityByName = identities;
        _identityProfile = profileKey;
      } on Object {
        return;
      }
    }
    if (_disposed || generation != _refreshGeneration) {
      return;
    }
    final groups = ref.read(groupsProvider);
    final groupNames = groups.map((group) => group.name).toSet();
    final names = <String, ProbeTarget>{};
    final urls = <String, Set<String>>{};
    for (final group in groups) {
      final url = ref.read(realTestUrlProvider(group.testUrl));
      for (final proxy in group.all) {
        if (groupNames.contains(proxy.name) ||
            _directTypes.contains(proxy.type.toLowerCase())) {
          continue;
        }
        final identity = _identityByName[proxy.name];
        if (identity == null) {
          continue;
        }
        names.putIfAbsent(
          proxy.name,
          () => ProbeTarget(name: proxy.name, identity: identity, url: url),
        );
        (urls[proxy.name] ??= {}).add(url);
      }
    }
    for (final entry in _byName.entries) {
      if (names[entry.key] != entry.value) {
        ref.read(delayDataSourceProvider.notifier).setDelays([
          for (final url in _urlsByName[entry.key] ?? {entry.value.url})
            Delay(name: entry.key, url: url),
        ]);
      }
    }
    _byName
      ..clear()
      ..addAll(names);
    _urlsByName
      ..clear()
      ..addAll(urls);
    _targetsVersion++;
    scheduler.setTargets(names.values);
  }

  static const _directTypes = {
    'direct',
    'reject',
    'reject-drop',
    'pass',
    'compatible',
    'dns',
    'selector',
    'urltest',
    'fallback',
    'loadbalance',
  };

  Future<void> requestCached(
    Iterable<({String name, String url})> requests,
  ) async {
    await refreshTargets();
    if (_disposed) {
      return;
    }
    final targets = <ProbeTarget>[];
    for (final request in requests) {
      final known = _byName[request.name];
      if (known == null) {
        continue;
      }
      final target = ProbeTarget(
        name: known.name,
        identity: known.identity,
        url: request.url,
      );
      (_urlsByName[target.name] ??= {}).add(target.url);
      final cached = scheduler.cached(target);
      if (cached != null && cached.target.url == target.url) {
        _publish(cached);
      }
      targets.add(target);
    }
    scheduler.request(targets);
  }

  List<FailoverSelection> _selections() {
    if (_disposed) {
      return [];
    }
    final groups = ref.read(groupsProvider);
    final selected = ref.read(currentProfileProvider)?.selectedMap ?? {};
    if (identical(groups, _snapshotGroups) &&
        identical(selected, _snapshotSelected) &&
        _targetsVersion == _snapshotTargetsVersion) {
      return _snapshotSelections;
    }
    final routes = ProbeRoutes(
      groups: groups,
      selected: selected,
      targets: _byName,
    );
    final results = <FailoverSelection>[];
    for (final selection in routes.selections()) {
      final current = _currentBindingGroup(
        routes,
        selection.group,
        selection.target.name,
      );
      if (current == null) continue;
      final bindings = _candidateBindings(routes, selection.group);
      results.add(
        FailoverSelection(
          group: selection.group,
          target: _targetAtBinding(current, selection.target),
          candidates: [
            for (final candidate in selection.candidates)
              if (bindings[candidate.name] case final binding?)
                _targetAtBinding(binding, candidate),
          ],
        ),
      );
    }
    _snapshotGroups = groups;
    _snapshotSelected = selected;
    _snapshotTargetsVersion = _targetsVersion;
    return _snapshotSelections = results;
  }

  Group? _currentBindingGroup(
    ProbeRoutes routes,
    String root,
    String targetName,
  ) {
    var group = routes.groups[root];
    final visited = <String>{};
    while (group != null && visited.add(group.name)) {
      if (group.type != GroupType.Selector && !group.type.isComputedSelected) {
        return null;
      }
      final selected = group.getCurrentSelectedName(
        routes.selected[group.name] ?? '',
      );
      if (selected == targetName) return group;
      group = routes.groups[selected];
    }
    return null;
  }

  Map<String, Group> _candidateBindings(ProbeRoutes routes, String root) {
    final bindings = <String, Group>{};
    final visited = <String>{};
    void visit(Group group) {
      if (!visited.add(group.name) ||
          (group.type != GroupType.Selector &&
              !group.type.isComputedSelected)) {
        return;
      }
      for (final proxy in group.all) {
        final nested = routes.groups[proxy.name];
        if (nested != null) {
          visit(nested);
        } else {
          bindings.putIfAbsent(proxy.name, () => group);
        }
      }
    }

    final group = routes.groups[root];
    if (group != null) visit(group);
    return bindings;
  }

  ProbeTarget _targetAtBinding(Group group, ProbeTarget target) {
    return ProbeTarget(
      name: target.name,
      identity: target.identity,
      url: ref.read(realTestUrlProvider(group.testUrl)),
    );
  }

  Future<bool> _changeProxy(String group, ProbeTarget target) async {
    if (_disposed || !scheduler.running) {
      return false;
    }
    final routes = ProbeRoutes(
      groups: ref.read(groupsProvider),
      selected: ref.read(currentProfileProvider)?.selectedMap ?? {},
      targets: _byName,
    );
    final route = routes.pathTo(group, target.name);
    if (route == null || route.isEmpty) {
      return false;
    }
    final binding = routes.groups[route.last.group];
    if (binding == null ||
        ref.read(realTestUrlProvider(binding.testUrl)) != target.url) {
      return false;
    }
    final revision = _intentRevision;
    final appliedHops = <ProbeRouteHop>[];
    Future<void> rollback() async {
      for (final hop in appliedHops.reversed) {
        if (_disposed || !scheduler.running || revision != _intentRevision) {
          return;
        }
        await ref
            .read(proxiesActionProvider.notifier)
            .changeProxy(
              groupName: hop.group,
              proxyName: hop.name,
              resetConnections: false,
            );
      }
    }

    _switching = true;
    try {
      for (final hop in route.reversed) {
        if (_disposed || !scheduler.running || revision != _intentRevision) {
          return false;
        }
        final applied = await ref
            .read(proxiesActionProvider.notifier)
            .changeProxy(
              groupName: hop.group,
              proxyName: hop.name,
              resetConnections: false,
            );
        if (!applied) {
          await rollback();
          return false;
        }
        final previous =
            routes.groups[hop.group]?.getCurrentSelectedName(
              routes.selected[hop.group] ?? '',
            ) ??
            '';
        if (previous != hop.name) {
          appliedHops.add((group: hop.group, name: previous));
        }
      }
      if (_disposed || revision != _intentRevision) {
        return false;
      }
      ref.read(proxiesActionProvider.notifier).updateGroupsDebounce();
      final selected = ref.read(currentProfileProvider)?.selectedMap ?? {};
      return route.every((hop) => selected[hop.group] == hop.name);
    } finally {
      _switching = false;
    }
  }

  Future<void> _closeOldConnections(String name) async {
    final core = ref.read(coreHandlerProvider);
    final connections = await core.getConnections();
    for (final connection in connections.where(
      (connection) => connection.chains.contains(name),
    )) {
      if (_disposed || !scheduler.running) {
        return;
      }
      await core.closeConnection(connection.id);
    }
  }

  Future<void> _observeTraffic() async {
    if (_disposed ||
        !scheduler.running ||
        !failover.enabled ||
        _observingTraffic) {
      return;
    }
    _observingTraffic = true;
    try {
      final connections = await ref.read(coreHandlerProvider).getConnections();
      if (_disposed || !scheduler.running) {
        return;
      }
      for (final selection in _selections()) {
        final routed = connections.where(
          (connection) => connection.chains.contains(selection.target.name),
        );
        failover.observeTraffic(
          selection,
          totalBytes: routed.fold<int>(
            0,
            (total, connection) =>
                total + connection.upload + connection.download,
          ),
          activeConnections: routed.length,
          hasNewConnections: routed.any(
            (connection) => !_connectionIds.contains(connection.id),
          ),
        );
      }
      _connectionIds = connections.map((connection) => connection.id).toSet();
    } on Object {
      return;
    } finally {
      _observingTraffic = false;
    }
  }

  @override
  void onLog(Log log) => failover.observeLog(log.payload);

  void dispose() {
    _disposed = true;
    _refreshGeneration++;
    coreEventManager.removeListener(this);
    _trafficTimer?.cancel();
    scheduler.dispose();
    failover.dispose();
  }
}
