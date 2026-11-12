import 'dart:async';
import 'dart:io';

import 'package:fl_clash/xboard/core/net/direct_socket_connector.dart';
import 'package:fl_clash/xboard/core/net/strict_http_client.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/push/push_ticket.dart';
import 'package:fl_clash/xboard/core/push/push_transport.dart';
import 'package:fl_clash/xboard/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

class _Epoch implements DirectSocketConnector {
  @override
  int generation = 0;
  int closes = 0;
  @override
  Future<ConnectionTask<Socket>> connect(
    Uri uri, {
    required SocketUpgrade secure,
  }) => throw StateError('native dial is not expected');
  @override
  void close() => closes++;
}

class _Client implements HttpClient {
  final pending = Completer<HttpClientRequest>();
  int closes = 0;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri uri) => pending.future;
  @override
  Future<HttpClientRequest> getUrl(Uri uri) => pending.future;
  @override
  set userAgent(String? value) {}
  @override
  set autoUncompress(bool value) {}
  @override
  void close({bool force = false}) => closes++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headers implements HttpHeaders {
  _Headers(this.touches);
  final List<String> touches;
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      touches.add('header:$name');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  final touches = <String>[];
  final body = <int>[];
  int aborts = 0;
  @override
  HttpHeaders get headers {
    touches.add('headers');
    return _Headers(touches);
  }

  @override
  set followRedirects(bool value) => touches.add('redirect');
  @override
  set persistentConnection(bool value) => touches.add('persistent');
  @override
  set contentLength(int value) => touches.add('length');
  @override
  void add(List<int> data) {
    touches.add('body');
    body.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() {
    touches.add('close');
    throw StateError('late request sent');
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborts++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends IoHttpTransport {
  _Api(this.client, {required super.connector});
  final _Client client;
  @override
  HttpClient createClient({bool pin = true}) => client;
}

class _Factory extends StrictHttpClientFactory {
  _Factory(this.client, {required super.connector});
  final _Client client;
  @override
  HttpClient create({bool pin = true}) => client;
}

class _Update extends IoUpdateHttp {
  _Update(this.client, {required super.connector});
  final _Client client;
  @override
  HttpClient createClient() => client;
}

void main() {
  test(
    'API rejects a late old-generation request before any headers or body',
    () async {
      final epoch = _Epoch();
      final client = _Client();
      final transport = _Api(client, connector: epoch);
      final request = _Request();
      final result = transport.send(
        TransportRequest(
          method: 'POST',
          uri: Uri.parse('https://example.invalid/account'),
          headers: const {'authorization': 'fixture'},
          body: const [1, 2, 3],
        ),
      );
      final refused = expectLater(
        result,
        throwsA(
          isA<TransportException>().having(
            (error) => error.beforeSend,
            'beforeSend',
            isTrue,
          ),
        ),
      );
      epoch.generation++;
      client.pending.complete(request);
      await refused;
      expect(request.touches, isEmpty);
      expect(request.body, isEmpty);
      expect(request.aborts, 1);
      transport.close();
      expect(epoch.closes, 0);
    },
  );

  for (final coreRestart in [false, true]) {
    test(
      'SSE blocks late headers after ${coreRestart ? 'Core restart' : 'close'}',
      () async {
        final epoch = _Epoch();
        final client = _Client();
        final transport = IoPushTransport(_Factory(client, connector: epoch));
        final result = transport.open(
          PushTicket(
            uri: Uri.parse('https://example.invalid/api/v1/xclient/events'),
            value: 'A' * 43,
          ),
          userAgent: 'FixtureClient/1',
        );
        final refused = expectLater(result, throwsA(isA<PushException>()));
        if (coreRestart) {
          epoch.generation++;
        } else {
          transport.close();
        }
        final request = _Request();
        client.pending.complete(request);
        await refused;
        expect(request.touches, isEmpty);
        expect(request.aborts, 1);
        transport.close();
        expect(epoch.closes, 0);
      },
    );

    test(
      'update download blocks late headers after ${coreRestart ? 'Core restart' : 'close'}',
      () async {
        final epoch = _Epoch();
        final client = _Client();
        final http = _Update(client, connector: epoch);
        final result = http.get(Uri.parse('https://example.invalid/installer'));
        final refused = expectLater(result, throwsA(isA<SocketException>()));
        if (coreRestart) {
          epoch.generation++;
        } else {
          http.close();
        }
        final request = _Request();
        client.pending.complete(request);
        await refused;
        expect(request.touches, isEmpty);
        expect(request.aborts, 1);
        http.close();
        expect(epoch.closes, 0);
      },
    );
  }

  testWidgets(
    'SSE timeout also refuses a late request before the ticket header',
    (tester) async {
      final epoch = _Epoch();
      final client = _Client();
      final transport = IoPushTransport(_Factory(client, connector: epoch));
      final result = transport.open(
        PushTicket(
          uri: Uri.parse('https://example.invalid/api/v1/xclient/events'),
          value: 'A' * 43,
        ),
        userAgent: 'FixtureClient/1',
      );
      final refused = expectLater(result, throwsA(isA<TimeoutException>()));
      await tester.pump(const Duration(seconds: 15));
      await refused;
      final request = _Request();
      client.pending.complete(request);
      await tester.pump();
      expect(request.touches, isEmpty);
      expect(request.aborts, 1);
      transport.close();
    },
  );
}
