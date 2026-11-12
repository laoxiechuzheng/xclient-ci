import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/providers/state.dart';

import 'brand/brand_config.dart';
import 'core/api/xboard_api.dart';
import 'core/auth/secure_store.dart';
import 'core/auth/session.dart';
import 'core/client_info.dart';
import 'core/log.dart';
import 'core/net/bootstrap.dart';
import 'core/net/core_direct_connector.dart';
import 'core/net/strict_http_client.dart';
import 'core/net/transport.dart';
import 'core/push/push_transport.dart';
import 'core/runtime.dart';
import 'core/sync/flclash_profile_sink.dart';
import 'core/sync/state_poller.dart';
import 'core/sync/policy_cache.dart';
import 'core/sync/subscription_sync.dart';
import 'core/sync/update_docs.dart';

export 'brand/brand_config.dart';
export 'core/api/xboard_api.dart';
export 'core/auth/session.dart';
export 'core/net/api_exception.dart';
export 'core/net/bootstrap.dart' show BootstrapState, BootstrapSource;
export 'core/runtime.dart';
export 'core/sync/state_poller.dart' show RemoteState, PolicyCheckPhase;
export 'core/sync/subscription_sync.dart'
    show SyncStatus, SyncPhase, SubscriptionUsage;
export 'core/sync/update_docs.dart';

final xcBrandConfigProvider = Provider<BrandConfig>(
  (ref) => BrandConfig.fromEnvironment(),
);

final xcManagedAndroidProvider = Provider<bool>(
  (_) => BrandConfig.isBranded && system.isAndroid,
);

final xcClosingProvider = NotifierProvider<XcLifecycleFlag, bool>(
  XcLifecycleFlag.new,
);
final xcExitRetryProvider = NotifierProvider<XcLifecycleFlag, bool>(
  XcLifecycleFlag.new,
);

class XcLifecycleFlag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final xcRuntimeShutdownProvider = Provider<XcRuntimeShutdown>((ref) {
  final shutdown = XcRuntimeShutdown();
  ref.onDispose(shutdown.close);
  return shutdown;
});

class XcRuntimeShutdown {
  bool isClosed = false;
  final _dispose = <void Function()>{};

  void Function() track(void Function() dispose) {
    if (isClosed) {
      dispose();
    } else {
      _dispose.add(dispose);
    }
    return () => _dispose.remove(dispose);
  }

  void close() {
    if (isClosed) return;
    isClosed = true;
    for (final dispose in _dispose.toList()) {
      dispose();
    }
    _dispose.clear();
  }
}

final xcControlActiveProvider = Provider<bool>((ref) {
  final visible = ref.watch(appVisibleProvider);
  return visible ||
      (ref.watch(xcManagedAndroidProvider) && ref.watch(isStartProvider));
});

final xcDirectConnectorProvider = Provider<CoreDirectConnector?>((ref) {
  if (ref.watch(safeModeProvider)) return null;
  final connector = CoreDirectConnector(
    api: ref.watch(coreHandlerProvider),
    ready: ref.read(coreStatusProvider) == CoreStatus.connected,
  );
  ref.listen(
    coreStatusProvider,
    (_, status) => connector.setCoreReady(status == CoreStatus.connected),
  );
  ref.onDispose(connector.close);
  return connector;
});

CoreDirectConnector? watchRuntimeDirectConnector(Ref ref) {
  final connector = ref.watch(xcDirectConnectorProvider);
  final release = connector?.attachRuntime();
  if (release != null) ref.onDispose(release);
  return connector;
}

/// Watch once at app start to own the runtime lifecycle.
final xcRuntimeProvider = FutureProvider<XClientRuntime>((ref) async {
  final shutdown = ref.read(xcRuntimeShutdownProvider);
  final brand = ref.watch(xcBrandConfigProvider);
  xcLogSink = (message, {required warn}) => commonPrint.log(
    message,
    logLevel: warn ? LogLevel.warning : LogLevel.info,
  );
  final client = await ClientInfo.detect();
  xcLog(
    'client identity ${client.platform.name}/${client.arch} '
    '${client.appVersion}+${client.build}',
  );
  final home = await appPath.homeDirPath;
  if (!ref.mounted || shutdown.isClosed) {
    throw StateError('Client runtime is closing');
  }
  final connector = watchRuntimeDirectConnector(ref);
  final runtime = XClientRuntime(
    brand: brand,
    client: client,
    store: PlatformSecureStore(brandId: brand.brandId),
    cache: FileBootstrapCache(join(home, 'xclient', 'bootstrap.json')),
    policyCache: FilePolicyCache(join(home, 'xclient', 'policy.json')),
    sink: FlClashProfileSink(ref),
    transportFactory: ({pins, onPinReport}) => IoHttpTransport(
      pins: pins,
      onPinReport: onPinReport,
      connector: connector,
    ),
    pushTransportFactory: ({pins, onPinReport}) => IoPushTransport(
      StrictHttpClientFactory(
        pins: pins,
        onPinReport: onPinReport,
        connector: connector,
      ),
    ),
  );
  var disposed = false;
  void dispose() {
    if (disposed) return;
    disposed = true;
    runtime.dispose();
  }

  final untrack = shutdown.track(dispose);
  ref.onDispose(() {
    untrack();
    dispose();
  });
  runtime.setForeground(ref.read(xcControlActiveProvider));
  await runtime.start();
  if (shutdown.isClosed) throw StateError('Client runtime is closing');
  return runtime;
});

final xcApiProvider = Provider<XboardApi?>(
  (ref) => ref.watch(xcRuntimeProvider).value?.xboard,
);

final xcSessionProvider = StreamProvider<XcSessionState>((ref) async* {
  final runtime = await ref.watch(xcRuntimeProvider.future);
  yield runtime.session.state;
  yield* runtime.session.changes;
});

final xcSyncStatusProvider = StreamProvider<SyncStatus>((ref) async* {
  final runtime = await ref.watch(xcRuntimeProvider.future);
  yield runtime.sync.status;
  yield* runtime.sync.changes;
});

final xcBootstrapProvider = StreamProvider<BootstrapState>((ref) async* {
  final runtime = await ref.watch(xcRuntimeProvider.future);
  yield runtime.bootstrap.state;
  yield* runtime.bootstrap.changes;
});

final xcRemoteStateProvider = StreamProvider<RemoteState>((ref) async* {
  final runtime = await ref.watch(xcRuntimeProvider.future);
  yield runtime.poller.state;
  yield* runtime.poller.changes;
});

final xcPolicyProvider = Provider<XcPolicy?>(
  (ref) => ref.watch(xcRemoteStateProvider).value?.policy,
);

final xcNoticeProvider = Provider<XcNotice?>(
  (ref) => ref.watch(xcRemoteStateProvider).value?.effectiveNotice,
);

final xcManagedProfileIdProvider = FutureProvider<int?>((ref) {
  ref.watch(xcSyncStatusProvider);
  return FlClashProfileSink.managedProfileId();
});

final xcActionsProvider = Provider<XcActions>((ref) => XcActions(ref));

class XcActions {
  final Ref _ref;

  const XcActions(this._ref);

  Future<XClientRuntime> get _runtime => _ref.read(xcRuntimeProvider.future);

  Future<void> login(String email, String password) async =>
      (await _runtime).login(email, password);

  Future<void> logout() async => (await _runtime).logout();

  Future<void> registerDevice() async =>
      (await _runtime).session.registerDevice();

  Future<SyncStatus> syncNow() async => (await _runtime).sync.syncNow();

  Future<void> refreshUser() async => (await _runtime).session.refreshUser();

  Future<void> pollState() async => (await _runtime).poller.pollNow();

  void setForeground(bool foreground) =>
      _ref.read(xcRuntimeProvider).value?.setForeground(foreground);
}
