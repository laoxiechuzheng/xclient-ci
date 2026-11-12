import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../helpers/test_profiles.dart';

class _Core extends Mock implements CoreHandlerInterface {}

class _CachedRuntime extends XcProbeRuntime {
  _CachedRuntime(super.ref);

  final List<String> requested = [];

  @override
  void start() {}

  @override
  Future<void> requestCached(
    Iterable<({String name, String url})> requests,
  ) async {
    requested.addAll(requests.map((target) => target.name));
  }
}

void main() {
  test(
    'branded single and group speed buttons only request cached feedback',
    () async {
      final core = _Core();
      late _CachedRuntime runtime;
      final container = ProviderContainer(
        overrides: [
          profilesProvider.overrideWith(TestProfiles.new),
          coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          xcProbeRuntimeProvider.overrideWith((ref) {
            runtime = _CachedRuntime(ref);
            ref.onDispose(runtime.dispose);
            return runtime;
          }),
        ],
      );
      addTearDown(container.dispose);
      final action = container.read(proxiesActionProvider.notifier);
      const a = Proxy(name: 'JP-1', type: 'ss');
      const b = Proxy(name: 'JP-2', type: 'ss');
      await action.proxyDelayTest(a, 'https://test.example');
      await action.delayTest([a, b], 'https://test.example');
      expect(runtime.requested, ['JP-1', 'JP-1', 'JP-2']);
      verifyZeroInteractions(core);
      expect(container.read(pendingDelayTestsProvider), isEmpty);
    },
    skip: !BrandConfig.isBranded,
  );
}
