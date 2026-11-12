import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/spki.dart';
import 'package:fl_clash/xboard/core/net/strict_http_client.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/push/push_events.dart';
import 'package:fl_clash/xboard/core/push/push_ticket.dart';
import 'package:fl_clash/xboard/core/push/push_transport.dart';
import 'package:fl_clash/xboard/core/runtime.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;
import 'package:yaml/yaml.dart';

String _option(String name) => Platform.environment[name] ?? '';

void _event(String name, [Map<String, Object?> fields = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, ...fields}));

class _ProbeFailure implements Exception {
  const _ProbeFailure(this.code);
  final String code;
  @override
  String toString() => 'InstanceProbeFailure($code)';
}

void _require(bool condition, String code) {
  if (!condition) throw _ProbeFailure(code);
}

Future<void> _until(
  bool Function() predicate,
  String code, {
  Duration timeout = const Duration(seconds: 20),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) throw _ProbeFailure(code);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

class _Sink implements ManagedProfileSink {
  int applied = 0;
  int removed = 0;
  int bytes = 0;
  int nodes = 0;
  String? digest;
  String? rejection;
  String proxiesShape = 'not_seen';

  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {
    final config = loadYaml(utf8.decode(yaml));
    if (config is! Map) rejection = 'not_yaml_map';
    _require(config is Map, 'subscription_not_yaml_map');
    final proxies = (config as Map)['proxies'];
    proxiesShape = proxies == null
        ? 'absent'
        : proxies is List
        ? 'list'
        : proxies is Map
        ? 'map'
        : 'other';
    if (proxies is! List || proxies.isEmpty) rejection = 'no_nodes';
    _require(
      proxies is List && proxies.isNotEmpty,
      'subscription_has_no_nodes',
    );
    applied++;
    bytes = yaml.length;
    nodes = (proxies as List).length;
    digest = sha256.convert(yaml).toString();
  }

  @override
  Future<void> remove() async {
    removed++;
    bytes = 0;
    nodes = 0;
    digest = null;
  }
}

class _Metrics {
  int httpActive = 0;
  int stateRequests = 0;
  int tickets = 0;
  int streamOpens = 0;
  int streamChunks = 0;
  int pinReports = 0;
  int coreWarnings = 0;
  String? cryptoFailure;
  String? profileFailureType;
  int lastPushPolicy = -1;
  final Set<int> activeStreams = {};
}

class _ObservedHttp implements HttpTransport {
  _ObservedHttp(this.inner, this.metrics);
  final HttpTransport inner;
  final _Metrics metrics;

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    metrics.httpActive++;
    if (request.uri.path.endsWith('/xclient/state')) metrics.stateRequests++;
    if (request.uri.path.endsWith('/xclient/push/ticket')) metrics.tickets++;
    try {
      return await inner.send(request);
    } finally {
      metrics.httpActive--;
    }
  }

  @override
  void close() => inner.close();
}

class _ObservedPush implements PushTransport {
  _ObservedPush(this.inner, this.metrics);
  final PushTransport inner;
  final _Metrics metrics;
  final Set<void Function()> _cancellations = {};

  @override
  Future<PushConnection> open(
    PushTicket ticket, {
    required String userAgent,
  }) async {
    final connection = await inner.open(ticket, userAgent: userAgent);
    final id = ++metrics.streamOpens;
    metrics.activeStreams.add(id);
    final hints = StreamController<List<int>>();
    final observer = decodePushEvents(hints.stream).listen(
      (seq) {
        metrics.lastPushPolicy = seq.policy ?? metrics.lastPushPolicy;
      },
      onError: (Object _) {},
      cancelOnError: true,
    );
    var cancelled = false;
    late final void Function() cancel;
    cancel = () {
      if (cancelled) return;
      cancelled = true;
      _cancellations.remove(cancel);
      metrics.activeStreams.remove(id);
      connection.cancel();
      unawaited(observer.cancel().catchError((Object _) {}));
      if (!hints.isClosed) unawaited(hints.close());
    };
    _cancellations.add(cancel);
    final observed = connection.body.transform(
      StreamTransformer<List<int>, List<int>>.fromHandlers(
        handleData: (chunk, sink) {
          metrics.streamChunks++;
          if (!hints.isClosed) hints.add(chunk);
          sink.add(chunk);
        },
        handleDone: (sink) {
          cancel();
          sink.close();
        },
      ),
    );

    return PushConnection(body: observed, cancel: cancel);
  }

  @override
  void close() {
    for (final cancel in _cancellations.toList()) {
      cancel();
    }
    inner.close();
  }
}

BrandConfig _brand(Map<String, dynamic> config) {
  final defines = config['defines'];
  if (defines is Map) {
    return BrandConfig.fromDefines(
      defines.map((key, value) => MapEntry('$key', '$value')),
    );
  }
  Map<String, String> keys(Object? value) =>
      value is Map ? value.map((key, value) => MapEntry('$key', '$value')) : {};
  final endpoint = config['endpoint'];
  _require(
    endpoint is String && normalizeBaseUrl(endpoint) != null,
    'invalid_test_endpoint',
  );
  return BrandConfig(
    brandId: config['brand'] is String ? config['brand'] as String : 'example',
    displayName: 'Integration Test',
    builtinApiEndpoints: [
      ApiEndpointSpec(normalizeBaseUrl(endpoint as String)!),
    ],
    ctrlPubKeys: keys(config['ctrl_pub_keys']),
    envPubKeys: keys(config['env_pub_keys']),
    obfKey: config['obf_key'] is String ? config['obf_key'] as String : '',
  );
}

Future<String> _certificatePin(String certificate) async {
  final pem = await File(certificate).readAsString();
  final match = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
  ).firstMatch(pem);
  _require(match != null, 'invalid_test_certificate');
  final der = base64.decode(match!.group(1)!.replaceAll(RegExp(r'\s'), ''));
  return spkiSha256Base64(Uint8List.fromList(der));
}

Future<void> _runProbe(String configPath, String certificatePath) async {
  var stage = 'read_config';
  XClientRuntime? runtime;
  final metrics = _Metrics();
  final sink = _Sink();
  final store = MemorySecureStore();
  final previousLog = xcLogSink;
  xcLogSink = (message, {required warn}) {
    if (warn) metrics.coreWarnings++;
    final applyFailure = RegExp(
      r'profile apply failed: ([A-Za-z_][A-Za-z0-9_<>]*)$',
    ).firstMatch(message);
    if (applyFailure != null) {
      metrics.profileFailureType = applyFailure.group(1);
    }
    for (final code in const [
      'bad_format',
      'unknown_kid',
      'bad_signature',
      'bad_version',
      'binding_mismatch',
      'expired',
      'not_yet_valid',
      'decrypt_failed',
      'bad_key',
      'brand_mismatch',
      'rollback',
      'insecure_url',
    ]) {
      if (message.endsWith(': $code')) metrics.cryptoFailure = code;
    }
  };
  try {
    final decoded = jsonDecode(await File(configPath).readAsString());
    _require(decoded is Map<String, dynamic>, 'invalid_config');
    final config = decoded as Map<String, dynamic>;
    final brand = _brand(config);
    _require(
      brand.ctrlPubKeys.isNotEmpty && brand.builtinApiEndpoints.isNotEmpty,
      'missing_test_brand',
    );
    _require(
      brand.builtinApiEndpoints.every((endpoint) {
        final host = Uri.parse(endpoint.url).host;
        return host == 'localhost' ||
            (InternetAddress.tryParse(host)?.isLoopback ?? false);
      }),
      'isolated_loopback_endpoint_required',
    );
    final email = config['email'];
    final password = config['password'];
    _require(email is String && password is String, 'missing_test_credentials');
    stage = 'trust_test_certificate';
    final certificatePin = await _certificatePin(certificatePath);
    SecurityContext.defaultContext.setTrustedCertificates(certificatePath);
    stage = 'start_runtime';
    final client = XClientRuntime(
      brand: brand,
      client: const ClientInfo(
        platform: XcPlatform.windows,
        arch: 'x64',
        appVersion: '1.0.0',
        build: '1',
        osVersion: '10.0',
        deviceName: 'Isolated test harness',
      ),
      store: store,
      cache: MemoryBootstrapCache(),
      sink: sink,
      transportFactory: ({pins, onPinReport}) => _ObservedHttp(
        IoHttpTransport(
          pins: pins,
          onPinReport: (_, _) {
            metrics.pinReports++;
          },
        ),
        metrics,
      ),
      pushTransportFactory: ({pins, onPinReport}) => _ObservedPush(
        IoPushTransport(
          StrictHttpClientFactory(
            pins: pins,
            onPinReport: (_, _) {
              metrics.pinReports++;
            },
          ),
        ),
        metrics,
      ),
    );
    runtime = client;
    await client.start();
    stage = 'login_register';
    await client.login(email as String, password as String);
    _require(
      client.session.state.isLoggedIn && client.session.state.deviceRegistered,
      'login_registration_not_ready',
    );
    _event('SESSION_READY', {'registered': true});
    stage = 'signed_bootstrap';
    await client.bootstrap.refresh();
    _require(
      client.bootstrap.state.payload != null && !client.bootstrap.state.stale,
      'bootstrap_not_verified',
    );
    final endpointHost = Uri.parse(brand.builtinApiEndpoints.first.url).host;
    final pin = client.bootstrap.state.pins.forHost(endpointHost);
    final requiredPin = _option('XCLIENT_TEST_REQUIRE_PIN');
    if (requiredPin.isNotEmpty) {
      _require(pin?.mode.name == requiredPin, 'unexpected_pin_mode');
      _require(
        pin!.spki.contains(certificatePin),
        'bootstrap_certificate_pin_mismatch',
      );
    }
    _event('BOOTSTRAP_VERIFIED', {
      'seq': client.bootstrap.state.seq,
      'pin_mode': pin?.mode.name ?? 'off',
      'certificate_pin_matches': pin?.spki.contains(certificatePin) ?? false,
    });
    stage = 'encrypted_subscription';
    final synced = await client.sync.syncNow();
    _event('SUBSCRIPTION_RESULT', {
      'phase': synced.phase.name,
      'inner_status': synced.panelStatus,
      'error_kind': synced.error?.kind.name,
      'crypto_code': metrics.cryptoFailure,
      'sink_applications': sink.applied,
      'sink_nodes': sink.nodes,
      'sink_rejection': sink.rejection,
      'proxies_shape': sink.proxiesShape,
      'apply_failure_type': metrics.profileFailureType,
    });
    _require(
      synced.phase == SyncPhase.ok && sink.applied > 0 && sink.nodes > 0,
      'encrypted_subscription_not_applied',
    );
    _event('SUBSCRIPTION_VERIFIED', {
      'applied': sink.applied,
      'nodes': sink.nodes,
      'bytes': sink.bytes,
      'sha256': sink.digest,
    });
    stage = 'push_handshake';
    await client.poller.pollNow();
    await _until(
      () =>
          metrics.activeStreams.isNotEmpty &&
          metrics.streamChunks > 0 &&
          client.poller.state.policy != null,
      'push_not_connected',
    );
    _require(metrics.pinReports == 0, 'unexpected_pin_mismatch');
    _event('PUSH_CONNECTED', {
      'streams': metrics.streamOpens,
      'ticket_requests': metrics.tickets,
      'signed_policy_seq': client.poller.state.policy!.seq,
    });

    stage = 'watch_notice';
    // Wait out the product's sequence coalescing window before arming the latency probe.
    await Future<void>.delayed(
      XClientRuntime.seqReactionGap + const Duration(seconds: 1),
    );
    await _until(() => metrics.httpActive == 0, 'initial_requests_not_quiet');
    client.poller.setIntervals(
      foreground: const Duration(minutes: 5),
      background: const Duration(seconds: 900),
    );
    final baseline = client.poller.state.policy!.notice?.id;
    final baselineSeq = client.poller.state.policy!.seq;
    final target = _option('XCLIENT_TEST_WATCH_NOTICE');
    final arm = _option('XCLIENT_TEST_ARM_FILE');
    if (arm.isNotEmpty) _require(!await File(arm).exists(), 'stale_arm_file');
    _event('READY', {
      'baseline_policy_seq': baselineSeq,
      'watch_notice': target,
      'arm_required': arm.isNotEmpty,
      'foreground_poll_seconds_for_probe': 300,
    });
    if (arm.isNotEmpty) {
      final deadline = DateTime.now().add(const Duration(minutes: 3));
      while (!await File(arm).exists()) {
        if (DateTime.now().isAfter(deadline)) {
          throw const _ProbeFailure('arm_timeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
    final watch = Stopwatch()..start();
    await _until(
      () {
        final notice = client.poller.state.policy?.notice;
        return notice != null &&
            notice.id != baseline &&
            (target.isEmpty ||
                notice.id == target ||
                notice.title.contains(target));
      },
      'signed_notice_not_received_within_10_seconds',
      timeout: const Duration(seconds: 10),
    );
    watch.stop();
    _require(
      client.poller.state.policy!.seq > baselineSeq &&
          metrics.lastPushPolicy > baselineSeq,
      'notice_change_has_no_push_hint',
    );
    _event('NOTICE_VERIFIED', {
      'latency_ms': watch.elapsedMilliseconds,
      'policy_seq': client.poller.state.policy!.seq,
      'push_hint_policy_seq': metrics.lastPushPolicy,
    });

    stage = 'background_poll_fallback';
    client.setForeground(false);
    await _until(
      () => metrics.activeStreams.isEmpty,
      'background_stream_not_closed',
    );
    client.poller.setIntervals(
      foreground: const Duration(seconds: 60),
      background: const Duration(seconds: 60),
    );
    final states = metrics.stateRequests;
    final opens = metrics.streamOpens;
    _event('BACKGROUND_POLL_WAIT', {
      'test_interval_seconds': 60,
      'product_default_seconds': 900,
    });
    await _until(
      () => metrics.stateRequests > states,
      'background_poll_timer_did_not_fire',
      timeout: const Duration(seconds: 70),
    );
    await _until(() => metrics.httpActive == 0, 'background_poll_not_complete');
    _require(
      metrics.streamOpens == opens && metrics.activeStreams.isEmpty,
      'background_reopened_push',
    );
    _event('BACKGROUND_POLL_VERIFIED', {
      'additional_state_requests': metrics.stateRequests - states,
    });
    stage = 'foreground_resume';
    client.setForeground(true);
    await _until(
      () => metrics.streamOpens > opens && metrics.activeStreams.isNotEmpty,
      'foreground_push_not_resumed',
      timeout: const Duration(seconds: 10),
    );
    _event('FOREGROUND_RESUMED', {'streams': metrics.streamOpens});
    stage = 'logout';
    final previousAuthorization = client.api.authorization;
    await client.logout();
    _require(
      !client.session.state.isLoggedIn &&
          !client.session.state.deviceRegistered &&
          client.api.authorization == null &&
          client.api.deviceId == null &&
          store.values.isEmpty &&
          sink.removed > 0 &&
          sink.bytes == 0 &&
          metrics.activeStreams.isEmpty,
      'logout_cleanup_failed',
    );
    var revoked = false;
    try {
      await client.api.call(
        'GET',
        '/api/v1/xclient/state',
        auth: false,
        headers: {'authorization': previousAuthorization!},
      );
    } on XbApiException catch (error) {
      revoked = error.kind == XbErrorKind.unauthorized;
    }
    _require(revoked, 'logout_token_not_revoked');
    _event('LOGOUT_VERIFIED', {
      'credentials_cleared': true,
      'profile_removed': true,
      'token_revoked': true,
      'streams_closed': true,
    });
    _event('PROBE_COMPLETE', {
      'passed': true,
      'subscription_applications': sink.applied,
      'stream_connections': metrics.streamOpens,
      'pin_reports': metrics.pinReports,
      'sanitized_warning_count': metrics.coreWarnings,
    });
  } catch (error) {
    final code = error is _ProbeFailure
        ? error.code
        : error is XbApiException
        ? error.kind.name
        : error.runtimeType.toString();
    _event('PROBE_FAILED', {'stage': stage, 'code': code});
    throw _ProbeFailure('$stage:$code');
  } finally {
    final client = runtime;
    if (client != null) {
      if (client.session.state.isLoggedIn) {
        try {
          await client.logout();
        } on Object {
          _event('CLEANUP_FAILED');
        }
      }
      client.dispose();
    }
    xcLogSink = previousLog;
  }
}

Future<void> _runPinProbe(String configPath, String certificatePath) async {
  var stage = 'pin_config';
  final transports = <HttpTransport>[];
  IoPushTransport? push;
  try {
    final config = jsonDecode(await File(configPath).readAsString());
    _require(config is Map<String, dynamic>, 'invalid_config');
    final brand = _brand(config as Map<String, dynamic>);
    _require(brand.builtinApiEndpoints.isNotEmpty, 'missing_test_endpoint');
    final endpoint = brand.builtinApiEndpoints.first.url;
    final host = Uri.parse(endpoint).host;
    _require(
      host == 'localhost' ||
          (InternetAddress.tryParse(host)?.isLoopback ?? false),
      'isolated_loopback_endpoint_required',
    );
    stage = 'pin_trust_certificate';
    final correct = await _certificatePin(certificatePath);
    SecurityContext.defaultContext.setTrustedCertificates(certificatePath);
    final wrong = base64.encode(List<int>.filled(32, 0));
    _require(correct != wrong, 'invalid_negative_pin_fixture');
    PinPolicy policy(PinMode mode, String value) => PinPolicy({
      host: HostPin(mode: mode, spki: {value}),
    });
    final uri = Uri.parse('$endpoint/api/v1/xclient/ping');
    final ua = buildUserAgent(
      const ClientInfo(
        platform: XcPlatform.windows,
        arch: 'x64',
        appVersion: '1.0.0',
        build: '1',
        osVersion: '10.0',
        deviceName: 'Isolated pin harness',
      ).uaParts(brandId: brand.brandId, coreVersion: brand.coreVersion),
    );
    Future<void> ping(HttpTransport transport) async {
      final response = await transport.send(
        TransportRequest(method: 'GET', uri: uri, headers: {'user-agent': ua}),
      );
      final body = jsonDecode(utf8.decode(response.body));
      _require(
        response.statusCode == 200 && body is Map && body['ok'] == true,
        'pin_ping_failed',
      );
    }

    stage = 'pin_correct_enforce';
    var correctReports = 0;
    final matching = IoHttpTransport(
      pins: () => policy(PinMode.enforce, correct),
      onPinReport: (_, _) {
        correctReports++;
      },
    );
    transports.add(matching);
    await ping(matching);
    _require(correctReports == 0, 'matching_pin_reported_mismatch');
    _event('PIN_CORRECT_ENFORCE_VERIFIED', {
      'http_status': 200,
      'mismatch_reports': correctReports,
    });

    stage = 'pin_wrong_report';
    var reportCount = 0;
    var reportBound = true;
    final reporting = IoHttpTransport(
      pins: () => policy(PinMode.report, wrong),
      onPinReport: (actualHost, actualPin) {
        reportCount++;
        reportBound = reportBound && actualHost == host && actualPin == correct;
      },
    );
    transports.add(reporting);
    await ping(reporting);
    _require(reportCount > 0 && reportBound, 'report_pin_not_reported');
    _event('PIN_WRONG_REPORT_VERIFIED', {
      'http_status': 200,
      'mismatch_reported': true,
      'reported_certificate_matches': true,
    });

    stage = 'pin_wrong_enforce';
    var enforceReports = 0;
    final enforcing = IoHttpTransport(
      pins: () => policy(PinMode.enforce, wrong),
      onPinReport: (_, _) {
        enforceReports++;
      },
    );
    transports.add(enforcing);
    var refusedBeforeSend = false;
    try {
      await ping(enforcing);
    } on TransportException catch (error) {
      refusedBeforeSend =
          error.kind == TransportFailure.pin && error.beforeSend;
    }
    _require(
      refusedBeforeSend && enforceReports > 0,
      'wrong_enforce_pin_not_rejected_before_send',
    );
    _event('PIN_WRONG_ENFORCE_VERIFIED', {
      'rejection': 'pin',
      'before_send': true,
      'mismatch_reported': true,
    });

    stage = 'push_wrong_enforce';
    var pushReports = 0;
    push = IoPushTransport(
      StrictHttpClientFactory(
        pins: () => policy(PinMode.enforce, wrong),
        onPinReport: (_, _) {
          pushReports++;
        },
      ),
    );
    var pushPinRejected = false;
    try {
      final connection = await push.open(
        PushTicket(
          uri: Uri.parse('$endpoint/api/v1/xclient/events'),
          value: base64Url.encode(List<int>.filled(32, 0)).replaceAll('=', ''),
        ),
        userAgent: ua,
      );
      connection.cancel();
    } on StrictPinMismatch {
      pushPinRejected = true;
    }
    _require(
      pushPinRejected && pushReports > 0,
      'push_wrong_pin_not_rejected_during_tls',
    );
    _event('PUSH_PIN_WRONG_ENFORCE_VERIFIED', {
      'rejection': 'tls_pin',
      'http_unauthorized': false,
      'mismatch_reported': true,
    });
    _event('PIN_PROBE_COMPLETE', {
      'passed': true,
      'matching_enforce': true,
      'mismatched_report': true,
      'mismatched_enforce_before_send': true,
      'push_mismatched_enforce': true,
    });
  } catch (error) {
    final code = error is _ProbeFailure
        ? error.code
        : error is TransportException
        ? error.kind.name
        : error.runtimeType.toString();
    _event('PIN_PROBE_FAILED', {'stage': stage, 'code': code});
    throw _ProbeFailure('$stage:$code');
  } finally {
    for (final transport in transports) {
      transport.close();
    }
    push?.close();
  }
}

void main() {
  final config = _option('XCLIENT_TEST_CONFIG');
  final certificate = _option('XCLIENT_TEST_CERT');
  test(
    'real isolated TLS SPKI pin policy and push rejection',
    () async {
      await _runPinProbe(path.normalize(config), path.normalize(certificate));
    },
    skip: config.isEmpty || certificate.isEmpty,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'real isolated XClient runtime, encrypted subscription and push',
    () async {
      await _runProbe(path.normalize(config), path.normalize(certificate));
    },
    skip: config.isEmpty || certificate.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
