import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/runtime.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

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

({XClientRuntime runtime, FakeTransport transport}) _runtime(
  String webUrl, {
  FakeHandler? handler,
}) {
  final transport = FakeTransport(
    handler ??
        (request) => request.uri.path.endsWith('/checkout')
            ? jsonResponse({'type': -1, 'data': true})
            : jsonResponse({'data': <String, Object?>{}}),
  );
  final runtime = XClientRuntime(
    brand: BrandConfig(
      brandId: 'demo',
      displayName: 'Example',
      panelWebUrl: webUrl,
      builtinApiEndpoints: const [
        ApiEndpointSpec('https://a.example.invalid/api-base'),
        ApiEndpointSpec('https://b.example.invalid/api-base'),
      ],
    ),
    client: const ClientInfo(
      platform: XcPlatform.android,
      arch: 'arm64-v8a',
      appVersion: '1.0.0',
      build: '1',
      osVersion: '14',
      deviceName: 'Test',
    ),
    store: MemorySecureStore(),
    cache: MemoryBootstrapCache(),
    sink: _Sink(),
    transportFactory: ({pins, onPinReport}) => transport,
  );
  addTearDown(runtime.dispose);
  runtime.pool.replace(runtime.brand.builtinApiEndpoints);
  runtime.api.authorization = 'Bearer fixture-only';
  return (runtime: runtime, transport: transport);
}

void main() {
  test(
    'runtime checkout sends only HTTPS Web origin and keeps account headers',
    () async {
      final (:runtime, :transport) = _runtime(
        'https://WEB.example.invalid:8443/private/path?token=do-not-forward#account',
      );
      await runtime.xboard.guestConfig();
      await runtime.xboard.userInfo();
      final result = await runtime.xboard.checkout(
        tradeNo: 'FAKE-ORDER',
        method: 2,
      );
      expect(result.isPaid, isTrue);
      final request = transport.requests.last;
      expect(request.headers['referer'], 'https://web.example.invalid:8443/');
      expect(request.headers['authorization'], 'Bearer fixture-only');
      expect(request.headers['user-agent'], runtime.userAgent);
      expect(request.method, 'POST');
      expect(request.uri.path, '/api-base/api/v1/user/order/checkout');
      expect(Uri.splitQueryString(utf8.decode(request.body!)), {
        'trade_no': 'FAKE-ORDER',
        'method': '2',
      });
      await runtime.xboard.userInfo();
      expect(
        transport.requests
            .where((r) => !r.uri.path.endsWith('/checkout'))
            .every((r) => !r.headers.containsKey('referer')),
        isTrue,
      );
      expect(
        request.headers.values.join(' '),
        isNot(contains('do-not-forward')),
      );
    },
  );

  test(
    'empty Web URL remains optional for an independent free checkout',
    () async {
      final (:runtime, :transport) = _runtime('');
      expect((await runtime.xboard.checkout(tradeNo: 'FREE')).isPaid, isTrue);
      expect(transport.requests.single.headers.containsKey('referer'), isFalse);
    },
  );

  test('IPv6 Web origin preserves its explicit TLS port', () async {
    final (:runtime, :transport) = _runtime(
      'https://[2001:db8::1]:8443/private?token=discarded#discarded',
    );
    await runtime.xboard.checkout(tradeNo: 'FREE');
    expect(
      transport.requests.single.headers['referer'],
      'https://[2001:db8::1]:8443/',
    );
  });

  for (final (index, value) in [
    'http://web.example.invalid/private?token=sensitive',
    'https://user:sensitive@web.example.invalid/',
    'https://@web.example.invalid/',
    'https://web.example.invalid:65536/',
    'https://-invalid.example.invalid/',
    'https://web.example.invalid/white space',
    'not-a-url?token=sensitive',
  ].indexed) {
    test(
      'invalid checkout Web configuration $index fails without leaking input',
      () {
        expect(
          () => _runtime(value),
          throwsA(
            isA<FormatException>().having(
              (error) => error.toString(),
              'safe configuration error',
              allOf(contains('checkoutWebUrl'), isNot(contains('sensitive'))),
            ),
          ),
        );
      },
    );
  }

  test(
    'checkout with a Referer is not replayed after an ambiguous send failure',
    () async {
      final (:runtime, :transport) = _runtime(
        'https://web.example.invalid/checkout',
        handler: (_) => throw const TransportException(TransportFailure.io),
      );
      await expectLater(
        runtime.xboard.checkout(tradeNo: 'FAKE-ORDER', method: 1),
        throwsA(
          isA<XbApiException>().having(
            (e) => e.kind,
            'kind',
            XbErrorKind.network,
          ),
        ),
      );
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.headers['referer'],
        'https://web.example.invalid/',
      );
      expect(transport.requests.single.uri.host, 'a.example.invalid');
    },
  );

  test('checkout with Referer does not retry an upstream 503', () async {
    final (:runtime, :transport) = _runtime(
      'https://web.example.invalid/',
      handler: (_) =>
          jsonResponse({'message': 'fixture unavailable'}, status: 503),
    );
    await expectLater(
      runtime.xboard.checkout(tradeNo: 'FAKE-ORDER', method: 1),
      throwsA(
        isA<XbApiException>().having((e) => e.kind, 'kind', XbErrorKind.server),
      ),
    );
    expect(transport.requests, hasLength(1));
    expect(
      transport.requests.single.headers['referer'],
      'https://web.example.invalid/',
    );
  });
}
