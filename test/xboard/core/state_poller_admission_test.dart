import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/auth/session.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/crypto/signed_doc.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/sync/state_poller.dart';
import 'package:fl_clash/xboard/core/sync/policy_cache.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  late _Harness h;
  setUp(() async {
    h = await _Harness.create();
  });
  tearDown(() => h.dispose());

  test('state without a signed policy does not count as checked', () async {
    h.reply = jsonResponse({
      'ok': true,
      'data': {'policy_seq': 9, 'policy': null},
    });
    await h.poller.pollNow();
    expect(h.poller.state.checkedAt, isNull);
  });

  test('304 without an authenticated policy baseline is not checked', () async {
    h.reply = TransportResponse(statusCode: 304, body: Uint8List(0));
    await h.poller.pollNow();
    expect(h.poller.state.checkedAt, isNull);
  });

  test('signed malformed policy sequence is refused', () async {
    h.reply = await h.response({'seq': '9'});
    await h.poller.pollNow();
    expect(h.poller.state.policy, isNull);
    expect(h.poller.state.checkedAt, isNull);
  });

  test('state arriving after logout cannot publish its force policy', () async {
    final pending = Completer<TransportResponse>();
    h.stateHandler = () => pending.future;
    final poll = h.poller.pollNow();
    await Future<void>.delayed(Duration.zero);
    await h.session.logout();
    await h.session.login('next@example.com', 'password');
    pending.complete(await h.response({'force': true, 'latest': '2.0.0'}));
    await poll;
    expect(h.poller.state.policy, isNull);
    expect(h.poller.state.checkedAt, isNull);
  });

  test('a slow or failed state request never grants a connection', () async {
    final pending = Completer<TransportResponse>();
    h.stateHandler = () => pending.future;
    final running = h.poller.pollNow();
    await Future<void>.delayed(Duration.zero);
    expect(h.poller.state.phase, PolicyCheckPhase.checking);
    expect(h.poller.state.canConnect, isFalse);
    pending.completeError(StateError('offline'));
    await running;
    expect(h.poller.state.phase, PolicyCheckPhase.error);
    expect(h.poller.state.canConnect, isFalse);
  });

  test(
    'a current-session signed no-update policy grants and validates 304',
    () async {
      h.reply = await h.response({});
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isTrue);
      h.reply = TransportResponse(statusCode: 304, body: Uint8List(0));
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isTrue);
      expect(h.stateRequests.last.headers['if-none-match'], '"policy-9"');
    },
  );

  test(
    'a new hint blocks until its sequence is verified and rejects 304',
    () async {
      h.reply = await h.response({});
      await h.poller.pollNow();
      h.poller.requirePolicy(10);
      expect(h.poller.state.canConnect, isFalse);
      h.reply = TransportResponse(statusCode: 304, body: Uint8List(0));
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isFalse);
      h.reply = await h.response({'seq': 10});
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isTrue);
      expect(h.poller.state.policy?.seq, 10);
    },
  );

  test(
    'a same-sequence content change cannot clear force or replace cache',
    () async {
      h.reply = await h.response({'force': true, 'latest': '2.0.0'});
      await h.poller.pollNow();
      final saved = h.cache.content;
      h.reply = await h.response({});
      await h.poller.pollNow();
      expect(h.poller.state.phase, PolicyCheckPhase.error);
      expect(h.poller.state.policy?.mustUpdate('1.0.0'), isTrue);
      expect(h.cache.content, saved);
    },
  );

  test(
    'a restart rechecks signed force and never treats disk as online permission',
    () async {
      h.reply = await h.response({'force': true, 'latest': '2.0.0'});
      await h.poller.pollNow();
      h.restartPoller();
      await h.poller.loadCache();
      expect(h.poller.state.policy?.mustUpdate('1.0.0'), isTrue);
      expect(h.poller.state.canConnect, isFalse);
      h.reply = TransportResponse(statusCode: 304, body: Uint8List(0));
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isFalse);
      expect(
        h.stateRequests.last.headers.containsKey('if-none-match'),
        isFalse,
      );
    },
  );

  test(
    'expired cached force stays blocked while a newer version satisfies it',
    () async {
      final sec = h.now.millisecondsSinceEpoch ~/ 1000;
      h.reply = await h.response({
        'force': true,
        'latest': '2.0.0',
        'expires_at': sec + 1,
      });
      await h.poller.pollNow();
      h.now = h.now.add(const Duration(seconds: 2));
      h.restartPoller();
      await h.poller.loadCache();
      expect(h.poller.state.policy?.mustUpdate('1.0.0'), isTrue);
      expect(h.poller.state.policy?.mustUpdate('2.0.0'), isFalse);
      expect(h.poller.state.canConnect, isFalse);
    },
  );

  test(
    'a restarted non-force cache still needs online proof and prevents rollback',
    () async {
      h.reply = await h.response({'seq': 10});
      await h.poller.pollNow();
      final saved = h.cache.content;
      h.restartPoller();
      await h.poller.loadCache();
      expect(h.poller.state.canConnect, isFalse);
      h.reply = await h.response({});
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isFalse);
      expect(h.cache.content, saved);
      h.reply = await h.response({'seq': 10});
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isTrue);
    },
  );

  test('an old pending poll cannot clobber a new session poll', () async {
    final old = Completer<TransportResponse>();
    h.stateHandler = () => old.future;
    final previous = h.poller.pollNow();
    await Future<void>.delayed(Duration.zero);
    await h.session.logout();
    await h.session.login('new@example.com', 'password');
    final next = Completer<TransportResponse>();
    h.stateHandler = () => next.future;
    final current = h.poller.pollNow();
    await Future<void>.delayed(Duration.zero);
    old.complete(await h.response({'force': true, 'latest': '9.0.0'}));
    await previous;
    expect(identical(h.poller.pollNow(), current), isTrue);
    next.complete(await h.response({}));
    await current;
    expect(h.poller.state.canConnect, isTrue);
    expect(h.poller.state.policy?.force, isFalse);
  });

  test(
    'a hint arriving during cache commit cannot admit the old sequence',
    () async {
      h.cache.started = Completer<void>();
      h.cache.release = Completer<void>();
      h.reply = await h.response({});
      final running = h.poller.pollNow();
      await h.cache.started!.future;
      h.poller.requirePolicy(10);
      h.cache.release!.complete();
      await running;
      expect(h.poller.state.canConnect, isFalse);
    },
  );
  test(
    'same-sequence expiry renewal preserves policy content identity',
    () async {
      final sec = h.now.millisecondsSinceEpoch ~/ 1000;
      h.reply = await h.response({'issued_at': sec, 'expires_at': sec + 60});
      await h.poller.pollNow();
      h.reply = await h.response({
        'issued_at': sec + 1,
        'expires_at': sec + 120,
      });
      await h.poller.pollNow();
      expect(h.poller.state.canConnect, isTrue);
      expect(h.poller.state.policy?.seq, 9);
    },
  );
  for (final invalid in <Map<String, Object?>>[
    {'brand': 'other'},
    {'force': 'false'},
    {'latest': 'broken'},
    {'min_supported': '1.0.0+not-a-build-number'},
    {
      'release_urls': ['http://example.com/release.json'],
    },
    {'expires_at': 1},
    {'issued_at': 'tomorrow'},
  ]) {
    test(
      'signed malformed or expired policy is refused: ${invalid.keys.single}',
      () async {
        h.reply = await h.response(invalid);
        await h.poller.pollNow();
        expect(h.poller.state.canConnect, isFalse);
        expect(h.poller.state.checkedAt, isNull);
      },
    );
  }
}

class _Cache extends MemoryPolicyCache {
  Completer<void>? started;
  Completer<void>? release;
  @override
  Future<void> write(String content) async {
    if (started?.isCompleted == false) started!.complete();
    await release?.future;
    await super.write(content);
  }
}

class _Harness {
  late final ApiClient api;
  late final Session session;
  late StatePoller poller;
  late final SimpleKeyPair key;
  late final TrustedKeys keys;
  final cache = _Cache();
  final stateRequests = <TransportRequest>[];
  TransportResponse? reply;
  FutureOr<TransportResponse> Function()? stateHandler;
  DateTime now = DateTime.utc(2026, 11, 4);

  static Future<_Harness> create() async {
    final h = _Harness();
    h.key = await Ed25519().newKeyPairFromSeed(
      List<int>.generate(32, (i) => i),
    );
    final public = await h.key.extractPublicKey();
    final transport = FakeTransport((r) {
      if (r.uri.path.endsWith('/state')) h.stateRequests.add(r);
      return switch (r.uri.path) {
        '/api/v1/passport/auth/login' => jsonResponse({
          'data': {'auth_data': 'Bearer test-only'},
        }),
        '/api/v1/xclient/device/register' => jsonResponse({
          'ok': true,
          'data': {'device_id': 'test-device'},
        }),
        '/api/v1/user/info' => jsonResponse({
          'data': {'plan_id': 1},
        }),
        '/api/v1/xclient/logout' => jsonResponse({'ok': true, 'data': {}}),
        '/api/v1/xclient/state' =>
          h.stateHandler?.call() ??
              h.reply ??
              jsonResponse({'ok': true, 'data': {}}),
        _ => jsonResponse({'message': 'absent'}, status: 404),
      };
    });
    h.api = ApiClient(
      transport: transport,
      pool: EndpointPool(
        endpoints: const [ApiEndpointSpec('https://api.example.com')],
      ),
      userAgent: 'test',
    );
    h.session = Session(
      api: h.api,
      store: MemorySecureStore(),
      client: const ClientInfo(
        platform: XcPlatform.android,
        arch: 'arm64-v8a',
        appVersion: '1.0.0',
        build: '1',
        osVersion: '14',
        deviceName: 'Test',
      ),
    );
    await h.session.login('test@example.com', 'password');
    h.keys = TrustedKeys({'test': public.bytes});
    h.restartPoller(initial: true);
    return h;
  }

  Future<Map<String, dynamic>> doc(Map<String, Object?> overrides) async {
    final payload = b64uEncode(
      utf8.encode(
        jsonEncode({
          'brand': 'example',
          'seq': 9,
          'latest': null,
          'min_supported': null,
          'force': false,
          'notes': '',
          'release_urls': <String>[],
          ...overrides,
        }),
      ),
    );
    final signature = await Ed25519().sign(
      utf8.encode('${SignedDocKind.policy}$payload'),
      keyPair: key,
    );
    return {
      'v': 1,
      'kid': 'test',
      'payload': payload,
      'sig': b64uEncode(signature.bytes),
    };
  }

  Future<TransportResponse> response(Map<String, Object?> overrides) async =>
      jsonResponse(
        {
          'ok': true,
          'data': {'policy_seq': 9, 'policy': await doc(overrides)},
        },
        headers: {'etag': '"policy-9"'},
      );

  void restartPoller({bool initial = false}) {
    if (!initial) poller.dispose();
    poller = StatePoller(
      api: api,
      session: session,
      ctrlKeys: () => keys,
      brandId: 'example',
      cache: cache,
      now: () => now,
    );
  }

  void dispose() {
    poller.dispose();
    session.dispose();
  }
}
