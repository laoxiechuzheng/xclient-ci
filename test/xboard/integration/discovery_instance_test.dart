import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/spki.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/runtime.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

final _environment = Platform.environment;

void _event(String name, [Map<String, Object?> fields = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, ...fields}));

Future<void> _until(bool Function() ready, String code) async {
  final deadline = DateTime.now().add(const Duration(seconds: 40));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw StateError(code);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

class _Sink implements ManagedProfileSink {
  int applied = 0;

  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {
    final document = loadYaml(utf8.decode(yaml));
    expect(document, isA<Map>());
    expect((document as Map)['proxies'], hasLength(3));
    applied++;
  }

  @override
  Future<void> remove() async {}
}

class _Transport implements HttpTransport {
  _Transport(this.inner, this.paths);
  final HttpTransport inner;
  final List<String> paths;

  @override
  Future<TransportResponse> send(TransportRequest request) {
    paths.add(request.uri.path);
    return inner.send(request);
  }

  @override
  void close() => inner.close();
}

void main() {
  final configPath = _environment['XCLIENT_TEST_CONFIG'] ?? '';
  final certificate = _environment['XCLIENT_TEST_CERT'] ?? '';
  final arm = _environment['XCLIENT_DISCOVERY_ARM_FILE'] ?? '';
  test(
    'active HTTPS keepalive obeys rotated pin policy',
    () async {
      final config = jsonDecode(await File(configPath).readAsString()) as Map;
      final uri = Uri.parse('${config['endpoint']}/api/v1/xclient/ping');
      expect(uri.scheme, 'https');
      expect(
        uri.host == 'localhost' ||
            (InternetAddress.tryParse(uri.host)?.isLoopback ?? false),
        isTrue,
      );
      final pem = await File(certificate).readAsString();
      final match = RegExp(
        r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
      ).firstMatch(pem)!;
      final certificateDer = base64.decode(
        match.group(1)!.replaceAll(RegExp(r'\s'), ''),
      );
      final correct = await spkiSha256Base64(
        Uint8List.fromList(certificateDer),
      );
      final wrong = base64.encode(List<int>.filled(32, 0));
      expect(correct, isNot(wrong));
      SecurityContext.defaultContext.setTrustedCertificates(certificate);
      PinPolicy policy(PinMode mode, String value) => PinPolicy({
        uri.host: HostPin(mode: mode, spki: {value}),
      });
      var current = policy(PinMode.enforce, correct);
      var reports = 0;
      final transport = IoHttpTransport(
        pins: () => current,
        onPinReport: (_, _) => reports++,
      );
      final request = TransportRequest(method: 'GET', uri: uri);
      Future<void> refused() async {
        await expectLater(
          transport.send(request),
          throwsA(
            isA<TransportException>()
                .having((error) => error.kind, 'kind', TransportFailure.pin)
                .having((error) => error.beforeSend, 'beforeSend', true),
          ),
        );
      }

      try {
        expect((await transport.send(request)).statusCode, 200);
        current = policy(PinMode.enforce, wrong);
        await refused();
        current = policy(PinMode.enforce, correct);
        expect((await transport.send(request)).statusCode, 200);
        current = policy(PinMode.report, wrong);
        expect((await transport.send(request)).statusCode, 200);
        current = policy(PinMode.enforce, wrong);
        await refused();
        expect(reports, greaterThanOrEqualTo(3));
        _event('DYNAMIC_PIN_VERIFIED', {
          'matching_status': 200,
          'enforce_changes_refused_before_send': 2,
          'mismatch_reports': reports,
        });
      } finally {
        transport.close();
      }
    },
    skip: configPath.isEmpty || certificate.isEmpty
        ? 'Requires an explicitly owned loopback TLS fixture.'
        : false,
  );
  test(
    'signed remote pool rotation, OSS recovery and cache restart over HTTPS',
    () async {
      final config =
          jsonDecode(await File(configPath).readAsString())
              as Map<String, dynamic>;
      final endpoint = config['endpoint'] as String;
      final uri = Uri.parse(endpoint);
      expect(uri.scheme, 'https');
      expect(
        uri.host == 'localhost' ||
            (InternetAddress.tryParse(uri.host)?.isLoopback ?? false),
        isTrue,
      );
      expect(await File(arm).exists(), isFalse);
      SecurityContext.defaultContext.setTrustedCertificates(certificate);
      Map<String, String> keys(String name) =>
          (config[name] as Map).map((key, value) => MapEntry('$key', '$value'));
      final brand = BrandConfig(
        brandId: config['brand'] as String,
        displayName: 'Discovery integration',
        builtinApiEndpoints: [ApiEndpointSpec(endpoint)],
        bootstrapSources: ['$endpoint/oss/builtin-rescue.json'],
        ctrlPubKeys: keys('ctrl_pub_keys'),
        envPubKeys: keys('env_pub_keys'),
      );
      final store = MemorySecureStore();
      final cache = MemoryBootstrapCache();
      final sink = _Sink();
      final paths = <String>[];
      XClientRuntime create() => XClientRuntime(
        brand: brand,
        client: const ClientInfo(
          platform: XcPlatform.windows,
          arch: 'x64',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '10.0',
          deviceName: 'Isolated discovery probe',
        ),
        store: store,
        cache: cache,
        sink: sink,
        transportFactory: ({pins, onPinReport}) => _Transport(
          IoHttpTransport(pins: pins, onPinReport: onPinReport),
          paths,
        ),
      );
      var runtime = create();
      StreamSubscription<BootstrapState>? subscription;
      try {
        await runtime.start();
        await runtime.login(
          config['email'] as String,
          config['password'] as String,
        );
        await _until(
          () => runtime.bootstrap.state.payload?.discovery != null,
          'initial_discovery_missing',
        );
        expect(runtime.pool.endpoints.map((e) => e.url), ['$endpoint/api-a']);
        await _until(
          () => sink.applied > 0,
          'initial_subscription_not_applied',
        );
        final firstSeq = runtime.bootstrap.state.seq;
        runtime.poller.setIntervals(
          foreground: const Duration(seconds: 300),
          background: const Duration(seconds: 900),
        );
        await Future<void>.delayed(const Duration(seconds: 11));
        var sawDeadApi = false;
        var rotationStart = -1;
        subscription = runtime.bootstrap.changes.listen((state) {
          if (state
              .endpoints(brand)
              .any((entry) => entry.url.endsWith('/dead-api'))) {
            if (!sawDeadApi) rotationStart = paths.length;
            sawDeadApi = true;
          }
        });
        paths.clear();
        _event('DISCOVERY_READY', {'seq': firstSeq});
        await _until(() => File(arm).existsSync(), 'arm_timeout');
        final stopwatch = Stopwatch()..start();
        await _until(() => sawDeadApi, 'push_rotation_not_received');
        _event('DISCOVERY_ROTATED', {
          'latency_ms': stopwatch.elapsedMilliseconds,
        });
        expect(runtime.bootstrap.state.payload!.discovery!.sources, [
          '$endpoint/oss/recovery.json',
        ]);
        await runtime.bootstrap.refresh();
        await _until(
          () => runtime.pool.endpoints.any(
            (entry) => entry.url.endsWith('/api-b'),
          ),
          'new_oss_did_not_recover_api',
        );
        final recovered = runtime.bootstrap.state;
        expect(recovered.seq, greaterThan(firstSeq + 1));
        expect(recovered.source, BootstrapSource.oss);
        expect(paths, contains('/oss/recovery.json'));
        expect(rotationStart, greaterThanOrEqualTo(0));
        expect(
          paths
              .skip(rotationStart)
              .where(
                (value) =>
                    value.contains('retired') ||
                    value.contains('builtin-rescue') ||
                    value.contains('disabled'),
              ),
          isEmpty,
        );
        final ping = await runtime.api.send('GET', '/api/v1/xclient/ping');
        expect(ping.statusCode, 200);
        _event('DISCOVERY_RECOVERED', {
          'seq': recovered.seq,
          'oss_requests': paths
              .where((value) => value == '/oss/recovery.json')
              .length,
          'old_or_disabled_requests': 0,
        });
        await subscription.cancel();
        subscription = null;
        runtime.dispose();
        runtime = create();
        await runtime.start();
        expect(runtime.bootstrap.state.seq, recovered.seq);
        expect(runtime.pool.endpoints.map((e) => e.url), ['$endpoint/api-b']);
        expect(
          runtime.bootstrap.state.payload!.discovery!.ossPools,
          hasLength(2),
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(runtime.bootstrap.state.seq, recovered.seq);
        expect(runtime.session.state.isLoggedIn, isTrue);
        await runtime.logout();
        _event('DISCOVERY_RESTART_OK', {
          'seq': recovered.seq,
          'session_restored': true,
        });
      } finally {
        await subscription?.cancel();
        if (runtime.session.state.isLoggedIn) {
          try {
            await runtime.logout();
          } catch (_) {}
        }
        runtime.dispose();
      }
    },
    skip: configPath.isEmpty || certificate.isEmpty || arm.isEmpty
        ? 'Requires an explicitly owned loopback test fixture and arm file.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
