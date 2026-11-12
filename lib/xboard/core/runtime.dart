import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../brand/brand_config.dart';
import 'api/xboard_api.dart';
import 'auth/secure_store.dart';
import 'auth/session.dart';
import 'client_info.dart';
import 'log.dart';
import 'net/api_client.dart';
import 'net/bootstrap.dart';
import 'net/endpoint_pool.dart';
import 'net/spki.dart';
import 'net/transport.dart';
import 'net/strict_http_client.dart';
import 'push/push_client.dart';
import 'push/push_ticket.dart';
import 'push/push_transport.dart';
import 'push/sequence_hint_gate.dart';
import 'sync/state_poller.dart';
import 'sync/policy_cache.dart';
import 'sync/subscription_sync.dart';
import 'ua.dart';

typedef TransportFactory =
    HttpTransport Function({
      PinPolicy Function()? pins,
      PinReport? onPinReport,
    });

HttpTransport _ioTransport({
  PinPolicy Function()? pins,
  PinReport? onPinReport,
}) => IoHttpTransport(pins: pins, onPinReport: onPinReport);

typedef PushTransportFactory =
    PushTransport Function({
      PinPolicy Function()? pins,
      PinReport? onPinReport,
    });

PushTransport _ioPushTransport({
  PinPolicy Function()? pins,
  PinReport? onPinReport,
}) => IoPushTransport(
  StrictHttpClientFactory(pins: pins, onPinReport: onPinReport),
);

/// Wires the XClient core together and runs its schedules:
/// bootstrap (L0 at start, refresh on `b` growth, on fail-over and every 6h
/// from the sources), the session, the subscription sync and the state
/// poller. One per app.
class XClientRuntime {
  static const sourceCheckEvery = Duration(hours: 6);
  static const seqReactionGap = Duration(seconds: 10);

  final BrandConfig brand;
  final ClientInfo client;
  final SecureStore store;
  final DateTime Function() _now;
  final Random _random;

  late final HttpTransport _apiTransport;
  late final HttpTransport _plainTransport;
  late final EndpointPool pool;
  late final ApiClient api;
  late final BootstrapResolver bootstrap;
  late final Session session;
  late final XboardApi xboard;
  late final SubscriptionSync sync;
  late final StatePoller poller;
  late final XcPushClient push;
  late final SequenceHintGate _seqGate;

  final _subscriptions = <StreamSubscription<Object?>>[];
  Timer? _sourceTimer;
  Timer? _fullCatchupTimer;
  int _fullCatchupSeq = -1;
  DateTime? _lastFullCatchup;
  bool _started = false;
  bool _disposed = false;
  List<ApiEndpointSpec> _appliedApi = const [];
  String _appliedPins = '[]';
  int _appliedPollFg = 60;
  int _appliedPollBg = 900;

  XClientRuntime({
    required this.brand,
    required this.client,
    required this.store,
    required BootstrapCache cache,
    required ManagedProfileSink sink,
    PolicyCache? policyCache,
    TransportFactory transportFactory = _ioTransport,
    PushTransportFactory pushTransportFactory = _ioPushTransport,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure() {
    final ua = buildUserAgent(
      client.uaParts(
        brandId: brand.brandId,
        coreVersion: brand.coreVersion,
        product: brand.uaProduct,
      ),
    );
    pool = EndpointPool(now: _now);
    _apiTransport = transportFactory(
      pins: () => bootstrap.state.pins,
      onPinReport: (host, spki) =>
          xcLog('pin mismatch for $host: $spki', warn: true),
    );
    // The signed bootstrap is never pinned: a wrong pin must not block the
    // document that fixes it.
    _plainTransport = transportFactory();
    api = ApiClient(
      transport: _apiTransport,
      pool: pool,
      userAgent: ua,
      now: _now,
    );
    bootstrap = BootstrapResolver(
      brand: brand,
      transport: _plainTransport,
      cache: cache,
      panelEndpoints: () => [for (final e in pool.attemptOrder()) e.url],
      userAgent: () => api.userAgent,
      now: _now,
    );
    session = Session(api: api, store: store, client: client);
    xboard = XboardApi(api, checkoutWebUrl: brand.panelWebUrl);
    sync = SubscriptionSync(
      api: api,
      session: session,
      sink: sink,
      envKeys: () =>
          bootstrap.state.envKeys(brand, _now().millisecondsSinceEpoch ~/ 1000),
      directHosts: () => {
        ...pool.hosts,
        for (final spec in brand.builtinApiEndpoints)
          ?Uri.tryParse(spec.url)?.host,
      },
      label: brand.displayName,
      now: _now,
      random: _random,
    );
    poller = StatePoller(
      api: api,
      session: session,
      ctrlKeys: () => brand.ctrlKeys,
      brandId: brand.brandId,
      cache: policyCache,
      now: _now,
    );
    _seqGate = SequenceHintGate(now: _now, gap: seqReactionGap);
    push = XcPushClient(
      tickets: ApiPushTicketIssuer(
        api: api,
        transportFactory: () =>
            transportFactory(pins: () => bootstrap.state.pins),
      ),
      transport: pushTransportFactory(pins: () => bootstrap.state.pins),
      userAgent: () => api.userAgent,
      onSeq: (seq) {
        if (session.state.isLoggedIn && session.state.deviceRegistered) {
          _onSeq(seq);
        }
      },
      now: _now,
      randomInt: _random.nextInt,
    );
  }

  String get userAgent => api.userAgent;

  /// L0 bootstrap, session restore, then the background work.
  Future<void> start() async {
    if (_started || _disposed) return;
    _started = true;
    final cached = await bootstrap.loadCache();
    if (_disposed) return;
    _applyBootstrap(cached);
    await poller.loadCache();
    if (_disposed) return;
    _subscriptions
      ..add(bootstrap.changes.listen(_applyBootstrap))
      ..add(session.changes.listen(_onSession));
    api.addSeqListener(_onSeq);
    push.start();
    pool
      ..onFailover = _refreshBootstrap
      ..onExhausted = () => _refreshBootstrap(panel: false);
    _sourceTimer = Timer.periodic(
      sourceCheckEvery,
      (_) => _refreshBootstrap(panel: false),
    );
    if (cached.payload == null) {
      _applyBootstrap(await bootstrap.refresh());
      if (_disposed) return;
    }
    await session.restore();
    if (_disposed) return;
    _onSession(session.state);
    if (cached.payload != null) _refreshBootstrap();
  }

  void _applyBootstrap(BootstrapState state) {
    if (_disposed) return;
    final endpoints = state.payload == null
        ? const <ApiEndpointSpec>[]
        : state.endpoints(brand);
    final urlsChanged =
        _appliedApi.length != endpoints.length ||
        endpoints.indexed.any(
          (entry) => _appliedApi[entry.$1].url != entry.$2.url,
        );
    final weightsChanged =
        !urlsChanged &&
        endpoints.indexed.any(
          (entry) => _appliedApi[entry.$1].weight != entry.$2.weight,
        );
    final pinKey = _pinKey(state.pins);
    final pinsChanged = _appliedPins != pinKey;
    if (urlsChanged || weightsChanged) pool.replace(endpoints);
    _appliedApi = List.of(endpoints);
    _appliedPins = pinKey;
    if (urlsChanged || pinsChanged) push.reconnect();
    final payload = state.payload;
    if (payload != null &&
        (payload.pollForeground != _appliedPollFg ||
            payload.pollBackground != _appliedPollBg)) {
      _appliedPollFg = payload.pollForeground;
      _appliedPollBg = payload.pollBackground;
      poller.setIntervals(
        foreground: Duration(seconds: payload.pollForeground),
        background: Duration(seconds: payload.pollBackground),
      );
    }
    _scheduleFullCatchup();
  }

  void _scheduleFullCatchup() {
    if (!bootstrap.needsFull) {
      _fullCatchupTimer?.cancel();
      _fullCatchupTimer = null;
      return;
    }
    if (bootstrap.state.seq <= _fullCatchupSeq) return;
    _fullCatchupSeq = bootstrap.state.seq;
    _fullCatchupTimer?.cancel();
    final elapsed = _lastFullCatchup == null
        ? seqReactionGap
        : _now().difference(_lastFullCatchup!);
    final delay = elapsed >= seqReactionGap
        ? Duration.zero
        : elapsed.isNegative
        ? seqReactionGap
        : seqReactionGap - elapsed;
    // The event queue lets the adopting refresh release its shared future first.
    _fullCatchupTimer = Timer(delay, () {
      _fullCatchupTimer = null;
      if (_disposed || !bootstrap.needsFull) return;
      _lastFullCatchup = _now();
      _refreshBootstrap();
    });
  }

  static String _pinKey(PinPolicy policy) {
    final hosts =
        policy.hosts.keys.where((host) => policy.forHost(host) != null).toList()
          ..sort();
    return jsonEncode([
      for (final host in hosts)
        [
          host,
          policy.hosts[host]!.mode.name,
          policy.hosts[host]!.spki.toList()..sort(),
        ],
    ]);
  }

  void _refreshBootstrap({bool panel = true}) {
    if (_disposed) return;
    unawaited(
      bootstrap
          .refresh(panel: panel)
          .then<void>(
            (_) {},
            onError: (Object e) =>
                xcLog('bootstrap refresh failed: $e', warn: true),
          ),
    );
  }

  void _onSession(XcSessionState state) {
    if (_disposed) return;
    push.setSession(
      ready: state.isLoggedIn && state.deviceRegistered,
      generation: api.authorizationGeneration,
    );
    push.start();
    if (state.isLoggedIn && state.deviceRegistered) {
      sync.start();
      poller.start();
    } else {
      sync.stop();
      poller.stop();
    }
  }

  /// API and push hints trigger fetching; only verified documents advance the floor.
  void _onSeq(XClientSeq seq) {
    if (_disposed) return;
    poller.requirePolicy(seq.policy);
    final reaction = _seqGate.react(
      seq,
      bootFloor: bootstrap.lastFullSeq,
      policyFloor: poller.state.policy?.seq ?? -1,
    );
    if (reaction.boot) _refreshBootstrap();
    if (reaction.policy) unawaited(poller.pollNow());
    if (reaction.boot || reaction.policy) {
      sync.requestSync(delay: Duration(seconds: 1 + _random.nextInt(5)));
    }
  }

  /// App lifecycle: polling is 60s in front, 15min behind.
  void setForeground(bool foreground) {
    if (_disposed) return;
    poller.setForeground(foreground);
    push.setForeground(foreground);
  }

  Future<void> login(String email, String password) =>
      session.login(email, password);

  Future<void> logout() {
    push.stop();
    return session.logout();
  }

  void dispose() {
    _disposed = true;
    push.dispose();
    _sourceTimer?.cancel();
    _fullCatchupTimer?.cancel();
    api.removeSeqListener(_onSeq);
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    sync.dispose();
    poller.dispose();
    session.dispose();
    bootstrap.dispose();
    _apiTransport.close();
    _plainTransport.close();
  }
}
