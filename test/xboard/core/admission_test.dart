import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/auth/session.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/crypto/aead.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/crypto/device_keys.dart';
import 'package:fl_clash/xboard/core/crypto/envelope.dart';
import 'package:fl_clash/xboard/core/crypto/signed_doc.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _reason = '当前网络触发订阅风控，请关闭其他代理或更换网络后重新检查；仍有问题请联系客服。';

class _AdmissionSink implements ManagedProfileSink {
  int applied = 0;
  int removed = 0;
  bool cached = true;
  bool removalFails = false;
  Completer<void>? application;
  Completer<void>? applyStarted;
  SyncPhase? phaseOnRemove;
  SubscriptionSync? sync;
  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {
    applyStarted?.complete();
    await application?.future;
    applied++;
    cached = true;
  }

  @override
  Future<void> remove() async {
    removed++;
    phaseOnRemove = sync?.status.phase;
    if (removalFails) throw StateError('stop/remove failed');
    cached = false;
  }
}

Future<Map<String, dynamic>> _seal(
  Map<String, dynamic> vector,
  Map<String, Object?> plain,
) async {
  final device = vector['device'] as Map;
  final sample = ((vector['envelope'] as Map)['ok'] as Map)
      .cast<String, dynamic>();
  final h = sample['h'] as String;
  final header = jsonDecode(b64uDecodeUtf8(h)) as Map;
  final deviceKeys = await DeviceKeyPair.fromPrivate(
    b64uDecode(device['sk'] as String),
  );
  final epk = b64uDecode(header['epk'] as String);
  final shared = await deviceKeys.sharedSecret(epk);
  final key = await hkdfSha256(
    ikm: shared,
    salt: b64uDecode(header['salt'] as String),
    info: [
      ...utf8.encode(envelopeInfoLabel),
      0,
      ...epk,
      ...deviceKeys.publicKey,
      ...utf8.encode(device['id'] as String),
    ],
  );
  final ciphertext = b64uEncode(
    await xchachaSeal(
      key: key,
      nonce: b64uDecode(header['nonce'] as String),
      plain: utf8.encode(jsonEncode(plain)),
      aad: ascii.encode(h),
    ),
  );
  final seed = await sha256Bytes(utf8.encode('xclient-test/env-1'));
  final signature = await Ed25519().sign(
    ascii.encode('$envelopeSigPrefix$h.$ciphertext'),
    keyPair: await Ed25519().newKeyPairFromSeed(seed),
  );
  return {'h': h, 'ct': ciphertext, 'sig': b64uEncode(signature.bytes)};
}

void main() {
  final vector = loadVectors('envelope_v1_core.json');
  final device = vector['device'] as Map;
  final envKeys = TrustedKeys.fromB64u(
    ((vector['keys'] as Map)['env'] as Map).cast<String, String>(),
  );
  late Session session;
  late SubscriptionSync sync;
  late _AdmissionSink sink;
  late FakeTransport transport;
  late ScriptedRandom random;
  late DateTime clock;
  late Map<String, Object?> plain;
  int requests = 0;
  Object? transportFailure;
  Completer<void>? responseBarrier;

  setUp(() async {
    clock = fromUnix(vector['now'] as int);
    plain = {
      'status': 200,
      'headers': <String, String>{},
      'body_b64': b64uEncode(
        utf8.encode('proxies: []\nproxy-groups: []\nrules: []'),
      ),
    };
    requests = 0;
    transportFailure = null;
    responseBarrier = null;
    sink = _AdmissionSink();
    transport = FakeTransport((request) async {
      switch (request.uri.path) {
        case '/api/v1/xclient/device/register':
          return jsonResponse({'ok': true, 'data': {}});
        case '/api/v1/user/info':
          return jsonResponse({
            'status': 'success',
            'data': {'email': 'demo@example.invalid'},
          });
        case '/api/v1/xclient/logout':
          return jsonResponse({'ok': true, 'data': {}});
        case '/api/v1/xclient/subscribe':
          requests++;
          await responseBarrier?.future;
          if (transportFailure case final TransportResponse response) {
            return response;
          }
          if (transportFailure case final Exception error) throw error;
          if (transportFailure case final Error error) throw error;
          return jsonResponse({'ok': true, 'data': await _seal(vector, plain)});
        default:
          return jsonResponse({'message': 'not found'}, status: 404);
      }
    });
    final api = ApiClient(
      transport: transport,
      pool: EndpointPool(
        endpoints: const [ApiEndpointSpec('https://api.example.invalid')],
      ),
      userAgent: 'demoClient/1.0.0',
      now: () => clock,
    );
    session = Session(
      api: api,
      store: MemorySecureStore({
        SecureKeys.auth: 'Bearer test',
        SecureKeys.deviceId: device['id'] as String,
        SecureKeys.deviceSk: device['sk'] as String,
      }),
      client: const ClientInfo(
        platform: XcPlatform.android,
        arch: 'arm64-v8a',
        appVersion: '1.0.0',
        build: '100',
        osVersion: '14',
        deviceName: 'demo',
      ),
    );
    random = ScriptedRandom(
      b64uDecode((vector['envelope'] as Map)['req_nonce'] as String),
    );
    sync = SubscriptionSync(
      api: api,
      session: session,
      sink: sink,
      envKeys: () => envKeys,
      directHosts: () => api.pool.hosts,
      label: 'Demo',
      now: () => clock,
      random: random,
    );
    sink.sync = sync;
    await session.restore();
    await session.ensureRegistered();
  });
  tearDown(() {
    sync.dispose();
    session.dispose();
  });
  Future<SyncStatus> pull() {
    random.reset();
    return sync.syncNow();
  }

  void restrict({int status = 200, int retry = 60}) {
    plain = {
      ...plain,
      'status': status,
      'admission': {
        'status': 'blocked',
        'code': 'subscription_restricted',
        'message': _reason,
        'retry_after': retry,
      },
    };
  }

  test(
    'sealed 200 admission refuses notice nodes and removes cached profiles',
    () async {
      restrict();
      final status = await pull();
      expect(status.phase, SyncPhase.blocked);
      expect(status.message, contains('当前网络触发订阅风控'));
      expect(status.lastSuccess, isNull);
      expect(sink.applied, 0);
      expect(sink.removed, 1);
      expect(sink.cached, isFalse);
      expect(sink.phaseOnRemove, SyncPhase.blocked);
      expect(session.state.isLoggedIn, isTrue);
    },
  );
  test(
    'legacy encrypted 403 clears old nodes without logging out the account',
    () async {
      plain = {...plain, 'status': 403};
      final status = await pull();
      expect(status.phase, SyncPhase.blocked);
      expect(sink.removed, 1);
      expect(sink.cached, isFalse);
      expect(session.state.isLoggedIn, isTrue);
    },
  );
  test(
    'failed cleanup cannot downgrade the blocked state into a connectable error',
    () async {
      restrict();
      sink.removalFails = true;
      final status = await pull();
      expect(status.phase, SyncPhase.blocked);
      expect(status.lastSuccess, isNull);
      expect(sink.applied, 0);
    },
  );
  test(
    'center throttle coalesces inflight calls and enforces ten seconds',
    () async {
      responseBarrier = Completer<void>();
      final first = pull();
      expect(identical(sync.syncNow(), first), isTrue);
      await Future<void>.delayed(Duration.zero);
      responseBarrier!.complete();
      await first;
      await pull();
      expect(requests, 1);
      clock = clock.add(const Duration(seconds: 9));
      await pull();
      expect(requests, 1);
      clock = clock.add(const Duration(seconds: 1));
      await pull();
      expect(requests, 2);
    },
  );
  test(
    'new admission metadata is authenticated and old vectors remain compatible',
    () async {
      final keys = await DeviceKeyPair.fromPrivate(
        b64uDecode(device['sk'] as String),
      );
      final nonce = (vector['envelope'] as Map)['req_nonce'] as String;
      restrict(retry: 90);
      final opened = await openEnvelope(
        await _seal(vector, plain),
        device: keys,
        deviceId: device['id'] as String,
        reqNonce: nonce,
        envKeys: envKeys,
        now: vector['now'] as int,
      );
      expect(opened.admission?.blocked, isTrue);
      expect(opened.admission?.code, 'subscription_restricted');
      expect(opened.admission?.message, _reason);
      expect(opened.admission?.retryAfter, const Duration(seconds: 90));
      final legacy = await openEnvelope(
        ((vector['envelope'] as Map)['ok'] as Map).cast<String, dynamic>(),
        device: keys,
        deviceId: device['id'] as String,
        reqNonce: nonce,
        envKeys: envKeys,
        now: vector['now'] as int,
      );
      expect(legacy.admission, isNull);
      expect(legacy.status, 200);
    },
  );
  test(
    'recovery remains blocked until the allowed configuration is applied',
    () async {
      restrict();
      await pull();
      clock = clock.add(const Duration(seconds: 10));
      plain.remove('admission');
      sink.application = Completer<void>();
      sink.applyStarted = Completer<void>();
      final recovering = pull();
      await sink.applyStarted!.future;
      expect(sync.status.phase, SyncPhase.blocked);
      expect(sync.status.lastSuccess, isNull);
      sink.application!.complete();
      final recovered = await recovering;
      expect(recovered.phase, SyncPhase.ok);
      expect(recovered.lastSuccess, isNotNull);
      expect(recovered.blockedCode, isNull);
      expect(recovered.cleanupWarning, isNull);
      expect(recovered.message, isNull);
      expect(sink.cached, isTrue);
    },
  );
  test(
    'temporary network failure preserves the last permitted cached profile',
    () async {
      await pull();
      final last = sync.status.lastSuccess;
      clock = clock.add(const Duration(seconds: 10));
      transportFailure = const TransportException(
        TransportFailure.connect,
        beforeSend: true,
      );
      final status = await pull();
      expect(status.phase, SyncPhase.error);
      expect(status.lastSuccess, last);
      expect(sink.cached, isTrue);
      expect(sink.removed, 0);
    },
  );
  test(
    'a network error while restricted does not lift the existing restriction',
    () async {
      restrict();
      await pull();
      clock = clock.add(const Duration(seconds: 10));
      transportFailure = const TransportException(
        TransportFailure.connect,
        beforeSend: true,
      );
      final status = await pull();
      expect(status.phase, SyncPhase.blocked);
      expect(status.message, _reason);
      expect(status.lastSuccess, isNull);
      expect(sink.cached, isFalse);
      expect(
        status.nextSync!.difference(clock),
        lessThanOrEqualTo(const Duration(minutes: 5)),
      );
    },
  );
  test(
    'automatic restriction retry backs off to five minutes and cannot be shortened by seq or connectivity bursts',
    () async {
      restrict();
      sync.start();
      for (final expected in [60, 120, 240, 300]) {
        final status = await pull();
        final remaining = status.nextSync!.difference(clock);
        expect(remaining, greaterThanOrEqualTo(Duration(seconds: expected)));
        expect(remaining, lessThanOrEqualTo(const Duration(minutes: 5)));
        final scheduled = sync.status.nextSync;
        sync.requestSync(delay: Duration.zero);
        sync.requestSync(delay: Duration.zero);
        expect(sync.status.nextSync, scheduled);
        clock = clock.add(const Duration(seconds: 10));
      }
    },
  );
  test(
    'a server restriction retry_after longer than backoff is respected',
    () async {
      restrict(retry: 600);
      final status = await pull();
      expect(status.nextSync!.difference(clock), const Duration(minutes: 10));
    },
  );
  test(
    'HTTP 403 admission denial also removes cache but leaves the account signed in',
    () async {
      transportFailure = jsonResponse({
        'ok': false,
        'error': 'subscription_restricted',
        'message': _reason,
      }, status: 403);
      final status = await pull();
      expect(status.phase, SyncPhase.blocked);
      expect(status.message, _reason);
      expect(sink.cached, isFalse);
      expect(session.state.isLoggedIn, isTrue);
    },
  );
  test('429 server cooldown also restricts manual rechecks', () async {
    plain = {
      ...plain,
      'status': 429,
      'headers': {'retry-after': '600'},
    };
    final status = await pull();
    expect(status.retryAt!.difference(clock), const Duration(minutes: 10));
    clock = clock.add(const Duration(seconds: 10));
    await pull();
    expect(requests, 1);
  });
  test(
    'explicit denial wins even when the server returned an unusable body',
    () async {
      restrict();
      plain['body_b64'] = 'not valid base64 ###';
      final status = await pull();
      expect(status.phase, SyncPhase.blocked);
      expect(sink.applied, 0);
      expect(sink.cached, isFalse);
    },
  );
}
