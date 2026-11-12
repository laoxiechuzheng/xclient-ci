import 'dart:async';
import 'dart:io';

import '../net/strict_http_client.dart';
import 'push_connection.dart';
import 'push_ticket.dart';

export 'push_connection.dart';

abstract class PushTransport {
  Future<PushConnection> open(PushTicket ticket, {required String userAgent});
  void close();
}

class IoPushTransport implements PushTransport {
  IoPushTransport(this.factory);

  final StrictHttpClientFactory factory;
  final Set<HttpClient> _clients = {};
  int _generation = 0;

  @override
  Future<PushConnection> open(
    PushTicket ticket, {
    required String userAgent,
  }) async {
    final uri = ticket.uri;
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const PushException('insecure_url');
    }
    final generation = _generation;
    final directGeneration = factory.generation;
    final client = factory.create();
    _clients.add(client);
    var cancelled = false;
    void cancel() {
      cancelled = true;
      _clients.remove(client);
      client.close(force: true);
    }

    try {
      Future<HttpClientResponse> request() async {
        final request = await client.getUrl(uri);
        if (cancelled ||
            generation != _generation ||
            directGeneration != factory.generation) {
          request.abort();
          throw const PushException('cancelled');
        }
        request.followRedirects = false;
        request.headers.set(
          HttpHeaders.authorizationHeader,
          'XClientPush ${ticket.value}',
        );
        request.headers.set(HttpHeaders.userAgentHeader, userAgent);
        request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
        request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
        return request.close();
      }

      final response = await request().timeout(const Duration(seconds: 15));
      if (generation != _generation) throw const PushException('cancelled');
      if (response.statusCode != 200 ||
          response.headers.contentType?.mimeType != 'text/event-stream') {
        throw const PushException('bad_response');
      }
      return PushConnection(body: response, cancel: cancel);
    } on Object {
      cancel();
      rethrow;
    }
  }

  @override
  void close() {
    _generation++;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }
}
