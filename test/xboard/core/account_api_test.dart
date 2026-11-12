import 'dart:convert';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/api/xboard_api.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

void main() {
  test(
    'account extensions use panel routes and preserve gift pagination',
    () async {
      final transport = FakeTransport((request) {
        if (request.uri.path.endsWith('/history')) {
          return jsonResponse({
            'data': [
              {'id': 7},
            ],
            'pagination': {'total': 31},
          });
        }
        if (request.uri.path.endsWith('/getActiveSession')) {
          return jsonResponse({
            'data': [
              {
                'id': 3,
                'token': 'hidden-hash',
                'abilities': ['*'],
                'tokenable_id': 1,
              },
            ],
          });
        }
        return jsonResponse({
          'data': {'username': 'example_bot'},
        });
      });
      final api = XboardApi(
        ApiClient(
          transport: transport,
          pool: EndpointPool(
            endpoints: const [ApiEndpointSpec('https://example.com')],
          ),
          userAgent: 'test',
        ),
      );
      expect((await api.activeSessions()).single, {'id': 3});
      await api.removeActiveSession(3);
      expect(Uri.splitQueryString(utf8.decode(transport.requests.last.body!)), {
        'session_id': '3',
      });
      expect((await api.telegramBotInfo())['username'], 'example_bot');
      await api.giftCardCheck('EXAMPLE123');
      expect(transport.requests.last.uri.path, '/api/v1/user/gift-card/check');
      await api.giftCardRedeem('EXAMPLE123');
      expect(transport.requests.last.method, 'POST');
      final page = await api.giftCardHistory(page: 2, pageSize: 20);
      expect(page.total, 31);
      expect(page.items.single['id'], 7);
      expect(transport.requests.last.uri.queryParameters, {
        'page': '2',
        'per_page': '20',
      });
      await api.giftCardDetail(7);
      expect(transport.requests.last.uri.queryParameters['id'], '7');
      await api.giftCardTypes();
      expect(transport.requests.last.uri.path, '/api/v1/user/gift-card/types');
    },
  );
}
