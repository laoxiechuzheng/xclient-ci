import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/runtime.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/push/sequence_hint_gate.dart';

import 'package:fl_clash/xboard/core/push/push_client.dart';
import 'package:fl_clash/xboard/core/push/push_events.dart';
import 'package:fl_clash/xboard/core/push/push_ticket.dart';
import 'package:fl_clash/xboard/core/push/push_transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

class _Tickets implements PushTicketIssuer {
  var issued = 0;
  var cancelled = 0;
  Completer<PushTicket>? pending;

  @override
  Future<PushTicket> issue() async {
    issued++;
    return pending?.future ??
        PushTicket(
          uri: Uri.parse('https://panel.example/api/v1/xclient/events'),
          value: 'a' * 43,
        );
  }

  @override
  void cancel() {
    cancelled++;
  }
}

class _Streams implements PushTransport {
  final opened = <PushTicket>[];
  final controllers = <StreamController<List<int>>>[];
  var closes = 0;

  @override
  Future<PushConnection> open(
    PushTicket ticket, {
    required String userAgent,
  }) async {
    opened.add(ticket);
    final controller = StreamController<List<int>>();
    controllers.add(controller);
    return PushConnection(
      body: controller.stream,
      cancel: () {
        if (!controller.isClosed) unawaited(controller.close());
      },
    );
  }

  @override
  void close() {
    closes++;
    for (final controller in controllers) {
      if (!controller.isClosed) unawaited(controller.close());
    }
  }
}

class _CancellationErrorTransport implements PushTransport {
  var cancellations = 0;
  StreamController<List<int>>? _controller;
  StreamController<List<int>> get controller => _controller!;
  @override
  Future<PushConnection> open(
    PushTicket ticket, {
    required String userAgent,
  }) async {
    _controller = StreamController<List<int>>(
      onCancel: () {
        cancellations++;
        return Future<void>.error(
          const HttpException('Expected closed test connection'),
        );
      },
    );
    return PushConnection(body: controller.stream, cancel: close);
  }

  @override
  void close() {
    if (_controller != null && !_controller!.isClosed) {
      unawaited(_controller!.close());
    }
  }
}

class _TrackedTransport extends FakeTransport {
  _TrackedTransport(super.handler);
  var closed = 0;
  @override
  void close() {
    closed++;
  }
}

class _Sink implements ManagedProfileSink {
  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {}
  @override
  Future<void> remove() async {}
}

void main() {
  testWidgets(
    'reconnect cancels a pending ticket and discards its late result',
    (tester) async {
      final old = Completer<PushTicket>();
      final next = Completer<PushTicket>();
      final tickets = _Tickets()..pending = old;
      final streams = _Streams();
      final client = XcPushClient(
        tickets: tickets,
        transport: streams,
        userAgent: () => 'ExampleClient/1.0',
        onSeq: (_) {},
      );
      client.start();
      client.setSession(ready: true, generation: 1);
      await tester.pump();
      tickets.pending = next;
      client.reconnect();
      await tester.pump();
      old.complete(
        PushTicket(
          uri: Uri.parse('https://old.example.invalid/api/v1/xclient/events'),
          value: 'a' * 43,
        ),
      );
      await tester.pump();
      expect(streams.opened, isEmpty);
      next.complete(
        PushTicket(
          uri: Uri.parse('https://new.example.invalid/api/v1/xclient/events'),
          value: 'b' * 43,
        ),
      );
      await tester.pump();
      expect(streams.opened.single.uri.host, 'new.example.invalid');
      expect(tickets.issued, 2);
      client.dispose();
      await tester.pump();
    },
  );

  test(
    'SSE parser handles UTF8/chunk boundaries, CRLF, comments and multiline data',
    () async {
      final payload = utf8.encode(
        '\ufeff: 心跳\r\nevent: seq\r\ndata: {"boot_seq":\r\ndata: 7, "policy_seq":9}\r\n\r\n',
      );
      final parts = <List<int>>[
        for (var index = 0; index < payload.length; index++) [payload[index]],
      ];
      final events = await decodePushEvents(
        Stream.fromIterable(parts),
      ).toList();
      expect(events.single.boot, 7);
      expect(events.single.policy, 9);
    },
  );

  test(
    'SSE parser ignores unrelated events and invalid sequence values',
    () async {
      const payload =
          'event: update\ndata: {"boot_seq":1,"policy_seq":2}\n\nevent: seq\ndata: {"boot_seq":-1,"policy_seq":2}\n\nevent: seq\ndata: {"boot_seq":"1","policy_seq":2}\n\nevent: seq\ndata: {"boot_seq":1.5,"policy_seq":2}\n\n';
      expect(
        await decodePushEvents(Stream.value(utf8.encode(payload))).toList(),
        isEmpty,
      );
    },
  );

  test(
    'SSE rejects an oversized line before the terminating newline',
    () async {
      await expectLater(
        decodePushEvents(
          Stream.value(utf8.encode('data: ${'x' * 5000}')),
        ).drain<void>(),
        throwsA(isA<PushException>()),
      );
    },
  );

  testWidgets(
    'foreground/session generations cancel stale tickets and preserve reconnection backoff',
    (tester) async {
      final tickets = _Tickets()..pending = Completer<PushTicket>();
      final streams = _Streams();
      final seen = <int?>[];
      final client = XcPushClient(
        tickets: tickets,
        transport: streams,
        userAgent: () => 'ExampleClient/1.0',
        onSeq: (seq) => seen.add(seq.boot),
        randomInt: (_) => 0,
      );
      client.start();
      client.setSession(ready: true, generation: 1);
      await tester.pump();
      expect(tickets.issued, 1);
      client.setSession(ready: false, generation: 2);
      tickets.pending!.complete(
        PushTicket(
          uri: Uri.parse('https://panel.example/api/v1/xclient/events'),
          value: 'a' * 43,
        ),
      );
      await tester.pump();
      expect(streams.opened, isEmpty);
      expect(seen, isEmpty);
      tickets.pending = null;
      client.setSession(ready: true, generation: 3);
      await tester.pump();
      expect(streams.opened.length, 1);
      streams.controllers.last.add(
        utf8.encode('event: seq\ndata: {"boot_seq":3,"policy_seq":4}\n\n'),
      );
      await tester.pump();
      expect(seen, [3]);
      await streams.controllers.last.close();
      await tester.pump();
      final count = tickets.issued;
      await tester.pump(const Duration(milliseconds: 999));
      expect(tickets.issued, count);
      await tester.pump(const Duration(milliseconds: 1));
      expect(tickets.issued, count + 1);
      client.setForeground(false);
      final background = tickets.issued;
      await tester.pump(const Duration(minutes: 20));
      expect(tickets.issued, background);
      client.setForeground(true);
      await tester.pump();
      expect(tickets.issued, background + 1);
      client.dispose();
      await tester.pump();
    },
  );
  test(
    'ticket follows the successful API endpoint despite a different pool current',
    () async {
      final pool = EndpointPool(
        endpoints: const [
          ApiEndpointSpec('https://a.example'),
          ApiEndpointSpec('https://b.example'),
        ],
      );
      final mainTransport = FakeTransport(
        (_) => throw StateError('main transport must not issue tickets'),
      );
      final api =
          ApiClient(
              transport: mainTransport,
              pool: pool,
              userAgent: 'ExampleClient/1.0',
            )
            ..authorization = 'Bearer dummy'
            ..deviceId = 'device';
      final transport = _TrackedTransport((request) {
        if (request.uri.host == 'a.example') connectFailure();
        expect(request.method, 'POST');
        expect(request.uri.path, '/api/v1/xclient/push/ticket');
        expect(request.headers['x-xclient-device'], 'device');
        expect(request.headers['authorization'], 'Bearer dummy');
        expect(utf8.decode(request.body!), '{}');
        return jsonResponse({
          'ok': true,
          'data': {
            'ticket': 'A' * 43,
            'expires_in': 60,
            'path': '/api/v1/xclient/events',
          },
        });
      });
      final issuer = ApiPushTicketIssuer(
        api: api,
        transportFactory: () => transport,
      );
      final ticket = await issuer.issue();
      pool.replace(const [ApiEndpointSpec('https://c.example')]);
      expect(ticket.uri.toString(), 'https://b.example/api/v1/xclient/events');
      expect(ticket.uri.hasQuery, isFalse);
      expect(transport.closed, 1);
      issuer.cancel();
    },
  );

  test('late unauthorized ticket responses cannot end a newer login', () async {
    final reply = Completer<TransportResponse>();
    final pool = EndpointPool(
      endpoints: const [ApiEndpointSpec('https://a.example')],
    );
    final api =
        ApiClient(
            transport: FakeTransport((_) => throw StateError('unused')),
            pool: pool,
            userAgent: 'ExampleClient/1.0',
          )
          ..authorization = 'Bearer old'
          ..deviceId = 'old-device';
    var errors = 0;
    api.addErrorListener((_) => errors++);
    final transport = _TrackedTransport((_) => reply.future);
    final issuer = ApiPushTicketIssuer(
      api: api,
      transportFactory: () => transport,
    );
    final pending = issuer.issue();
    api
      ..authorization = 'Bearer new'
      ..deviceId = 'new-device';
    reply.complete(
      jsonResponse({'ok': false, 'error': 'unauthorized'}, status: 401),
    );
    await expectLater(pending, throwsA(isA<PushException>()));
    expect(errors, 0);
    expect(api.authorization, 'Bearer new');
    issuer.cancel();
  });

  test(
    'current unauthorized ticket responses notify the session exactly once',
    () async {
      final pool = EndpointPool(
        endpoints: const [ApiEndpointSpec('https://a.example')],
      );
      final api =
          ApiClient(
              transport: FakeTransport((_) => throw StateError('unused')),
              pool: pool,
              userAgent: 'ExampleClient/1.0',
            )
            ..authorization = 'Bearer dummy'
            ..deviceId = 'device';
      var errors = 0;
      api.addErrorListener((_) => errors++);
      final issuer = ApiPushTicketIssuer(
        api: api,
        transportFactory: () => _TrackedTransport(
          (_) =>
              jsonResponse({'ok': false, 'error': 'unauthorized'}, status: 401),
        ),
      );
      await expectLater(
        issuer.issue(),
        throwsA(
          isA<XbApiException>().having(
            (error) => error.kind,
            'kind',
            XbErrorKind.unauthorized,
          ),
        ),
      );
      expect(errors, 1);
      issuer.cancel();
    },
  );

  test(
    'cancelling tickets immediately closes only the dedicated transport',
    () async {
      final reply = Completer<TransportResponse>();
      final main = _TrackedTransport((_) => throw StateError('unused'));
      final dedicated = _TrackedTransport((_) => reply.future);
      final api =
          ApiClient(
              transport: main,
              pool: EndpointPool(
                endpoints: const [ApiEndpointSpec('https://a.example')],
              ),
              userAgent: 'ExampleClient/1.0',
            )
            ..authorization = 'Bearer dummy'
            ..deviceId = 'device';
      final issuer = ApiPushTicketIssuer(
        api: api,
        transportFactory: () => dedicated,
      );
      final pending = issuer.issue();
      issuer.cancel();
      expect(dedicated.closed, 1);
      expect(main.closed, 0);
      reply.complete(
        jsonResponse({
          'ok': true,
          'data': {
            'ticket': 'A' * 43,
            'expires_in': 60,
            'path': '/api/v1/xclient/events',
          },
        }),
      );
      await expectLater(pending, throwsA(isA<PushException>()));
    },
  );

  test(
    'the first hint compares with verified document versions and failed refreshes remain retryable',
    () {
      var date = DateTime.utc(2026);
      final gate = SequenceHintGate(now: () => date);
      const seq = XClientSeq(boot: 6, policy: 8);
      expect(gate.react(seq, bootFloor: 5, policyFloor: 7), (
        boot: true,
        policy: true,
      ));
      expect(gate.react(seq, bootFloor: 5, policyFloor: 7), (
        boot: false,
        policy: false,
      ));
      date = date.add(const Duration(seconds: 10));
      expect(gate.react(seq, bootFloor: 5, policyFloor: 7), (
        boot: true,
        policy: true,
      ));
      date = date.add(const Duration(seconds: 10));
      expect(gate.react(seq, bootFloor: 6, policyFloor: 8), (
        boot: false,
        policy: false,
      ));
    },
  );

  testWidgets(
    'repeated short streams back off exponentially and stop leaves no timer',
    (tester) async {
      final tickets = _Tickets();
      final streams = _Streams();
      final client = XcPushClient(
        tickets: tickets,
        transport: streams,
        userAgent: () => 'ExampleClient/1.0',
        onSeq: (_) {},
        randomInt: (_) => 0,
        now: () => tester.binding.clock.now(),
      );
      client.start();
      client.setSession(ready: true, generation: 1);
      await tester.pump();
      for (final seconds in [1, 2, 4, 8, 16, 32, 60, 60]) {
        final before = tickets.issued;
        await streams.controllers.last.close();
        await tester.pump();
        await tester.pump(
          Duration(seconds: seconds) - const Duration(milliseconds: 1),
        );
        expect(tickets.issued, before);
        await tester.pump(const Duration(milliseconds: 1));
        expect(tickets.issued, before + 1);
      }
      client.dispose();
      await tester.pump();
    },
  );

  testWidgets(
    'heartbeats maintain a stream and an idle stream is replaced after 45 seconds',
    (tester) async {
      final tickets = _Tickets();
      final streams = _Streams();
      final client = XcPushClient(
        tickets: tickets,
        transport: streams,
        userAgent: () => 'ExampleClient/1.0',
        onSeq: (_) {},
        randomInt: (_) => 0,
        now: () => tester.binding.clock.now(),
      );
      client.start();
      client.setSession(ready: true, generation: 1);
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 20));
        streams.controllers.last.add(utf8.encode(': heartbeat\n\n'));
        await tester.pump();
        expect(tickets.issued, 1);
      }
      await tester.pump(const Duration(seconds: 45));
      await tester.pump(const Duration(seconds: 1));
      expect(tickets.issued, 2);
      client.dispose();
      await tester.pump();
    },
  );
  test(
    'cancelling a pending ticket never penalizes the regular API endpoint',
    () async {
      final pending = Completer<TransportResponse>();
      final pool = EndpointPool(
        endpoints: const [ApiEndpointSpec('https://a.example')],
      );
      final api =
          ApiClient(
              transport: FakeTransport((_) => throw StateError('unused')),
              pool: pool,
              userAgent: 'ExampleClient/1.0',
            )
            ..authorization = 'Bearer dummy'
            ..deviceId = 'device';
      final issuer = ApiPushTicketIssuer(
        api: api,
        transportFactory: () => _TrackedTransport((_) => pending.future),
      );
      final result = issuer.issue();
      issuer.cancel();
      pending.completeError(const TransportException(TransportFailure.io));
      await expectLater(result, throwsA(isA<XbApiException>()));
      expect(pool.endpoints.single.consecutiveFailures, 0);
    },
  );

  test(
    'SSE bounds the accumulated event and discards an unterminated event',
    () async {
      final data =
          'event: seq\n${List.filled(5, 'data: ${'a' * 4000}\n').join()}\n';
      await expectLater(
        decodePushEvents(Stream.value(utf8.encode(data))).drain<void>(),
        throwsA(isA<PushException>()),
      );
      expect(
        await decodePushEvents(
          Stream.value(
            utf8.encode('event: seq\ndata: {"boot_seq":1,"policy_seq":2}'),
          ),
        ).toList(),
        isEmpty,
      );
    },
  );

  testWidgets(
    'runtime leaves background polling active when the push stream is suspended',
    (tester) async {
      final vectors = loadVectors('envelope_v1_core.json');
      final device = vectors['device'] as Map;
      final store = MemorySecureStore({
        SecureKeys.deviceId: device['id'] as String,
        SecureKeys.deviceSk: device['sk'] as String,
      });
      var stateRequests = 0;
      final transports = <_TrackedTransport>[];
      final streams = _Streams();
      final runtime = XClientRuntime(
        brand: BrandConfig(
          brandId: 'demo',
          displayName: 'Example',
          builtinApiEndpoints: const [ApiEndpointSpec('https://panel.example')],
          ctrlPubKeys: ((vectors['keys'] as Map)['ctrl'] as Map)
              .cast<String, String>(),
        ),
        client: const ClientInfo(
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '14',
          deviceName: 'Test',
        ),
        store: store,
        cache: MemoryBootstrapCache(
          jsonEncode({'v': 1, 'doc': (vectors['bootstrap'] as Map)['plain']}),
        ),
        sink: _Sink(),
        now: () => tester.binding.clock.now(),
        pushTransportFactory: ({pins, onPinReport}) => streams,
        transportFactory: ({pins, onPinReport}) {
          final transport = _TrackedTransport((request) {
            switch (request.uri.path) {
              case '/api/v1/passport/auth/login':
                return jsonResponse({
                  'data': {'auth_data': 'Bearer dummy'},
                });
              case '/api/v1/user/info':
                return jsonResponse({'data': <String, Object?>{}});
              case '/api/v1/xclient/device/register':
                return jsonResponse({'ok': true, 'data': <String, Object?>{}});
              case '/api/v1/xclient/push/ticket':
                return jsonResponse({
                  'ok': true,
                  'data': {
                    'ticket': 'A' * 43,
                    'expires_in': 60,
                    'path': '/api/v1/xclient/events',
                  },
                });
              case '/api/v1/xclient/state':
                stateRequests++;
                return jsonResponse({
                  'ok': true,
                  'data': {'boot_seq': 0, 'policy_seq': 0},
                });
              default:
                return jsonResponse({
                  'ok': false,
                  'error': 'not_found',
                }, status: 404);
            }
          });
          transports.add(transport);
          return transport;
        },
      );
      await runtime.start();
      await runtime.login('unit@example.test', 'dummy-password');
      await tester.pump();
      expect(streams.opened.length, 1);
      expect(stateRequests, greaterThan(0));
      runtime.setForeground(false);
      final before = stateRequests;
      final tickets = streams.opened.length;
      await tester.pump(const Duration(seconds: 899));
      expect(stateRequests, before);
      expect(streams.opened.length, tickets);
      await tester.pump(const Duration(seconds: 1));
      expect(stateRequests, before + 1);
      runtime.setForeground(true);
      await tester.pump();
      expect(streams.opened.length, tickets + 1);
      runtime.dispose();
      await tester.pump();
      expect(transports.every((transport) => transport.closed > 0), isTrue);
    },
  );
  testWidgets(
    'a socket cancellation error is contained during foreground suspension',
    (tester) async {
      final transport = _CancellationErrorTransport();
      final client = XcPushClient(
        tickets: _Tickets(),
        transport: transport,
        userAgent: () => 'ExampleClient/1.0',
        onSeq: (_) {},
      );
      client.start();
      client.setSession(ready: true, generation: 1);
      await tester.pump();
      transport.controller.add(utf8.encode(': heartbeat\n\n'));
      await tester.pump();
      client.setForeground(false);
      expect(transport.cancellations, 1);
      await tester.pump();
      client.dispose();
      await tester.pump();
    },
  );
}
