import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/update/update_providers.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:riverpod/riverpod.dart';

void main() {
  test(
    'a ready subscription cannot connect before online policy verification',
    () async {
      final container = ProviderContainer(
        overrides: [
          initProvider.overrideWithBuild((_, _) => true),
          currentProfileIdProvider.overrideWithBuild((_, _) => 1),
          xcForceUpdateActiveProvider.overrideWithValue(false),
          xcSessionProvider.overrideWith(
            (_) => Stream.value(
              const XcSessionState(
                status: XcSessionStatus.loggedIn,
                deviceRegistered: true,
              ),
            ),
          ),
          xcManagedProfileIdProvider.overrideWith((_) async => 1),
          xcSyncStatusProvider.overrideWith(
            (_) => Stream.value(
              SyncStatus(phase: SyncPhase.ok, lastSuccess: DateTime.utc(2026)),
            ),
          ),
          xcRemoteStateProvider.overrideWith(
            (_) => Stream.value(const RemoteState()),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.listen(xcConnectionBlockProvider, (_, _) {});
      container.listen(xcManagedProfileIdProvider, (_, _) {});
      container.listen(xcSyncStatusProvider, (_, _) {});
      await container.read(xcSessionProvider.future);
      await container.read(xcSyncStatusProvider.future);
      await container.read(xcManagedProfileIdProvider.future);
      expect(container.read(initProvider), isTrue);
      expect(container.read(currentProfileIdProvider), 1);
      expect(container.read(xcConnectionBlockProvider), isNotNull);
    },
    skip: !BrandConfig.isBranded,
  );
  test(
    'connection refusal covers ordinary and initialization starts',
    () async {
      final container = ProviderContainer(
        overrides: [xcConnectionBlockProvider.overrideWithValue('需要更新')],
      );
      addTearDown(container.dispose);
      final action = container.read(setupActionProvider.notifier);
      expect(await action.setRunning(true), isFalse);
      expect(await action.setRunning(true, initialize: true), isFalse);
    },
  );

  test('branded startup stops a native run before restoring login', () async {
    final previous = globalState.needInitStatus;
    globalState.needInitStatus = true;
    addTearDown(() => globalState.needInitStatus = previous);
    final action = _RestoredSetupAction();
    final container = ProviderContainer(
      overrides: [
        appVisibleProvider.overrideWithBuild((_, _) => false),
        setupActionProvider.overrideWith(() => action),
        xcConnectionBlockProvider.overrideWithValue('请先登录'),
      ],
    );
    addTearDown(container.dispose);
    await container.read(setupActionProvider.notifier).initStatus();
    expect(action.transitions, [false]);
  }, skip: !BrandConfig.isBranded);
}

class _RestoredSetupAction extends SetupAction {
  final transitions = <bool>[];

  @override
  Future<DateTime?> serviceStartTime() async =>
      DateTime.now().subtract(const Duration(minutes: 1));

  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    transitions.add(running);
    return true;
  }

  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) async => true;
}
