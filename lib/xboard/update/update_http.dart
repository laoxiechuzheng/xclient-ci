import 'dart:async';
import 'dart:io';

import '../core/net/direct_socket_connector.dart';
import '../core/net/strict_http_client.dart';

class UpdateHttpResponse {
  final int statusCode;

  final int? contentLength;
  final Stream<List<int>> body;
  final void Function() cancel;

  UpdateHttpResponse({
    required this.statusCode,
    required this.body,
    this.contentLength,
    void Function()? cancel,
  }) : cancel = cancel ?? _noop;

  static void _noop() {}
}

abstract class UpdateHttp {
  Future<UpdateHttpResponse> get(Uri uri);

  void close();
}

/// Requests bypass FlClash HttpOverrides and require valid HTTPS, including redirects.
/// Package integrity is checked against the signed release document after download.
class IoUpdateHttp implements UpdateHttp {
  final String? userAgent;
  final Duration connectTimeout;
  final int maxRedirects;
  final DirectSocketConnector? connector;

  HttpClient? _client;
  int _epoch = 0;
  int? _directGeneration;

  IoUpdateHttp({
    this.userAgent,
    this.connectTimeout = const Duration(seconds: 15),
    this.maxRedirects = 5,
    this.connector,
  });

  HttpClient get _http => _client ??= () {
    final client = createClient();
    client.userAgent = userAgent;
    client.autoUncompress = false;
    return client;
  }();

  HttpClient createClient() => StrictHttpClientFactory(
    connector: connector,
    connectTimeout: connectTimeout,
  ).create(pin: false);

  @override
  Future<UpdateHttpResponse> get(Uri uri) async {
    _syncConnector();
    final epoch = _epoch;
    var target = uri;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      if (target.scheme != 'https' || target.host.isEmpty) {
        throw const HttpException('insecure url');
      }
      final request = await _http.getUrl(target);
      _syncConnector();
      if (epoch != _epoch) {
        request.abort();
        throw const SocketException('Update request cancelled');
      }
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (response.isRedirect && location != null) {
        // Drain so the connection can be reused.
        unawaited(response.drain<void>().catchError((_) {}));
        target = target.resolve(location);
        continue;
      }
      StreamSubscription<List<int>>? subscription;
      final controller = StreamController<List<int>>(
        onCancel: () => subscription?.cancel(),
      );
      controller.onListen = () {
        subscription = response.listen(
          controller.add,
          onError: controller.addError,
          onDone: () => unawaited(controller.close()),
          cancelOnError: true,
        );
      };
      return UpdateHttpResponse(
        statusCode: response.statusCode,
        contentLength: response.contentLength < 0
            ? null
            : response.contentLength,
        body: controller.stream,
        cancel: () {
          final current = subscription;
          if (current != null) {
            unawaited(current.cancel());
          } else if (!controller.hasListener) {
            // Never listened: close the socket side instead of reading on.
            subscription = response.listen(null)..cancel();
          }
        },
      );
    }
    throw const HttpException('too many redirects');
  }

  @override
  void close() {
    _epoch++;
    _client?.close(force: true);
    _client = null;
  }

  void _syncConnector() {
    if (_directGeneration == connector?.generation) return;
    _directGeneration = connector?.generation;
    close();
  }
}
