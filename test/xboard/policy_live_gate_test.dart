import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/sync/state_poller.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

final _liveCheck = Provider(
  (ref) =>
      () => xcConnectionBlockNow(ref),
);

void main() {
  for (final phase in PolicyCheckPhase.values) {
    test(
      'live $phase policy is checked despite a stale allowing stream value',
      () async {
        final runtime = _Runtime();
        runtime.poller.current = RemoteState(phase: phase);
        final container = ProviderContainer(
          overrides: [
            xcRuntimeProvider.overrideWith((_) async => runtime),
            xcConnectionBlockProvider.overrideWithValue(null),
          ],
        );
        addTearDown(container.dispose);
        await container.read(xcRuntimeProvider.future);
        final check = container.read(_liveCheck);
        expect(check() == null, phase == PolicyCheckPhase.verified);
        runtime.session.current = const XcSessionState(
          status: XcSessionStatus.loggedOut,
        );
        expect(check(), contains('登录'));
      },
      skip: !BrandConfig.isBranded,
    );
  }

  test(
    'same-turn force or admission changes cannot start a listener',
    () async {
      final runtime = _Runtime();
      final container = ProviderContainer(
        overrides: [
          xcRuntimeProvider.overrideWith((_) async => runtime),
          xcConnectionBlockProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      await container.read(xcRuntimeProvider.future);
      final check = container.read(_liveCheck);
      expect(check(), isNull);
      runtime.poller.current = const RemoteState(
        phase: PolicyCheckPhase.verified,
        policy: XcPolicy(
          brand: 'example',
          seq: 9,
          latest: '2.0.0',
          minSupported: '',
          force: true,
        ),
      );
      expect(check(), contains('更新'));
      expect(
        await container.read(setupActionProvider.notifier).setRunning(true),
        isFalse,
      );
      runtime.poller.current = const RemoteState(
        phase: PolicyCheckPhase.verified,
      );
      runtime.sync.current = const SyncStatus(
        phase: SyncPhase.blocked,
        message: '网络准入拒绝',
      );
      expect(check(), '网络准入拒绝');
      expect(
        await container
            .read(setupActionProvider.notifier)
            .setRunning(true, initialize: true),
        isFalse,
      );
    },
    skip: !BrandConfig.isBranded,
  );

  for (final blocked in [false, true]) {
    test(
      'soft policy waiting does not request a stop; admission=$blocked does',
      () async {
        final container = ProviderContainer(
          overrides: [
            xcForceUpdateActiveProvider.overrideWithValue(false),
            xcSessionProvider.overrideWith(
              (_) => Stream.value(
                const XcSessionState(
                  status: XcSessionStatus.loggedIn,
                  deviceRegistered: true,
                ),
              ),
            ),
            xcSyncStatusProvider.overrideWith(
              (_) => Stream.value(
                SyncStatus(phase: blocked ? SyncPhase.blocked : SyncPhase.ok),
              ),
            ),
          ],
        );
        addTearDown(container.dispose);
        container.listen(xcConnectionMustStopProvider, (_, _) {});
        await container.read(xcSessionProvider.future);
        await container.read(xcSyncStatusProvider.future);
        expect(container.read(xcConnectionMustStopProvider), blocked);
      },
      skip: !BrandConfig.isBranded,
    );
  }
}

class _Session extends Fake implements Session {
  XcSessionState current = const XcSessionState(
    status: XcSessionStatus.loggedIn,
    deviceRegistered: true,
  );
  @override
  XcSessionState get state => current;
}

class _Poller extends Fake implements StatePoller {
  RemoteState current = const RemoteState(phase: PolicyCheckPhase.verified);
  @override
  RemoteState get state => current;
}

class _Sync extends Fake implements SubscriptionSync {
  SyncStatus current = SyncStatus(
    phase: SyncPhase.ok,
    lastSuccess: DateTime.utc(2026),
  );
  @override
  SyncStatus get status => current;
}

class _Runtime extends Fake implements XClientRuntime {
  @override
  final _Session session = _Session();
  @override
  final _Poller poller = _Poller();
  @override
  final _Sync sync = _Sync();
  @override
  final client = const ClientInfo(
    platform: XcPlatform.android,
    arch: 'arm64-v8a',
    appVersion: '1.0.0',
    build: '1',
    osVersion: '14',
    deviceName: 'Test',
  );
}
