import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _a = 'https://a.example.com';
const _b = 'https://b.example.net';
const _c = 'https://c.example.org/panel';

void main() {
  group('EndpointPool', () {
    test('orders by weight, keeps the current one sticky', () {
      final pool = EndpointPool(
        endpoints: const [
          ApiEndpointSpec(_a, weight: 50),
          ApiEndpointSpec(_b, weight: 100),
        ],
      );
      expect(pool.current!.url, _b);
      pool.reportSuccess(_a, const Duration(milliseconds: 20));
      expect(pool.current!.url, _b);
      expect(pool.hosts, {'a.example.com', 'b.example.net'});
    });

    test('moves on after two consecutive failures and reports exhaustion', () {
      var failovers = 0;
      var exhausted = 0;
      final pool =
          EndpointPool(
              endpoints: const [ApiEndpointSpec(_a), ApiEndpointSpec(_b)],
            )
            ..onFailover = (() => failovers++)
            ..onExhausted = (() => exhausted++);
      expect(pool.current!.url, _a);
      expect(pool.reportFailure(_a), isFalse);
      expect(pool.current!.url, _a);
      expect(pool.reportFailure(_a), isTrue);
      expect(pool.current!.url, _b);
      expect(failovers, 1);
      pool
        ..reportFailure(_b)
        ..reportFailure(_b);
      expect(exhausted, 1);
      expect(pool.allDown, isTrue);
    });

    test('a success between failures resets the count', () {
      final pool = EndpointPool(
        endpoints: const [ApiEndpointSpec(_a), ApiEndpointSpec(_b)],
      );
      pool
        ..reportFailure(_a)
        ..reportSuccess(_a, const Duration(milliseconds: 10))
        ..reportFailure(_a);
      expect(pool.current!.url, _a);
    });

    test('replace keeps health and the current endpoint', () {
      final pool =
          EndpointPool(
              endpoints: const [ApiEndpointSpec(_a), ApiEndpointSpec(_b)],
            )
            ..reportFailure(_a)
            ..reportFailure(_a);
      expect(pool.current!.url, _b);
      pool.replace(const [
        ApiEndpointSpec(_a),
        ApiEndpointSpec(_b),
        ApiEndpointSpec(_c),
      ]);
      expect(pool.current!.url, _b);
      expect(pool.attemptOrder().last.url, _a);
    });

    test('down endpoints come back after the cool-down', () {
      var now = DateTime(2026, 11, 2, 12);
      final pool =
          EndpointPool(
              endpoints: const [ApiEndpointSpec(_a), ApiEndpointSpec(_b)],
              now: () => now,
            )
            ..reportFailure(_a)
            ..reportFailure(_a);
      expect(pool.endpoints.firstWhere((e) => e.url == _a).isDown(now), isTrue);
      now = now.add(EndpointPool.downFor + const Duration(seconds: 1));
      expect(
        pool.endpoints.firstWhere((e) => e.url == _a).isDown(now),
        isFalse,
      );
    });
  });

  group('ApiClient', () {
    late FakeTransport transport;
    late EndpointPool pool;
    late ApiClient client;

    setUp(() {
      transport = FakeTransport(
        (_) => jsonResponse({'status': 'success', 'data': 1}),
      );
      pool = EndpointPool(
        endpoints: const [
          ApiEndpointSpec(_a),
          ApiEndpointSpec(_b),
          ApiEndpointSpec(_c),
        ],
      );
      client =
          ApiClient(
              transport: transport,
              pool: pool,
              userAgent:
                  '98kClient/1.0.0 (Windows NT 10.0; Win64; x64; x64; b1) mihomo/1.19.33 Clash.Meta',
            )
            ..authorization = 'Bearer secret'
            ..deviceId = 'dev-1';
    });

    test('sends UA, auth, device and language headers; parses seq', () async {
      final seqs = <XClientSeq>[];
      client.addSeqListener(seqs.add);
      transport.handler = (_) => jsonResponse(
        {
          'ok': true,
          'data': {'x': 1},
        },
        headers: {'x-xclient-seq': 'b=5;p=9'},
      );
      final data = await client.call(
        'POST',
        '/api/v1/xclient/subscribe',
        shape: ApiShape.plugin,
        device: true,
        json: {'a': 1},
      );
      expect(data, {'x': 1});
      final request = transport.requests.single;
      expect(request.uri.toString(), '$_a/api/v1/xclient/subscribe');
      expect(request.headers['user-agent'], startsWith('98kClient/'));
      expect(request.headers['authorization'], 'Bearer secret');
      expect(request.headers['x-xclient-device'], 'dev-1');
      expect(request.headers['content-language'], 'zh-CN');
      expect(request.headers['content-type'], 'application/json');
      expect(seqs.single.boot, 5);
      expect(seqs.single.policy, 9);
    });

    test('form bodies and query strings', () async {
      await client.call(
        'POST',
        '/api/v1/user/order/save',
        form: {'plan_id': 3, 'coupon_code': null, 'x': true},
      );
      expect(
        String.fromCharCodes(transport.requests.single.body!),
        'plan_id=3&x=1',
      );
      await client.call(
        'GET',
        '/api/v1/user/plan/fetch',
        query: {'id': 7, 'n': null},
        auth: false,
      );
      expect(transport.requests.last.uri.query, 'id=7');
      expect(
        transport.requests.last.headers.containsKey('authorization'),
        isFalse,
      );
    });

    test('GET moves to the next endpoint on connect errors and 5xx', () async {
      transport.handler = (r) {
        if (r.uri.host == 'a.example.com') connectFailure();
        if (r.uri.host == 'b.example.net') return jsonResponse({}, status: 502);
        return jsonResponse({'status': 'success', 'data': 'ok'});
      };
      expect(await client.call('GET', '/api/v1/user/info'), 'ok');
      expect(transport.requests.map((r) => r.uri.host), [
        'a.example.com',
        'b.example.net',
        'c.example.org',
      ]);
      expect(transport.requests.last.uri.path, '/panel/api/v1/user/info');
      // A second failure of a moves the pool off it.
      await client.call('GET', '/api/v1/user/info');
      expect(pool.current!.url, isNot(_a));
    });

    test('POST is not repeated once it may have reached the server', () async {
      transport.handler = (r) =>
          throw const TransportException(TransportFailure.io);
      await expectLater(
        client.call(
          'POST',
          '/api/v1/user/order/save',
          form: {'plan_id': 1},
          idempotent: false,
        ),
        throwsA(
          isA<XbApiException>().having(
            (e) => e.kind,
            'kind',
            XbErrorKind.network,
          ),
        ),
      );
      expect(transport.requests.length, 1);
      transport.requests.clear();
      transport.handler = (r) => r.uri.host == 'a.example.com'
          ? connectFailure()
          : jsonResponse({'status': 'success', 'data': 'T1'});
      expect(
        await client.call(
          'POST',
          '/api/v1/user/order/save',
          form: {'plan_id': 1},
          idempotent: false,
        ),
        'T1',
      );
    });

    Future<XbApiException> errorOf(int status, Object body) async {
      transport.handler = (_) => jsonResponse(body, status: status);
      try {
        await client.call('GET', '/x', shape: ApiShape.plugin);
      } on XbApiException catch (e) {
        return e;
      }
      fail('no error');
    }

    test('maps refusals to kinds', () async {
      expect(
        (await errorOf(401, {'ok': false, 'error': 'unauthenticated'})).kind,
        XbErrorKind.unauthorized,
      );
      expect(
        (await errorOf(403, {'status': 'fail', 'message': '未登录或登陆已过期'})).kind,
        XbErrorKind.unauthorized,
      );
      expect(
        (await errorOf(403, {'ok': false, 'error': 'device_revoked'})).kind,
        XbErrorKind.deviceRevoked,
      );
      expect(
        (await errorOf(403, {'ok': false, 'error': 'device_limit'})).kind,
        XbErrorKind.deviceLimit,
      );
      expect(
        (await errorOf(409, {'ok': false, 'error': 'device_unknown'})).kind,
        XbErrorKind.deviceUnknown,
      );
      expect(
        (await errorOf(409, {'ok': false, 'error': 'replay'})).kind,
        XbErrorKind.replay,
      );
      final validation = await errorOf(422, {
        'message': 'bad',
        'errors': {
          'email': ['邮箱格式不正确'],
        },
      });
      expect(validation.kind, XbErrorKind.validation);
      expect(validation.displayMessage, '邮箱格式不正确');
      transport.handler = (_) => jsonResponse(
        {'message': 'slow'},
        status: 429,
        headers: {'retry-after': '30'},
      );
      final limited = await client
          .call('GET', '/x')
          .then<XbApiException?>(
            (_) => null,
            onError: (Object e) => e as XbApiException,
          );
      expect(limited!.kind, XbErrorKind.rateLimited);
      expect(limited.retryAfter, const Duration(seconds: 30));
      expect(
        (await errorOf(400, {
          'status': 'fail',
          'message': 'Incorrect email or password',
        })).message,
        'Incorrect email or password',
      );
      expect(
        (await errorOf(404, {'message': 'nope'})).kind,
        XbErrorKind.notFound,
      );
      expect(
        (await errorOf(503, {'message': 'down'})).kind,
        XbErrorKind.server,
      );
    });

    test('error listeners see session-ending errors', () async {
      final seen = <XbErrorKind>[];
      client.addErrorListener((e) => seen.add(e.kind));
      await errorOf(403, {'ok': false, 'error': 'device_revoked'});
      expect(seen, [XbErrorKind.deviceRevoked]);
    });

    test('TLS and pin failures are typed', () async {
      transport.handler = (_) => throw const TransportException(
        TransportFailure.tls,
        beforeSend: true,
      );
      await expectLater(
        client.call('GET', '/x'),
        throwsA(
          isA<XbApiException>().having((e) => e.kind, 'kind', XbErrorKind.tls),
        ),
      );
      transport.handler = (_) => throw const TransportException(
        TransportFailure.pin,
        beforeSend: true,
      );
      await expectLater(
        client.call('GET', '/x'),
        throwsA(
          isA<XbApiException>().having(
            (e) => e.kind,
            'kind',
            XbErrorKind.pinMismatch,
          ),
        ),
      );
    });
  });

  test('XClientSeq parsing', () {
    expect(XClientSeq.parse('b=1;p=2')!.policy, 2);
    expect(XClientSeq.parse(' p=3 ')!.boot, isNull);
    expect(XClientSeq.parse('junk'), isNull);
    expect(XClientSeq.parse(null), isNull);
  });
}
