import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/core/direct_socket.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/core_direct_connector.dart';
import 'package:fl_clash/xboard/core/net/direct_socket_connector.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/spki.dart';
import 'package:fl_clash/xboard/core/net/strict_http_client.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/push/push_events.dart';
import 'package:fl_clash/xboard/core/push/push_ticket.dart';
import 'package:fl_clash/xboard/core/push/push_transport.dart';
import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:fl_clash/xboard/update/download.dart';
import 'package:fl_clash/xboard/update/update_http.dart';
import 'package:flutter_test/flutter_test.dart';

class _GoApi implements DirectSocketApi {
  _GoApi(this.process) {
    _lines = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(
          (line) {
            try {
              final response = jsonDecode(line) as Map;
              final result = _pending.remove(response['id']);
              if (response['error'] != null) {
                result?.completeError(
                  const DirectSocketException(DirectSocketFailure.unavailable),
                );
              } else {
                result?.complete(response['result']);
              }
            } catch (_) {
              _fail();
            }
          },
          onDone: _fail,
          onError: (Object _) => _fail(),
        );
    _errors = process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final category =
              RegExp('dns|resolv|lookup', caseSensitive: false).hasMatch(line)
              ? 'dns'
              : RegExp(
                  'tls|handshake|cert',
                  caseSensitive: false,
                ).hasMatch(line)
              ? 'tls'
              : RegExp('dial|connect', caseSensitive: false).hasMatch(line)
              ? 'dial'
              : 'other';
          stderrKinds.update(category, (count) => count + 1, ifAbsent: () => 1);
        });
  }
  final Process process;
  late final StreamSubscription<String> _lines;
  late final StreamSubscription<String> _errors;
  final stderrKinds = <String, int>{};
  final _pending = <String, Completer<Object?>>{};
  final opened = <String>[];
  int _id = 0;
  bool _closed = false;

  void _fail() {
    for (final result in _pending.values) {
      if (!result.isCompleted) {
        result.completeError(
          const DirectSocketException(DirectSocketFailure.unavailable),
        );
      }
    }
    _pending.clear();
  }

  Future<Object?> _call(String method, Map<String, Object> arguments) {
    if (_closed) {
      return Future.error(
        const DirectSocketException(DirectSocketFailure.unavailable),
      );
    }
    final id = '${++_id}';
    final result = Completer<Object?>();
    _pending[id] = result;
    process.stdin.writeln(
      jsonEncode({'id': id, 'method': method, 'arguments': arguments}),
    );
    return result.future.timeout(const Duration(seconds: 12));
  }

  @override
  Future<DirectSocketLease> openDirectSocket({
    required String sessionId,
    required String host,
    required int port,
  }) async {
    opened.add(sessionId);
    return DirectSocketLease.parse(
      await _call('openDirectSocket', {
        'sessionId': sessionId,
        'host': host,
        'port': port,
      }),
    );
  }

  @override
  Future<void> closeDirectSocket({
    required String sessionId,
    required String connectionId,
  }) async {
    if (await _call('closeDirectSocket', {
          'sessionId': sessionId,
          'connectionId': connectionId,
        }) !=
        true) {
      throw const DirectSocketException(DirectSocketFailure.unavailable);
    }
  }

  @override
  Future<void> closeDirectSession({required String sessionId}) async {
    if (await _call('closeDirectSession', {'sessionId': sessionId}) != true) {
      throw const DirectSocketException(DirectSocketFailure.unavailable);
    }
  }

  Future<void> dispose() async {
    await Future<void>.delayed(Duration.zero);
    await process.stdin.flush();
    _closed = true;
    await process.stdin.close();
    final exit = await process.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        process.kill();
        return -1;
      },
    );
    await _lines.cancel();
    await _errors.cancel();
    _fail();
    expect(exit, 0);
  }
}

class _ObservedConnector implements DirectSocketConnector {
  _ObservedConnector(this.inner);
  final CoreDirectConnector inner;
  int certificateFailures = 0;
  @override
  int get generation => inner.generation;
  @override
  Future<ConnectionTask<Socket>> connect(
    Uri uri, {
    required SocketUpgrade secure,
  }) => inner.connect(
    uri,
    secure: (raw) async {
      try {
        return await secure(raw);
      } on HandshakeException catch (error) {
        if (error.toString().contains('CERTIFICATE_VERIFY_FAILED')) {
          certificateFailures++;
        }
        rethrow;
      }
    },
  );
  void setCoreReady(bool ready) => inner.setCoreReady(ready);
  @override
  void close() => inner.close();
}

void main() {
  final binary = Platform.environment['XCLIENT_DIRECT_HARNESS'] ?? '';
  test(
    'real Go DIRECT bridge preserves TLS, pins and all control consumers',
    () async {
      const fixtures = 'test/xboard/fixtures/direct-control';
      final correctCertificate = File('$fixtures/test-cert.pem');
      final wrongCertificate = File('$fixtures/test-wrong-host-cert.pem');
      final context = SecurityContext()
        ..useCertificateChain(correctCertificate.path)
        ..usePrivateKey('$fixtures/test-key.pem');
      final wrongContext = SecurityContext()
        ..useCertificateChain(wrongCertificate.path)
        ..usePrivateKey('$fixtures/test-key.pem');
      SecurityContext.defaultContext.setTrustedCertificates(
        correctCertificate.path,
      );
      final pem = await correctCertificate.readAsString();
      final der = base64.decode(
        pem.replaceAll(RegExp(r'-----[^-]+-----|\s'), ''),
      );
      final pin = await spkiSha256Base64(der);
      final requests = <String>[];
      var wrongRequests = 0;
      final payload = List<int>.generate(16384, (index) => index % 251);
      final server = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        context,
      );
      final serverV6 = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv6,
        server.port,
        context,
      );
      final wrongServer = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv4,
        0,
        wrongContext,
      );
      final wrongServerV6 = await HttpServer.bindSecure(
        InternetAddress.loopbackIPv6,
        wrongServer.port,
        wrongContext,
      );
      void wrongRequest(HttpRequest request) {
        wrongRequests++;
        unawaited(request.response.close());
      }

      wrongServer.listen(wrongRequest, onError: (Object _) {});
      wrongServerV6.listen(wrongRequest, onError: (Object _) {});
      Future<void> handle(HttpRequest request) async {
        requests.add(request.uri.path);
        await request.drain<void>();
        switch (request.uri.path) {
          case '/api/v1/xclient/push/ticket':
            request.response.headers.contentType = ContentType.json;
            request.response.write(
              jsonEncode({
                'ok': true,
                'data': {
                  'ticket': 'A' * 43,
                  'expires_in': 60,
                  'path': '/api/v1/xclient/events',
                },
              }),
            );
          case '/api/v1/xclient/events':
            request.response.headers.contentType = ContentType(
              'text',
              'event-stream',
            );
            request.response.write(
              'event: seq\ndata: {"boot_seq":1,"policy_seq":2}\n\n',
            );
          case '/package':
            request.response.contentLength = payload.length;
            request.response.add(payload);
          default:
            request.response.headers.contentType = ContentType.json;
            request.response.write('{"ok":true,"data":{}}');
        }
        await request.response.close();
      }

      server.listen(handle, onError: (Object _) {});
      serverV6.listen(handle, onError: (Object _) {});
      final api = _GoApi(
        await Process.start(
          binary,
          const [
            '-test.run=^TestDirectControlHarness\$',
            '-test.paniconexit0=false',
          ],
          environment: const {'XC_DIRECT_TEST_BRIDGE': '1'},
        ),
      );
      final connector = _ObservedConnector(CoreDirectConnector(api: api));
      final base = 'https://localhost:${server.port}';
      final pinned = PinPolicy({
        'localhost': HostPin(mode: PinMode.enforce, spki: {pin}),
      });
      final transports = <IoHttpTransport>[];
      final push = IoPushTransport(
        StrictHttpClientFactory(connector: connector, pins: () => pinned),
      );
      final update = IoUpdateHttp(connector: connector);
      final output = File(
        '.dart_tool/codex-direct-control/verified-download.bin',
      );
      IoHttpTransport transport([PinPolicy? pins]) {
        final value = IoHttpTransport(
          connector: connector,
          pins: () => pins ?? const PinPolicy(),
        );
        transports.add(value);
        return value;
      }

      var stage = 'fixture-tls-calibration';
      try {
        // Fixture-only calibration separates certificate errors from broker errors.
        // ignore: close_sinks
        final calibrationRaw = await Socket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
        );
        final calibration = await SecureSocket.secure(
          calibrationRaw,
          host: 'localhost',
          onBadCertificate: (_) => false,
        );
        calibration.destroy();
        stage = 'api';
        final response = await transport(pinned).send(
          TransportRequest(
            method: 'POST',
            uri: Uri.parse('$base/account'),
            headers: const {'authorization': 'fixture-auth'},
            body: const [1, 2, 3],
          ),
        );
        expect(response.statusCode, 200);
        for (final path in [
          '/bootstrap.json',
          '/oss/bootstrap.json',
          '/dns-query',
        ]) {
          stage = 'unpinned';
          final plain = transport();
          expect(
            (await plain.send(
              TransportRequest(method: 'GET', uri: Uri.parse('$base$path')),
            )).statusCode,
            200,
          );
          plain.close();
        }
        stage = 'ticket';
        final client =
            ApiClient(
                transport: transport(pinned),
                pool: EndpointPool(endpoints: [ApiEndpointSpec(base)]),
                userAgent: 'FixtureClient/1',
              )
              ..authorization = 'Bearer fixture'
              ..deviceId = 'fixture-device';
        final issuer = ApiPushTicketIssuer(
          api: client,
          transportFactory: () => transport(pinned),
        );
        final ticket = await issuer.issue();
        stage = 'sse';
        final stream = await push.open(ticket, userAgent: 'FixtureClient/1');
        expect(await decodePushEvents(stream.body).toList(), hasLength(1));
        stream.cancel();
        stage = 'download';
        final asset = ReleaseAsset(
          urls: ['$base/package'],
          sha256: sha256.convert(payload).toString(),
          size: payload.length,
        );
        await downloadVerified(asset: asset, target: output, http: update);
        expect(await output.readAsBytes(), payload);
        final beforePinFailure = requests.length;
        stage = 'bad-pin';
        const badPin = PinPolicy({
          'localhost': HostPin(mode: PinMode.enforce, spki: {'wrong'}),
        });
        await expectLater(
          transport(badPin).send(
            TransportRequest(
              method: 'POST',
              uri: Uri.parse('$base/forbidden'),
              headers: const {'authorization': 'must-not-send'},
            ),
          ),
          throwsA(
            isA<TransportException>()
                .having((error) => error.kind, 'pin', TransportFailure.pin)
                .having((error) => error.beforeSend, 'beforeSend', isTrue),
          ),
        );
        expect(requests.length, beforePinFailure);
        for (final trustWrong in [false, true]) {
          stage = trustWrong ? 'wrong-hostname' : 'untrusted-ca';
          final beforeRefusal = connector.certificateFailures;
          if (trustWrong) {
            SecurityContext.defaultContext.setTrustedCertificates(
              wrongCertificate.path,
            );
          }
          await expectLater(
            transport().send(
              TransportRequest(
                method: 'POST',
                uri: Uri.parse(
                  'https://localhost:${wrongServer.port}/forbidden',
                ),
                headers: const {'authorization': 'must-not-send'},
              ),
            ),
            throwsA(
              isA<TransportException>()
                  .having((error) => error.kind, 'tls', TransportFailure.tls)
                  .having((error) => error.beforeSend, 'beforeSend', isTrue),
            ),
          );
          expect(wrongRequests, 0);
          expect(connector.certificateFailures, beforeRefusal + 1);
        }
        connector.setCoreReady(false);
        stage = 'unavailable';
        final beforeUnavailable = requests.length;
        await expectLater(
          transport().send(
            TransportRequest(
              method: 'GET',
              uri: Uri.parse('$base/no-fallback'),
            ),
          ),
          throwsA(
            isA<TransportException>().having(
              (error) => error.beforeSend,
              'beforeSend',
              isTrue,
            ),
          ),
        );
        expect(requests.length, beforeUnavailable);
        connector.setCoreReady(true);
        stage = 'recovered';
        expect(
          (await transport().send(
            TransportRequest(method: 'GET', uri: Uri.parse('$base/recovered')),
          )).statusCode,
          200,
        );
        expect(api.opened.toSet().length, greaterThan(1));
        expect(
          requests,
          containsAll([
            '/account',
            '/bootstrap.json',
            '/oss/bootstrap.json',
            '/dns-query',
            '/api/v1/xclient/push/ticket',
            '/api/v1/xclient/events',
            '/package',
            '/recovered',
          ]),
        );
        stdout.writeln(
          jsonEncode({
            'event': 'DIRECT_COMPONENT_VERIFIED',
            'originalHostname': true,
            'controlPaths': 8,
            'verifiedUpdateBytes': payload.length,
            'certificateRefusals': connector.certificateFailures,
            'enforcePinBeforeSend': true,
            'noFallback': true,
            'ownerCount': api.opened.toSet().length,
          }),
        );
      } catch (error) {
        stdout.writeln(
          jsonEncode({
            'event': 'DIRECT_COMPONENT_FAILED',
            'stage': stage,
            'error': error is TransportException
                ? error.kind.name
                : error.runtimeType.toString(),
            'certificateRefusals': connector.certificateFailures,
            'goOpenCount': api.opened.length,
            'stderrKinds': api.stderrKinds,
          }),
        );
        rethrow;
      } finally {
        for (final value in transports) {
          value.close();
        }
        push.close();
        update.close();
        connector.close();
        await server.close(force: true);
        await serverV6.close(force: true);
        await wrongServer.close(force: true);
        await wrongServerV6.close(force: true);
        await api.dispose();
        if (await output.exists()) await output.delete();
      }
    },
    skip: binary.isEmpty
        ? 'Requires an explicitly built local Go DIRECT harness.'
        : false,
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
