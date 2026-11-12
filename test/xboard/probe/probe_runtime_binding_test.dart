import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/lib.dart';
import 'package:fl_clash/core/event.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:fl_clash/xboard/probe/probe_scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_profiles.dart';

const _primary = 'https://primary.example';
const _binding = 'https://binding.example';
const _definitions = [
  {'name': 'JP-old', 'type': 'ss'},
  {'name': 'JP-new', 'type': 'ss'},
];

class _Core extends Mock implements CoreController {}

class _BindingSelection extends ProxiesAction {
  _BindingSelection(this.alive, this.groups);

  final Map<(String, String), bool> alive;
  final Map<String, Group> groups;

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
    final group = groups[groupName]!;
    if (group.type.isComputedSelected &&
        alive[(proxyName, group.testUrl!)] != true) {
      return false;
    }
    ref
        .read(profilesProvider.notifier)
        .updateProfile(
          1,
          (profile) => profile.copyWith(
            selectedMap: {...profile.selectedMap, groupName: proxyName},
          ),
        );
    return true;
  }
}

Future<
  ({
    ProviderContainer container,
    XcProbeRuntime runtime,
    List<(String, String)> calls,
  })
>
_fixture({
  List<Group>? groups,
  Map<String, String>? selected,
  bool primaryOldHealthy = false,
}) async {
  final core = _Core();
  final calls = <(String, String)>[];
  final alive = <(String, String), bool>{('JP-new', _binding): false};
  when(
    () => core.getConfig(1),
  ).thenAnswer((_) async => {'proxies': _definitions});
  when(() => core.getConnections()).thenAnswer((_) async => []);
  when(
    () => core.getDelay(any(), any(), const Duration(seconds: 5)),
  ).thenAnswer((call) async {
    final url = call.positionalArguments[0] as String;
    final name = call.positionalArguments[1] as String;
    calls.add((name, url));
    final value = name == 'JP-new' || (primaryOldHealthy && url == _primary)
        ? 40
        : -1;
    alive[(name, url)] = value > 0;
    return Delay(name: name, url: url, value: value);
  });
  final holder = Provider<XcProbeRuntime>((ref) {
    final runtime = XcProbeRuntime(ref);
    ref.onDispose(runtime.dispose);
    return runtime;
  });
  final actualGroups =
      groups ??
      [
        const Group(
          name: 'Primary',
          type: GroupType.LoadBalance,
          testUrl: _primary,
          all: [
            Proxy(name: 'JP-old', type: 'ss'),
            Proxy(name: 'JP-new', type: 'ss'),
          ],
        ),
        const Group(
          name: 'Binding',
          type: GroupType.Fallback,
          testUrl: _binding,
          now: 'JP-old',
          all: [
            Proxy(name: 'JP-old', type: 'ss'),
            Proxy(name: 'JP-new', type: 'ss'),
          ],
        ),
      ];
  final container = ProviderContainer(
    overrides: [
      coreHandlerProvider.overrideWithValue(core),
      profilesProvider.overrideWith(
        () => TestProfiles([
          Profile(
            id: 1,
            autoUpdateDuration: const Duration(days: 1),
            selectedMap: selected ?? {'Binding': 'JP-old'},
          ),
        ]),
      ),
      currentProfileProvider.overrideWith(
        (ref) => ref.watch(profilesProvider).single,
      ),
      coreStatusProvider.overrideWithBuild((_, _) => CoreStatus.connected),
      isStartProvider.overrideWithValue(true),
      realTestUrlProvider(_primary).overrideWithValue(_primary),
      realTestUrlProvider(_binding).overrideWithValue(_binding),
      groupsProvider.overrideWithValue(actualGroups),
      proxiesActionProvider.overrideWith(
        () => _BindingSelection(alive, {
          for (final group in actualGroups) group.name: group,
        }),
      ),
    ],
  );
  final runtime = container.read(holder);
  await runtime.refreshTargets();
  return (container: container, runtime: runtime, calls: calls);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'NoView native Service log reaches Core owner and the real same-region recovery',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.container.dispose);
      final bridge = CoreLib.scoped(Service(), confirmedStops: true);
      addTearDown(bridge.close);
      coreEventManager.addListener(fixture.runtime);
      addTearDown(() => coreEventManager.removeListener(fixture.runtime));
      fixture.runtime.scheduler.setRunning(true);
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      const codec = StandardMethodCodec();
      for (var index = 0; index < 3; index++) {
        final payload = json.encode(
          const CoreMethodCall(
            method: CoreMethod.message,
            arguments: [
              {
                'type': 'log',
                'data': {
                  'LogLevel': 'warning',
                  'Payload': 'dial JP-old error: timeout',
                },
              },
            ],
          ).toJson(),
        );
        await messenger.handlePlatformMessage(
          '$packageName/service',
          codec.encodeMethodCall(MethodCall('event', utf8.encode(payload))),
          null,
        );
      }
      for (var index = 0; index < 40; index++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (fixture.container
                .read(currentProfileProvider)
                ?.selectedMap['Binding'] ==
            'JP-new') {
          break;
        }
      }
      expect(fixture.calls, [('JP-old', _binding), ('JP-new', _binding)]);
      expect(
        fixture.container.read(currentProfileProvider)?.selectedMap['Binding'],
        'JP-new',
      );
    },
    skip: !BrandConfig.isBranded,
  );
  test(
    'shared leaves confirm the current selected branch before choosing a candidate path',
    () async {
      final fixture = await _fixture(
        primaryOldHealthy: true,
        selected: {'Main': 'Binding', 'A': 'JP-old', 'Binding': 'JP-old'},
        groups: [
          const Group(
            name: 'Main',
            type: GroupType.Selector,
            all: [
              Proxy(name: 'A', type: 'Fallback'),
              Proxy(name: 'Binding', type: 'Fallback'),
            ],
          ),
          const Group(
            name: 'A',
            type: GroupType.Fallback,
            testUrl: _primary,
            now: 'JP-old',
            all: [
              Proxy(name: 'JP-old', type: 'ss'),
              Proxy(name: 'JP-new', type: 'ss'),
            ],
          ),
          const Group(
            name: 'Binding',
            type: GroupType.Fallback,
            testUrl: _binding,
            now: 'JP-old',
            all: [
              Proxy(name: 'JP-old', type: 'ss'),
              Proxy(name: 'JP-new', type: 'ss'),
            ],
          ),
        ],
      );
      addTearDown(fixture.container.dispose);
      fixture.runtime.scheduler.setRunning(true);
      for (var index = 0; index < 3; index++) {
        fixture.runtime.failover.observeLog('dial JP-old error: timeout');
      }
      for (var index = 0; index < 20; index++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (fixture.container
                .read(currentProfileProvider)
                ?.selectedMap['Main'] ==
            'A') {
          break;
        }
      }
      expect(fixture.calls, [('JP-old', _binding), ('JP-new', _primary)]);
      expect(
        fixture.container.read(currentProfileProvider)?.selectedMap['Main'],
        'A',
      );
    },
    skip: !BrandConfig.isBranded,
  );
  test(
    'C22 confirms the binding URL before selecting a previously dead fallback member',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.container.dispose);
      fixture.runtime.scheduler.setRunning(true);
      for (var index = 0; index < 3; index++) {
        fixture.runtime.failover.observeLog('dial JP-old error: timeout');
      }
      for (var index = 0; index < 20; index++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
        if (fixture.container
                .read(currentProfileProvider)
                ?.selectedMap['Binding'] ==
            'JP-new') {
          break;
        }
      }
      expect(fixture.calls, [('JP-old', _binding), ('JP-new', _binding)]);
      expect(
        fixture.container.read(currentProfileProvider)?.selectedMap['Binding'],
        'JP-new',
      );
    },
    skip: !BrandConfig.isBranded,
  );

  test(
    'an actual primary URL result is never published as binding URL success',
    () async {
      final fixture = await _fixture();
      addTearDown(fixture.container.dispose);
      final target = ProbeTarget(
        name: 'JP-new',
        identity: sha256
            .convert(utf8.encode(jsonEncode(_definitions[1])))
            .toString(),
        url: _primary,
      );
      fixture.runtime.scheduler.setRunning(true);
      await fixture.runtime.scheduler.emergency((probe) => probe(target));
      final values = fixture.container.read(delayDataSourceProvider);
      expect(values[_primary]?['JP-new'], 40);
      expect(values[_binding]?['JP-new'], isNull);
      await fixture.runtime.requestCached([(name: 'JP-new', url: _binding)]);
      expect(
        fixture.container.read(delayDataSourceProvider)[_binding]?['JP-new'],
        isNull,
      );
      expect(fixture.calls, [('JP-new', _primary)]);
    },
    skip: !BrandConfig.isBranded,
  );
}
