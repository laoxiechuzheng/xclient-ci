import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:fl_clash/xboard/probe/probe_scheduler.dart';
import 'package:fl_clash/xboard/probe/region_failover.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_profiles.dart';

const _url = 'https://probe.example';

class _Core extends Mock implements CoreController {}

class _Settings extends XcProbeSettingsNotifier {
  _Settings(this.initial);

  final XcProbeSettings initial;

  @override
  XcProbeSettings build() => initial;
}

class _Selection extends ProxiesAction {
  _Selection(this.changes, this.firstHop);

  final List<(String, String)> changes;
  final Completer<void>? firstHop;

  @override
  void build() {}

  @override
  void updateGroupsDebounce([Duration? duration]) {}

  @override
  Future<bool> changeProxy({
    required String groupName,
    required String proxyName,
    bool resetConnections = true,
  }) async {
    changes.add((groupName, proxyName));
    ref
        .read(profilesProvider.notifier)
        .updateProfile(
          1,
          (profile) => profile.copyWith(
            selectedMap: {...profile.selectedMap, groupName: proxyName},
          ),
        );
    if (changes.length == 1 && firstHop != null) {
      await firstHop!.future;
    }
    return true;
  }
}

class _Fixture {
  _Fixture(this.container, this.runtime, this.selection);

  final ProviderContainer container;
  final XcProbeRuntime runtime;
  final FailoverSelection selection;
  final candidateStarted = Completer<void>();
  final candidateResult = Completer<int>();
  final changes = <(String, String)>[];
  final probes = <String>[];

  Future<void> update({bool? enabled, bool? allowCrossRegion}) => container
      .read(xcProbeSettingsProvider.notifier)
      .update(enabled: enabled, allowCrossRegion: allowCrossRegion);

  Future<void> recover() => runtime.failover.confirmAndRecover(selection);

  void dispose() => container.dispose();
}

Future<_Fixture> _fixture({
  bool enabled = true,
  bool crossRegion = true,
  bool nested = false,
  bool extraCandidate = false,
  String candidate = 'US-new',
  Completer<void>? firstHop,
}) async {
  final definitions = [
    {'name': 'JP-old', 'type': 'ss'},
    {'name': candidate, 'type': 'ss'},
    if (extraCandidate) {'name': 'US-other', 'type': 'ss'},
  ];
  ProbeTarget target(int index) => ProbeTarget(
    name: definitions[index]['name']!,
    identity: sha256
        .convert(utf8.encode(jsonEncode(definitions[index])))
        .toString(),
    url: _url,
  );
  final core = _Core();
  late _Fixture fixture;
  when(
    () => core.getConfig(1),
  ).thenAnswer((_) async => {'proxies': definitions});
  when(() => core.getConnections()).thenAnswer((_) async => []);
  when(() => core.getDelay(_url, any(), const Duration(seconds: 5))).thenAnswer(
    (call) async {
      final name = call.positionalArguments[1] as String;
      fixture.probes.add(name);
      if (name == 'JP-old') return Delay(name: name, url: _url, value: -1);
      if (!fixture.candidateStarted.isCompleted) {
        fixture.candidateStarted.complete();
      }
      final result = await fixture.candidateResult.future;
      return Delay(name: name, url: _url, value: result);
    },
  );
  final groups = [
    Group(
      name: 'Main',
      type: GroupType.Selector,
      testUrl: _url,
      all: [
        const Proxy(name: 'JP-old', type: 'ss'),
        Proxy(
          name: nested ? 'Region' : candidate,
          type: nested ? 'Selector' : 'ss',
        ),
        if (extraCandidate) const Proxy(name: 'US-other', type: 'ss'),
      ],
    ),
    if (nested)
      Group(
        name: 'Region',
        type: GroupType.Selector,
        testUrl: _url,
        all: [Proxy(name: candidate, type: 'ss')],
      ),
  ];
  final holder = Provider<XcProbeRuntime>((ref) {
    final runtime = XcProbeRuntime(ref);
    ref.onDispose(runtime.dispose);
    return runtime;
  });
  final container = ProviderContainer(
    overrides: [
      safeModeProvider.overrideWithValue(false),
      coreHandlerProvider.overrideWithValue(core),
      profilesProvider.overrideWith(
        () => TestProfiles([
          const Profile(
            id: 1,
            autoUpdateDuration: Duration(days: 1),
            selectedMap: {'Main': 'JP-old'},
          ),
        ]),
      ),
      currentProfileProvider.overrideWith(
        (ref) => ref.watch(profilesProvider).single,
      ),
      coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
      isStartProvider.overrideWithValue(true),
      realTestUrlProvider(_url).overrideWithValue(_url),
      groupsProvider.overrideWithValue(groups),
      xcProbeSettingsProvider.overrideWith(
        () => _Settings(
          XcProbeSettings(enabled: enabled, allowCrossRegion: crossRegion),
        ),
      ),
      proxiesActionProvider.overrideWith(
        () => _Selection(fixture.changes, firstHop),
      ),
    ],
  );
  fixture = _Fixture(
    container,
    container.read(holder),
    FailoverSelection(
      group: 'Main',
      target: target(0),
      candidates: [
        for (var index = 1; index < definitions.length; index++) target(index),
      ],
    ),
  );
  fixture.runtime.start();
  await fixture.runtime.refreshTargets();
  return fixture;
}

Future<void> _drain() async {
  for (var index = 0; index < 12; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    AppPath.supportDirectory = () async =>
        throw const FileSystemException('fixture cache unavailable');
    AppPath.temporaryDirectory = () async => Directory.systemTemp;
    AppPath.cacheDirectory = () async => Directory.systemTemp;
    AppPath.downloadDirectory = () async => Directory.systemTemp;
    try {
      await appPath.rebind();
    } on FileSystemException {
      return;
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'turning cross-region off discards a successful foreign probe already in flight',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      final recovery = fixture.recover();
      await fixture.candidateStarted.future;
      await fixture.update(allowCrossRegion: false);
      fixture.candidateResult.complete(40);
      await recovery;
      expect(fixture.probes, ['JP-old', 'US-new']);
      expect(fixture.changes, isEmpty);
      expect(
        fixture.container.read(currentProfileProvider)?.selectedMap['Main'],
        'JP-old',
      );
    },
    skip: !BrandConfig.isBranded,
  );

  test(
    'settings cancellation prevents a later candidate from being issued',
    () async {
      final fixture = await _fixture(extraCandidate: true);
      addTearDown(fixture.dispose);
      final recovery = fixture.recover();
      await fixture.candidateStarted.future;
      await fixture.update(allowCrossRegion: false);
      fixture.candidateResult.complete(-1);
      await recovery;
      expect(fixture.probes, hasLength(2));
      expect(fixture.probes.first, 'JP-old');
      expect(fixture.changes, isEmpty);
    },
    skip: !BrandConfig.isBranded,
  );

  test(
    'disable then enable cannot resurrect the old in-flight recovery',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.dispose);
      final recovery = fixture.recover();
      await fixture.candidateStarted.future;
      await fixture.update(enabled: false);
      await fixture.update(enabled: true);
      fixture.candidateResult.complete(40);
      await recovery;
      expect(fixture.changes, isEmpty);
    },
    skip: !BrandConfig.isBranded,
  );

  test('unchanged settings keep a valid in-flight recovery', () async {
    final fixture = await _fixture();
    addTearDown(fixture.dispose);
    final recovery = fixture.recover();
    await fixture.candidateStarted.future;
    await fixture.update(enabled: true, allowCrossRegion: true);
    fixture.candidateResult.complete(40);
    await recovery;
    expect(fixture.changes, [('Main', 'US-new')]);
  }, skip: !BrandConfig.isBranded);

  test(
    'settings cancellation prevents later hops without claiming to undo the sent hop',
    () async {
      final firstHop = Completer<void>();
      final fixture = await _fixture(nested: true, firstHop: firstHop);
      addTearDown(fixture.dispose);
      final recovery = fixture.recover();
      await fixture.candidateStarted.future;
      fixture.candidateResult.complete(40);
      await _drain();
      expect(fixture.changes, [('Region', 'US-new')]);
      await fixture.update(allowCrossRegion: false);
      firstHop.complete();
      await recovery;
      expect(fixture.changes, [('Region', 'US-new')]);
      expect(
        fixture.container.read(currentProfileProvider)?.selectedMap['Main'],
        'JP-old',
      );
    },
    skip: !BrandConfig.isBranded,
  );

  test(
    'same-region recovery remains available with cross-region disabled',
    () async {
      final fixture = await _fixture(crossRegion: false, candidate: 'JP-new');
      addTearDown(fixture.dispose);
      final recovery = fixture.recover();
      await fixture.candidateStarted.future;
      fixture.candidateResult.complete(35);
      await recovery;
      expect(fixture.changes, [('Main', 'JP-new')]);
    },
    skip: !BrandConfig.isBranded,
  );

  test(
    'enabling recovery and cross-region allows a new foreign recovery',
    () async {
      final fixture = await _fixture(enabled: false, crossRegion: false);
      addTearDown(fixture.dispose);
      await fixture.recover();
      expect(fixture.probes, isEmpty);
      await fixture.update(enabled: true, allowCrossRegion: true);
      final recovery = fixture.recover();
      await fixture.candidateStarted.future;
      fixture.candidateResult.complete(35);
      await recovery;
      expect(fixture.changes, [('Main', 'US-new')]);
    },
    skip: !BrandConfig.isBranded,
  );
}
