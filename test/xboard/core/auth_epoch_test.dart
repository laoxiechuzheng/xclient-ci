import 'dart:async';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  for (final resetSameToken in [false, true]) {
    test(
      'old refusal remains typed but cannot notify the new auth epoch; same token=$resetSameToken',
      () async {
        final response = Completer<TransportResponse>();
        final transport = FakeTransport((_) => response.future);
        final api = ApiClient(
          transport: transport,
          pool: EndpointPool(
            endpoints: const [ApiEndpointSpec('https://api.example.invalid')],
          ),
          userAgent: 'demoClient/1.0.0',
        );
        final errors = <XbApiException>[];
        api.addErrorListener(errors.add);
        api.authorization = 'Bearer old';
        final oldEpoch = api.authorizationGeneration;
        final request = api.call('GET', '/private');
        final refused = expectLater(
          request,
          throwsA(
            isA<XbApiException>().having(
              (error) => error.kind,
              'kind',
              XbErrorKind.unauthorized,
            ),
          ),
        );
        api.authorization = resetSameToken ? 'Bearer old' : 'Bearer new';
        expect(api.authorizationGeneration, greaterThan(oldEpoch));
        response.complete(
          jsonResponse({'message': 'unauthenticated'}, status: 401),
        );
        await refused;
        expect(errors, isEmpty);
      },
    );
  }
  test('external ticket response uses its original primary auth epoch', () {
    final api = ApiClient(
      transport: FakeTransport((_) => jsonResponse(null)),
      pool: EndpointPool(
        endpoints: const [ApiEndpointSpec('https://api.example.invalid')],
      ),
      userAgent: 'demoClient/1.0.0',
    );
    final errors = <XbApiException>[];
    api.addErrorListener(errors.add);
    api.authorization = 'Bearer primary';
    final epoch = api.authorizationGeneration;
    final wire = jsonResponse({
      'ok': false,
      'error': 'unauthenticated',
    }, status: 401);
    final response = ApiResponse(
      statusCode: 401,
      headers: wire.headers,
      body: wire.body,
      endpoint: 'https://api.example.invalid',
      authorizationGeneration: epoch,
    );
    expect(
      () => api.unwrap(response, ApiShape.plugin),
      throwsA(isA<XbApiException>()),
    );
    expect(errors, hasLength(1));
    api.authorization = null;
    expect(
      () => api.unwrap(response, ApiShape.plugin),
      throwsA(isA<XbApiException>()),
    );
    expect(errors, hasLength(1));
  });
}
