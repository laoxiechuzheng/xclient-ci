import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/spki.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

/// Points every client at a dead proxy and accepts every certificate, like
/// FlClash's global overrides can.
class _HostileOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..findProxy = ((_) => 'PROXY 127.0.0.1:9')
      ..badCertificateCallback = ((_, _, _) => true);
  }
}

class _ControlledTransport extends IoHttpTransport {
  _ControlledTransport(this.client);

  final _ControlledClient client;

  @override
  HttpClient createClient({bool pin = true}) => client;
}

class _RotatingTransport extends IoHttpTransport {
  _RotatingTransport(this.clients, {required super.pins});

  final List<_ControlledClient> clients;
  final created = <bool>[];

  @override
  HttpClient createClient({bool pin = true}) {
    created.add(pin);
    return clients.removeAt(0);
  }
}

PinPolicy _policy(PinMode mode, String pin) => PinPolicy({
  'a.example': HostPin(mode: mode, spki: {pin}),
});

class _ControlledClient implements HttpClient {
  final opens = <Uri>[];
  final replies = <Future<HttpClientRequest>>[];
  int closes = 0;

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    opens.add(url);
    return replies.removeAt(0);
  }

  @override
  void close({bool force = false}) => closes++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledHeaders implements HttpHeaders {
  _ControlledHeaders(this.touches);
  final List<String> touches;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      touches.add('header:$name');

  @override
  void forEach(void Function(String name, List<String> values) action) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledRequest implements HttpClientRequest {
  final touches = <String>[];
  final written = <int>[];
  int aborts = 0;

  @override
  HttpHeaders get headers {
    touches.add('headers');
    return _ControlledHeaders(touches);
  }

  @override
  set followRedirects(bool value) => touches.add('followRedirects');

  @override
  set persistentConnection(bool value) => touches.add('persistentConnection');

  @override
  set contentLength(int value) => touches.add('contentLength');

  @override
  void add(List<int> data) {
    touches.add('add');
    written.addAll(data);
  }

  @override
  Future<HttpClientResponse> close() async {
    touches.add('close');
    return _ControlledResponse();
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) => aborts++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _ControlledResponse extends Stream<List<int>>
    implements HttpClientResponse {
  @override
  int get statusCode => 200;

  @override
  HttpHeaders get headers => _ControlledHeaders([]);

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream.value(utf8.encode('{"data":true}')).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _timeoutBeforeSend = isA<TransportException>()
    .having((e) => e.kind, 'kind', TransportFailure.timeout)
    .having((e) => e.beforeSend, 'beforeSend', isTrue);

TransportRequest _post({Duration timeout = const Duration(milliseconds: 20)}) =>
    TransportRequest(
      method: 'POST',
      uri: Uri.parse('https://a.example/transfer'),
      headers: const {'authorization': 'test-authorization'},
      body: utf8.encode('amount=100'),
      timeout: timeout,
    );

void main() {
  for (final (description, before, after) in [
    (
      'pin rotation',
      _policy(PinMode.enforce, 'A'),
      _policy(PinMode.enforce, 'B'),
    ),
    (
      'report to enforce',
      _policy(PinMode.report, 'A'),
      _policy(PinMode.enforce, 'A'),
    ),
    ('enabling pins', const PinPolicy(), _policy(PinMode.enforce, 'A')),
    ('removing pins', _policy(PinMode.enforce, 'A'), const PinPolicy()),
  ]) {
    test('$description invalidates the retained connection pool', () async {
      var policy = before;
      final old = _ControlledClient()
        ..replies.addAll([
          Future.value(_ControlledRequest()),
          Future.value(_ControlledRequest()),
        ]);
      final current = _ControlledClient()
        ..replies.add(Future.value(_ControlledRequest()));
      final transport = _RotatingTransport([old, current], pins: () => policy);
      addTearDown(transport.close);

      await transport.send(_post());
      policy = after;
      await transport.send(_post());

      expect(transport.created, hasLength(2));
      expect(old.opens, hasLength(1));
      expect(current.opens, hasLength(1));
      expect(old.closes, 1);
    });
  }

  test(
    'a policy change aborts late openUrl before credential headers',
    () async {
      var policy = _policy(PinMode.report, 'A');
      final pending = Completer<HttpClientRequest>();
      final old = _ControlledClient()..replies.add(pending.future);
      final current = _ControlledClient()
        ..replies.add(Future.value(_ControlledRequest()));
      final transport = _RotatingTransport([old, current], pins: () => policy);
      addTearDown(transport.close);
      final sent = transport.send(_post(timeout: const Duration(seconds: 1)));
      final rejected = expectLater(
        sent,
        throwsA(
          isA<TransportException>()
              .having((e) => e.kind, 'kind', TransportFailure.pin)
              .having((e) => e.beforeSend, 'beforeSend', isTrue),
        ),
      );
      policy = _policy(PinMode.enforce, 'B');
      final lateRequest = _ControlledRequest();
      pending.complete(lateRequest);
      await rejected;

      expect(lateRequest.aborts, 1);
      expect(lateRequest.touches, isEmpty);
      expect(old.closes, 1);
      await transport.send(_post());
      expect(transport.created, [true, true]);
      expect(current.opens, hasLength(1));
    },
  );

  test('a prior policy epoch stays stale when the same pins return', () async {
    var policy = _policy(PinMode.enforce, 'A');
    final pending = Completer<HttpClientRequest>();
    final old = _ControlledClient()
      ..replies.addAll([
        pending.future,
        Future.value(_ControlledRequest()),
        Future.value(_ControlledRequest()),
      ]);
    final second = _ControlledClient()
      ..replies.add(Future.value(_ControlledRequest()));
    final third = _ControlledClient()
      ..replies.add(Future.value(_ControlledRequest()));
    final transport = _RotatingTransport([
      old,
      second,
      third,
    ], pins: () => policy);
    addTearDown(transport.close);
    final sent = transport.send(_post(timeout: const Duration(seconds: 1)));
    final rejected = expectLater(sent, throwsA(isA<TransportException>()));
    policy = _policy(PinMode.enforce, 'B');
    await transport.send(_post());
    policy = _policy(PinMode.enforce, 'A');
    await transport.send(_post());
    final lateRequest = _ControlledRequest();
    pending.complete(lateRequest);
    await rejected;

    expect(lateRequest.aborts, 1);
    expect(lateRequest.touches, isEmpty);
    expect(transport.created, hasLength(3));
  });

  test(
    'equivalent policy objects and pin ordering preserve keepalive',
    () async {
      var policy = const PinPolicy({
        'a.example': HostPin(mode: PinMode.enforce, spki: {'A', 'B'}),
        'b.example': HostPin(mode: PinMode.report, spki: {'C'}),
      });
      final client = _ControlledClient()
        ..replies.addAll([
          Future.value(_ControlledRequest()),
          Future.value(_ControlledRequest()),
        ]);
      final transport = _RotatingTransport([client], pins: () => policy);
      addTearDown(transport.close);
      await transport.send(_post());
      policy = const PinPolicy({
        'b.example': HostPin(mode: PinMode.report, spki: {'C'}),
        'a.example': HostPin(mode: PinMode.enforce, spki: {'B', 'A'}),
      });
      await transport.send(_post());

      expect(transport.created, [true]);
      expect(client.closes, 0);
      expect(client.opens, hasLength(2));
    },
  );

  test('a timed-out openUrl cannot send its late request', () async {
    final pending = Completer<HttpClientRequest>();
    final client = _ControlledClient()..replies.add(pending.future);
    final transport = _ControlledTransport(client);
    addTearDown(transport.close);
    await expectLater(transport.send(_post()), throwsA(_timeoutBeforeSend));

    final lateRequest = _ControlledRequest();
    pending.complete(lateRequest);
    await Future<void>.delayed(Duration.zero);

    expect(lateRequest.aborts, 1);
    expect(lateRequest.touches, isEmpty);
    expect(lateRequest.written, isEmpty);
    expect(client.closes, 0);
  });

  test(
    'non-idempotent endpoint retry sends only the replacement POST',
    () async {
      final pending = Completer<HttpClientRequest>();
      // ignore: close_sinks
      final replacement = _ControlledRequest();
      final client = _ControlledClient()
        ..replies.addAll([pending.future, Future.value(replacement)]);
      final transport = _ControlledTransport(client);
      addTearDown(transport.close);
      final api = ApiClient(
        transport: transport,
        pool: EndpointPool(
          endpoints: const [
            ApiEndpointSpec('https://a.example'),
            ApiEndpointSpec('https://b.example'),
          ],
        ),
        userAgent: 'test-client',
      );
      final result = await api.call(
        'POST',
        '/transfer',
        form: const {'amount': 100},
        timeout: const Duration(milliseconds: 20),
        idempotent: false,
      );
      final lateRequest = _ControlledRequest();
      pending.complete(lateRequest);
      await Future<void>.delayed(Duration.zero);

      expect(result, isTrue);
      expect(client.opens.map((uri) => uri.host), ['a.example', 'b.example']);
      expect(utf8.decode(replacement.written), 'amount=100');
      expect(
        replacement.touches.where((touch) => touch == 'close'),
        hasLength(1),
      );
      expect(lateRequest.aborts, 1);
      expect(lateRequest.touches, isEmpty);
      expect(client.closes, 0);
    },
  );

  test(
    'close prevents an unresolved openUrl from sending afterwards',
    () async {
      final pending = Completer<HttpClientRequest>();
      final client = _ControlledClient()..replies.add(pending.future);
      final transport = _ControlledTransport(client);
      final sent = transport.send(_post(timeout: const Duration(seconds: 1)));
      final refused = expectLater(sent, throwsA(isA<TransportException>()));
      transport.close();
      final lateRequest = _ControlledRequest();
      pending.complete(lateRequest);
      await refused;

      expect(lateRequest.aborts, 1);
      expect(lateRequest.touches, isEmpty);
      expect(client.closes, 1);
    },
  );

  test('close prevents subsequent requests from recreating a client', () async {
    final client = _ControlledClient()
      ..replies.add(Future.value(_ControlledRequest()));
    final transport = _ControlledTransport(client);
    transport.close();

    await expectLater(
      transport.send(_post()),
      throwsA(isA<TransportException>()),
    );
    expect(client.opens, isEmpty);
  });

  test('refuses anything but https', () async {
    final transport = IoHttpTransport();
    await expectLater(
      transport.send(
        TransportRequest(method: 'GET', uri: Uri.parse('http://127.0.0.1/')),
      ),
      throwsA(
        isA<TransportException>()
            .having((e) => e.kind, 'kind', TransportFailure.insecure)
            .having((e) => e.beforeSend, 'beforeSend', isTrue),
      ),
    );
    transport.close();
  });

  test(
    'ignores global HttpOverrides: direct connection, TLS required',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      var accepted = 0;
      final sub = server.listen((socket) {
        accepted++;
        socket
          ..write('HTTP/1.1 200 OK\r\ncontent-length: 2\r\n\r\nhi')
          ..destroy();
      });
      await HttpOverrides.runWithHttpOverrides(() async {
        final transport = IoHttpTransport(
          connectTimeout: const Duration(seconds: 3),
        );
        await expectLater(
          transport.send(
            TransportRequest(
              method: 'GET',
              uri: Uri.parse('https://127.0.0.1:${server.port}/'),
              timeout: const Duration(seconds: 5),
            ),
          ),
          throwsA(
            isA<TransportException>().having(
              (e) => e.kind,
              'kind',
              anyOf(
                TransportFailure.tls,
                TransportFailure.connect,
                TransportFailure.io,
              ),
            ),
          ),
        );
        transport.close();
      }, _HostileOverrides());
      // The plain-text answer reached us directly, not through the proxy, and
      // was not taken for a valid HTTPS response.
      expect(accepted, greaterThan(0));
      await sub.cancel();
      await server.close();
    },
  );
}
