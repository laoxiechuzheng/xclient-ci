import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/api/xboard_api.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/auth/session.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/crypto/signed_doc.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/sync/state_poller.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class _Sink implements ManagedProfileSink {
  final applied = <String>[];
  String? userinfo;
  Error? applyError;
  var removed = 0;
  Completer<void>? removeBarrier;
  Completer<void>? removeStarted;

  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {
    if (applyError != null) throw applyError!;
    applied.add(utf8.decode(yaml));
    userinfo = subscriptionUserinfo;
  }

  @override
  Future<void> remove() async {
    removed++;
    removeStarted?.complete();
    await removeBarrier?.future;
  }
}

const _api = 'https://api.example.com';

void main() {
  final v = loadVectors('envelope_v1_core.json');
  final now = v['now'] as int;
  final device = v['device'] as Map<String, dynamic>;
  final envelope = v['envelope'] as Map<String, dynamic>;
  final envKeys = TrustedKeys.fromB64u(
    ((v['keys'] as Map)['env'] as Map).cast<String, String>(),
  );
  final nonceBytes = b64uDecode(envelope['req_nonce'] as String);

  late FakeTransport transport;
  late MemorySecureStore store;
  late ApiClient api;
  late Session session;
  late _Sink sink;
  late SubscriptionSync sync;
  late ScriptedRandom random;
  late Object subscribeReply;
  late Map<String, int> hits;

  const client = ClientInfo(
    platform: XcPlatform.android,
    arch: 'arm64-v8a',
    appVersion: '1.0.0',
    build: '100',
    osVersion: '14',
    deviceName: 'Pixel',
  );

  setUp(() {
    hits = {};
    subscribeReply = {'ok': true, 'data': envelope['ok']};
    store = MemorySecureStore({
      SecureKeys.deviceId: device['id'] as String,
      SecureKeys.deviceSk: device['sk'] as String,
    });
    transport = FakeTransport((request) {
      final path = request.uri.path;
      hits[path] = (hits[path] ?? 0) + 1;
      switch (path) {
        case '/api/v1/passport/auth/login':
          final form = Uri.splitQueryString(utf8.decode(request.body!));
          if (form['password'] != 'right-password') {
            return jsonResponse({
              'status': 'fail',
              'message': '邮箱或密码错误',
              'data': null,
            }, status: 400);
          }
          return jsonResponse({
            'status': 'success',
            'data': {
              'token': 'SUBSCRIBE-TOKEN',
              'auth_data': 'Bearer abc',
              'is_admin': false,
            },
          });
        case '/api/v1/xclient/device/register':
          return jsonResponse({
            'ok': true,
            'data': {
              'device_id': device['id'],
              'max_devices': 5,
              'active_devices': 1,
              'env_kid': 'env-1',
            },
          });
        case '/api/v1/xclient/subscribe':
          final reply = subscribeReply;
          if (reply is TransportResponse) return reply;
          return jsonResponse(reply);
        case '/api/v1/user/info':
          return jsonResponse({
            'status': 'success',
            'data': {'email': 'u@example.com'},
          });
        case '/api/v1/xclient/logout':
          return jsonResponse({'ok': true, 'data': {}});
      }
      return jsonResponse({'message': 'not found'}, status: 404);
    });
    api = ApiClient(
      transport: transport,
      pool: EndpointPool(endpoints: const [ApiEndpointSpec(_api)]),
      userAgent: buildUserAgent(
        client.uaParts(brandId: 'demo', coreVersion: '1.19.33'),
      ),
      now: () => fromUnix(now),
    );
    session = Session(api: api, store: store, client: client);
    sink = _Sink();
    random = ScriptedRandom(nonceBytes);
    sync = SubscriptionSync(
      api: api,
      session: session,
      sink: sink,
      envKeys: () => envKeys,
      directHosts: () => api.pool.hosts,
      label: 'Demo',
      now: () => fromUnix(now),
      random: random,
    );
  });

  tearDown(() {
    sync.dispose();
    session.dispose();
  });

  Future<SyncStatus> pull() {
    random.reset();
    return sync.syncNow();
  }

  test('a wrong password leaves an error state and stores nothing', () async {
    await expectLater(
      session.login('u@example.com', 'wrong'),
      throwsA(isA<XbApiException>()),
    );
    expect(session.state.status, XcSessionStatus.error);
    expect(session.state.message, '邮箱或密码错误');
    expect(await store.read(SecureKeys.auth), isNull);
  });

  test(
    'login keeps only auth_data, registers the device, then pulls',
    () async {
      await session.login(' u@example.com ', 'right-password');
      expect(session.state.isLoggedIn, isTrue);
      expect(session.state.deviceRegistered, isTrue);
      expect(session.state.device?['max_devices'], 5);
      expect(await store.read(SecureKeys.auth), 'Bearer abc');
      expect(await store.read(SecureKeys.email), 'u@example.com');
      expect(
        store.values.values.any((v) => v.contains('SUBSCRIBE-TOKEN')),
        isFalse,
      );
      expect(
        store.values.values.any((v) => v.contains('right-password')),
        isFalse,
      );

      final register = transport.requests.firstWhere(
        (r) => r.uri.path == '/api/v1/xclient/device/register',
      );
      final body = jsonDecode(utf8.decode(register.body!)) as Map;
      expect(body['device_id'], device['id']);
      expect(body['pub'], device['pk']);
      expect(body['platform'], 'android');
      expect(body['arch'], 'arm64-v8a');
      expect(register.headers['authorization'], 'Bearer abc');
      expect(register.headers['x-xclient-device'], device['id']);
      expect(
        register.headers['user-agent'],
        startsWith('demoClient/1.0.0 (Android 14; Mobile;'),
      );

      final status = await pull();
      expect(status.phase, SyncPhase.ok, reason: status.message);
      final subscribe = transport.requests.lastWhere(
        (r) => r.uri.path == '/api/v1/xclient/subscribe',
      );
      final pullBody = jsonDecode(utf8.decode(subscribe.body!)) as Map;
      expect(pullBody['req_nonce'], envelope['req_nonce']);
      expect(pullBody['ts'], now);
      expect(sink.applied, hasLength(1));
      final yaml = loadPlainYaml(sink.applied.single) as Map;
      final auto = (yaml['proxy-groups'] as List).first as Map;
      expect(auto['lazy'], true);
      expect(auto['interval'], 1800);
      expect((yaml['rules'] as List).first, 'DOMAIN,api.example.com,DIRECT');
      expect(sink.userinfo, contains('total=10737418240'));
      expect(status.usage?.total, 10737418240);
      expect(sync.interval, const Duration(hours: 24));
    },
  );

  test(
    'an unaccepted profile application never marks subscription sync successful',
    () async {
      await session.login('u@example.com', 'right-password');
      sink.applyError = StateError('core rejected config');
      final result = await pull();
      expect(result.phase, SyncPhase.error);
      expect(result.lastSuccess, isNull);
      expect(result.message, SyncMessages.config);
    },
  );

  test('a blocked (403) envelope does not touch the profile', () async {
    await session.login('u@example.com', 'right-password');
    subscribeReply = {'ok': true, 'data': envelope['blocked']};
    final status = await pull();
    expect(status.phase, SyncPhase.blocked);
    expect(status.panelStatus, 403);
    expect(status.message, SyncMessages.blocked);
    expect(sink.applied, isEmpty);
  });

  test('device_unknown re-registers once and retries', () async {
    await session.login('u@example.com', 'right-password');
    var first = true;
    final ok = {'ok': true, 'data': envelope['ok']};
    transport.handler = _wrap(
      transport.handler,
      '/api/v1/xclient/subscribe',
      () {
        if (first) {
          first = false;
          // The retry draws a fresh nonce; let it be the vector's again.
          random.reset();
          return jsonResponse({
            'ok': false,
            'error': 'device_unknown',
          }, status: 409);
        }
        return jsonResponse(ok);
      },
    );
    final registersBefore = hits['/api/v1/xclient/device/register']!;
    final status = await pull();
    expect(status.phase, SyncPhase.ok, reason: status.message);
    expect(hits['/api/v1/xclient/device/register'], registersBefore + 1);
  });

  test('an envelope from an untrusted key is refused', () async {
    await session.login('u@example.com', 'right-password');
    subscribeReply = {'ok': true, 'data': envelope['rogue']};
    final status = await pull();
    expect(status.phase, SyncPhase.error);
    expect(status.message, SyncMessages.invalid);
    expect(sink.applied, isEmpty);
  });

  test('401 ends the session: profile removed, store cleared', () async {
    await session.login('u@example.com', 'right-password');
    subscribeReply = jsonResponse({
      'ok': false,
      'error': 'unauthenticated',
    }, status: 401);
    await pull();
    await Future<void>.delayed(Duration.zero);
    expect(session.state.status, XcSessionStatus.loggedOut);
    expect(session.state.message, SessionMessages.expired);
    expect(sink.removed, 1);
    expect(store.values, isEmpty);
    expect(api.authorization, isNull);
  });

  test('device_revoked ends the session with its own message', () async {
    await session.login('u@example.com', 'right-password');
    subscribeReply = jsonResponse({
      'ok': false,
      'error': 'device_revoked',
    }, status: 403);
    await pull();
    await Future<void>.delayed(Duration.zero);
    expect(session.state.message, SessionMessages.deviceRevoked);
  });

  test('device limit keeps the login and reports it', () async {
    transport.handler = _wrap(
      transport.handler,
      '/api/v1/xclient/device/register',
      () => jsonResponse({
        'ok': false,
        'error': 'device_limit',
        'message': 'limit',
      }, status: 403),
    );
    await session.login('u@example.com', 'right-password');
    expect(session.state.isLoggedIn, isTrue);
    expect(session.state.deviceRegistered, isFalse);
    expect(session.state.deviceError?.kind, XbErrorKind.deviceLimit);
    expect(session.state.message, SessionMessages.deviceLimit);
    final status = await pull();
    expect(status.phase, SyncPhase.error);
  });

  test('logout calls the server, then wipes everything', () async {
    await session.login('u@example.com', 'right-password');
    await session.logout();
    expect(hits['/api/v1/xclient/logout'], 1);
    expect(session.state.status, XcSessionStatus.loggedOut);
    expect(store.values, isEmpty);
    expect(sink.removed, 1);
  });

  test(
    'a subscription arriving after logout cannot restore the profile',
    () async {
      await session.login('u@example.com', 'right-password');
      final pending = Completer<TransportResponse>();
      final requested = Completer<void>();
      final original = transport.handler;
      transport.handler = (request) {
        if (request.uri.path == '/api/v1/xclient/subscribe') {
          requested.complete();
          return pending.future;
        }
        return original(request);
      };
      final pulling = pull();
      await requested.future;
      await session.logout();
      pending.complete(jsonResponse(subscribeReply));
      await pulling;
      expect(sink.applied, isEmpty);
      expect(sync.status.phase, SyncPhase.idle);
    },
  );

  test(
    'logout becomes non-authenticated before asynchronous cleanup finishes',
    () async {
      await session.login('u@example.com', 'right-password');
      sink.removeStarted = Completer<void>();
      sink.removeBarrier = Completer<void>();
      final logout = session.logout();
      await sink.removeStarted!.future;
      try {
        expect(session.state.isLoggedIn, isFalse);
        expect(api.authorization, isNull);
        expect(session.identity, isNull);
      } finally {
        sink.removeBarrier!.complete();
        await logout;
      }
    },
  );

  test(
    'a registration finishing inside the logout barrier cannot revive the session',
    () async {
      await session.login('u@example.com', 'right-password');
      final pending = Completer<TransportResponse>();
      final requested = Completer<void>();
      final original = transport.handler;
      transport.handler = (request) {
        if (request.uri.path.endsWith('/device/register')) {
          requested.complete();
          return pending.future;
        }
        return original(request);
      };
      final registering = session.registerDevice();
      await requested.future;
      sink.removeStarted = Completer<void>();
      sink.removeBarrier = Completer<void>();
      final logout = session.logout();
      await sink.removeStarted!.future;
      pending.complete(
        jsonResponse({
          'ok': true,
          'data': {'max_devices': 5},
        }),
      );
      await registering;
      try {
        expect(session.state.isLoggedIn, isFalse);
        expect(session.state.deviceRegistered, isFalse);
      } finally {
        sink.removeBarrier!.complete();
        await logout;
      }
    },
  );

  test('a new login waits for the previous logout cleanup', () async {
    await session.login('u@example.com', 'right-password');
    sink.removeStarted = Completer<void>();
    sink.removeBarrier = Completer<void>();
    final logout = session.logout();
    await sink.removeStarted!.future;
    final before = hits['/api/v1/passport/auth/login'];
    final login = session.login('new@example.com', 'right-password');
    await Future<void>.delayed(Duration.zero);
    try {
      expect(hits['/api/v1/passport/auth/login'], before);
    } finally {
      sink.removeBarrier!.complete();
      await logout;
      await login;
    }
    expect(session.state.isLoggedIn, isTrue);
    expect(session.state.email, 'new@example.com');
    expect(await store.read(SecureKeys.auth), 'Bearer abc');
  });

  test('a login response received after logout is discarded', () async {
    final pending = Completer<TransportResponse>();
    final requested = Completer<void>();
    final original = transport.handler;
    transport.handler = (request) {
      if (request.uri.path.endsWith('/auth/login')) {
        requested.complete();
        return pending.future;
      }
      return original(request);
    };
    final login = session.login('u@example.com', 'right-password');
    await requested.future;
    await session.logout();
    pending.complete(
      jsonResponse({
        'status': 'success',
        'data': {'auth_data': 'Bearer stale'},
      }),
    );
    await login;
    expect(session.state.isLoggedIn, isFalse);
    expect(store.values, isEmpty);
    expect(api.authorization, isNull);
  });

  test('an old user response cannot overwrite a later login', () async {
    await session.login('u@example.com', 'right-password');
    await session.refreshUser();
    final pending = Completer<TransportResponse>();
    final requested = Completer<void>();
    var held = false;
    final original = transport.handler;
    transport.handler = (request) {
      if (request.uri.path.endsWith('/user/info')) {
        if (!held) {
          held = true;
          requested.complete();
          return pending.future;
        }
        return jsonResponse({
          'status': 'success',
          'data': {'email': 'new@example.com'},
        });
      }
      return original(request);
    };
    final refreshing = session.refreshUser();
    await requested.future;
    await session.logout();
    await session.login('new@example.com', 'right-password');
    await session.refreshUser();
    pending.complete(
      jsonResponse({
        'status': 'success',
        'data': {'email': 'old@example.com'},
      }),
    );
    await refreshing;
    expect(session.state.user?['email'], 'new@example.com');
  });

  test(
    'an old 401 still reaches its caller without terminating a later login',
    () async {
      var logins = 0;
      final original = transport.handler;
      final pending = Completer<TransportResponse>();
      final requested = Completer<void>();
      var hold = false;
      transport.handler = (request) {
        if (request.uri.path.endsWith('/auth/login')) {
          return jsonResponse({
            'status': 'success',
            'data': {'auth_data': 'Bearer session-${++logins}'},
          });
        }
        if (hold && request.uri.path.endsWith('/user/info')) {
          hold = false;
          requested.complete();
          return pending.future;
        }
        return original(request);
      };
      await session.login('u@example.com', 'right-password');
      await session.refreshUser();
      hold = true;
      final refreshing = session.refreshUser();
      final refused = expectLater(
        refreshing,
        throwsA(
          isA<XbApiException>().having(
            (error) => error.kind,
            'kind',
            XbErrorKind.unauthorized,
          ),
        ),
      );
      await requested.future;
      await session.logout();
      await session.login('new@example.com', 'right-password');
      pending.complete(
        jsonResponse({'ok': false, 'error': 'unauthenticated'}, status: 401),
      );
      await refused;
      await Future<void>.delayed(Duration.zero);
      expect(session.state.isLoggedIn, isTrue);
      expect(api.authorization, 'Bearer session-2');
    },
  );

  test(
    'device_unknown from an old operation cannot retry under a new login',
    () async {
      await session.login('u@example.com', 'right-password');
      final pending = Completer<String>();
      var calls = 0;
      final operation = session.withDevice(() {
        calls++;
        return pending.future;
      });
      final refused = expectLater(
        operation,
        throwsA(
          isA<XbApiException>().having(
            (error) => error.kind,
            'kind',
            XbErrorKind.deviceUnknown,
          ),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      await session.logout();
      await session.login('new@example.com', 'right-password');
      pending.completeError(const XbApiException(XbErrorKind.deviceUnknown));
      await refused;
      expect(calls, 1);
      expect(session.state.deviceRegistered, isTrue);
    },
  );

  test(
    'new subscription pull starts independently from an old pending pull',
    () async {
      await session.login('u@example.com', 'right-password');
      final pending = <Completer<TransportResponse>>[];
      final original = transport.handler;
      transport.handler = (request) {
        if (request.uri.path.endsWith('/subscribe')) {
          final reply = Completer<TransportResponse>();
          pending.add(reply);
          return reply.future;
        }
        return original(request);
      };
      final oldPull = pull();
      await Future<void>.delayed(Duration.zero);
      expect(pending, hasLength(1));
      await session.logout();
      await session.login('new@example.com', 'right-password');
      final newPull = pull();
      await Future<void>.delayed(Duration.zero);
      expect(pending, hasLength(2));
      pending.first.complete(jsonResponse(subscribeReply));
      await oldPull;
      expect(identical(sync.syncNow(), newPull), isTrue);
      expect(pending, hasLength(2));
      pending.last.complete(jsonResponse(subscribeReply));
      await newPull;
    },
  );

  test(
    'concurrent logout calls share one cleanup and one remote revoke',
    () async {
      await session.login('u@example.com', 'right-password');
      sink.removeStarted = Completer<void>();
      sink.removeBarrier = Completer<void>();
      final first = session.logout();
      await sink.removeStarted!.future;
      final second = session.logout();
      expect(identical(first, second), isTrue);
      sink.removeBarrier!.complete();
      await Future.wait([first, second]);
      expect(sink.removed, 1);
      expect(hits['/api/v1/xclient/logout'], 1);
    },
  );

  test(
    'a delayed secure write is drained before logout clears storage',
    () async {
      final controlled = _WriteBarrierStore(Map.of(store.values));
      final local = Session(api: api, store: controlled, client: client);
      addTearDown(local.dispose);
      final login = local.login('u@example.com', 'right-password');
      await controlled.started.future;
      final logout = local.logout();
      expect(local.state.isLoggedIn, isFalse);
      controlled.release.complete();
      await Future.wait([login, logout]);
      expect(controlled.values, isEmpty);
      expect(api.authorization, isNull);
    },
  );

  test('a delayed restore cannot restore credentials after logout', () async {
    final controlled = _ReadBarrierStore({
      ...store.values,
      SecureKeys.auth: 'Bearer stored',
    });
    final local = Session(api: api, store: controlled, client: client);
    addTearDown(local.dispose);
    final restoring = local.restore();
    await controlled.started.future;
    final logout = local.logout();
    controlled.release.complete();
    await Future.wait([restoring, logout]);
    expect(local.state.isLoggedIn, isFalse);
    expect(controlled.values, isEmpty);
    expect(api.authorization, isNull);
  });

  test(
    'secure deletion failure still exits in memory and attempts every key',
    () async {
      final failing = _DeleteFailureStore(Map.of(store.values));
      final local = Session(api: api, store: failing, client: client);
      addTearDown(local.dispose);
      await local.login('u@example.com', 'right-password');
      await expectLater(local.logout(), throwsA(isA<XbApiException>()));
      expect(local.state.isLoggedIn, isFalse);
      expect(local.state.message, contains('未能完全清除'));
      expect(local.identity, isNull);
      expect(api.authorization, isNull);
      expect(failing.deleted, SecureKeys.all);
      expect(failing.values.keys, [SecureKeys.auth]);
    },
  );

  test('restore picks the stored login up and registers', () async {
    await store.write(SecureKeys.auth, 'Bearer abc');
    await store.write(SecureKeys.email, 'u@example.com');
    await session.restore();
    expect(session.state.isLoggedIn, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(session.state.deviceRegistered, isTrue);
    expect(api.deviceId, device['id']);
  });

  test('XboardApi strips the subscription URL and token', () async {
    transport.handler = (_) => jsonResponse({
      'status': 'success',
      'data': {
        'plan_id': 1,
        'token': 'T0KEN1234',
        'subscribe_url': 'https://s.example.com/s/T0KEN1234',
        'u': 1,
      },
    });
    final summary = await XboardApi(api).subscribeSummary();
    expect(summary.containsKey('token'), isFalse);
    expect(summary.containsKey('subscribe_url'), isFalse);
    expect(summary['u'], 1);
  });

  test('XboardApi checkout and pages are unwrapped from raw bodies', () async {
    transport.handler = (r) => switch (r.uri.path) {
      '/api/v1/user/order/checkout' => jsonResponse({
        'type': 0,
        'data': 'https://qr.example.com/x',
      }),
      '/api/v1/user/notice/fetch' => jsonResponse({
        'data': [
          {'id': 1},
        ],
        'total': 9,
      }),
      '/api/v1/user/loginLog/fetch' => jsonResponse({
        'message': 'x',
      }, status: 404),
      _ => jsonResponse({'message': 'x'}, status: 404),
    };
    final xb = XboardApi(api);
    final pay = await xb.checkout(tradeNo: 'T1', method: 2);
    expect(pay.qrContent, 'https://qr.example.com/x');
    expect(pay.isPaid, isFalse);
    final page = await xb.notices();
    expect(page.total, 9);
    expect(page.items.single['id'], 1);
    expect(await xb.loginLog(), isNull);
  });

  test('StatePoller verifies the policy and uses ETag', () async {
    await session.login('u@example.com', 'right-password');
    final policyDoc = (v['policy'] as Map)['doc'];
    final ctrl = TrustedKeys.fromB64u(
      ((v['keys'] as Map)['ctrl'] as Map).cast<String, String>(),
    );
    transport.handler = _wrap(transport.handler, '/api/v1/xclient/state', () {
      return jsonResponse(
        {
          'ok': true,
          'data': {
            'boot_seq': 7,
            'policy_seq': 3,
            'policy': policyDoc,
            'notice': null,
          },
        },
        headers: {'etag': '"abc"'},
      );
    });
    final poller = StatePoller(
      api: api,
      session: session,
      ctrlKeys: () => ctrl,
      brandId: 'demo',
      now: () => fromUnix(now),
    );
    await poller.pollNow();
    expect(poller.state.policy?.latest, '1.2.0');
    expect(poller.state.bootSeq, 7);
    transport.handler = _wrap(
      transport.handler,
      '/api/v1/xclient/state',
      () => TransportResponse(statusCode: 304, body: Uint8List(0)),
    );
    await poller.pollNow();
    final last = transport.requests.last;
    expect(last.headers['if-none-match'], '"abc"');
    expect(poller.state.policy?.seq, 12);
    poller.dispose();
  });
}

FakeHandler _wrap(
  FakeHandler inner,
  String path,
  TransportResponse Function() reply,
) {
  return (request) => request.uri.path == path ? reply() : inner(request);
}

class _WriteBarrierStore extends MemorySecureStore {
  _WriteBarrierStore(super.values);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    if (key == SecureKeys.auth && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    await super.write(key, value);
  }
}

class _ReadBarrierStore extends MemorySecureStore {
  _ReadBarrierStore(super.values);
  final started = Completer<void>();
  final release = Completer<void>();
  @override
  Future<String?> read(String key) async {
    if (key == SecureKeys.auth && !started.isCompleted) {
      started.complete();
      await release.future;
    }
    return super.read(key);
  }
}

class _DeleteFailureStore extends MemorySecureStore {
  _DeleteFailureStore(super.values);
  final deleted = <String>[];
  @override
  Future<void> delete(String key) async {
    deleted.add(key);
    if (key == SecureKeys.auth) throw StateError('keychain refused deletion');
    await super.delete(key);
  }
}
