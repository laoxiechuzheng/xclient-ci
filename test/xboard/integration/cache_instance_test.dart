import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

class _CacheFailure implements Exception {
  const _CacheFailure(this.code);
  final String code;
  @override
  String toString() => 'CacheInstanceFailure($code)';
}

void _require(bool condition, String code) {
  if (!condition) throw _CacheFailure(code);
}

void _event(String name, [Map<String, Object?> fields = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, ...fields}));

bool _loopback(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);

class _CacheTransport implements HttpTransport {
  final inner = IoHttpTransport(connectTimeout: const Duration(seconds: 3));
  final statuses = <String>[];
  @override
  Future<TransportResponse> send(TransportRequest request) async {
    _require(_loopback(request.uri.host), 'non_loopback_request');
    _require(
      !request.headers.containsKey('authorization'),
      'resolver_auth_header',
    );
    final response = await inner.send(request);
    final status = response.header('x-xclient-cache');
    if (status != null) statuses.add(status);
    return response;
  }

  @override
  void close() => inner.close();
}

Future<void> _arm(Directory work, String ready, String proceed) async {
  final next = File(path.join(work.path, proceed));
  _require(!await next.exists(), 'stale_control_flag');
  await File(path.join(work.path, ready)).writeAsString('ready\n');
  _event(ready.toUpperCase().replaceAll('.', '_'));
  final deadline = DateTime.now().add(const Duration(minutes: 2));
  while (!await next.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      throw const _CacheFailure('control_timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

Future<void> _runCacheProbe(
  String configPath,
  String certificate,
  String workPath,
) async {
  var stage = 'config';
  final transports = <_CacheTransport>[];
  final resolvers = <BootstrapResolver>[];
  final direct = IoHttpTransport();
  final oldLog = xcLogSink;
  var badSignatures = 0;
  xcLogSink = (message, {required warn}) {
    if (message.contains('bad_signature')) badSignatures++;
  };
  try {
    final raw = jsonDecode(await File(configPath).readAsString());
    _require(raw is Map<String, dynamic>, 'config_shape');
    final config = raw as Map<String, dynamic>;
    final base = Uri.tryParse('${config['cache_base']}');
    _require(
      base != null &&
          base.scheme == 'https' &&
          _loopback(base.host) &&
          base.userInfo.isEmpty &&
          !base.hasQuery &&
          !base.hasFragment,
      'loopback_https_cache_required',
    );
    final work = Directory(workPath);
    _require(
      await File(path.join(work.path, '.cache-test-owned')).exists(),
      'work_owner_required',
    );
    SecurityContext.defaultContext.setTrustedCertificates(certificate);
    final cacheUrl = '$base/bootstrap.json';
    final mutableUrl = '$base/mutable.json';
    final stored = File(path.join(work.path, 'bootstrap-cache.json'));
    final mutableStored = File(path.join(work.path, 'mutable-cache.json'));
    _require(
      !await stored.exists() && !await mutableStored.exists(),
      'client_cache_must_start_empty',
    );

    Future<TransportResponse> get(
      String resource, {
      String method = 'GET',
      bool foreign = false,
    }) => direct.send(
      TransportRequest(
        method: method,
        uri: Uri.parse('$base$resource'),
        headers: foreign
            ? const {
                'authorization': 'FixtureSentinel',
                'cookie': 'fixture=discard',
              }
            : const {},
      ),
    );
    void status(TransportResponse response, String expected) {
      _require(
        response.statusCode == 200 &&
            response.header('x-xclient-cache') == expected,
        'unexpected_cache_status_$expected',
      );
    }

    BootstrapResolver resolver(String source, BootstrapCache cache) {
      final transport = _CacheTransport();
      transports.add(transport);
      final brand = BrandConfig(
        brandId: config['brand'] as String,
        displayName: 'Isolated cache fixture',
        builtinApiEndpoints: const [],
        bootstrapSources: [source],
        ctrlPubKeys: (config['ctrl_pub_keys'] as Map).cast<String, String>(),
        obfKey: config['obf_key'] is String ? config['obf_key'] as String : '',
      );
      final value = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: cache,
        panelEndpoints: () => [],
        userAgent: () => 'CacheFixtureClient/1',
        panelHead: const Duration(milliseconds: 20),
        stagger: const Duration(milliseconds: 20),
        perSource: const Duration(seconds: 3),
        budget: const Duration(seconds: 10),
      );
      resolvers.add(value);
      return value;
    }

    stage = 'real_gateway_miss_hit';
    final miss = await get(
      '/bootstrap.json?brand=foreign&discard=1',
      foreign: true,
    );
    status(miss, 'MISS');
    final wrapped = jsonDecode(utf8.decode(miss.body));
    _require(
      wrapped is Map && wrapped['ok'] == true && wrapped['data'] is Map,
      'actual_gateway_wrapper_missing',
    );
    status(await get('/bootstrap.json?brand=another'), 'HIT');
    final initial = resolver(cacheUrl, FileBootstrapCache(stored.path));
    await initial.loadCache();
    final first = await initial.refresh(panel: false, doh: false);
    _require(
      first.source == BootstrapSource.oss &&
          first.payload?.brand == config['brand'] &&
          !first.stale,
      'real_cache_wrapper_not_adopted',
    );
    final seq = first.seq;
    final preserved = await stored.readAsString();
    _require(
      !(jsonDecode(preserved)['doc'] as Map).containsKey('ok'),
      'outer_wrapper_persisted',
    );
    _event('REAL_GATEWAY_CACHE_VERIFIED', {
      'miss': true,
      'hit': true,
      'wrapper_verified': true,
      'seq': seq,
      'brand_matches': true,
    });

    stage = 'header_method_and_media_boundaries';
    final echo = await get('/echo.json?brand=foreign&discard=1', foreign: true);
    status(echo, 'MISS');
    _require(
      echo.header('x-fixture-auth-present') == '0' &&
          echo.header('x-fixture-cookie-present') == '0' &&
          echo.header('x-fixture-fixed-args') == '1',
      'foreign_input_forwarded',
    );
    status(await get('/echo.json?irrelevant=2'), 'HIT');
    _require(
      (await get('/bootstrap.json', method: 'POST')).statusCode == 405,
      'post_not_rejected',
    );
    _require(
      (await get('/bootstrap.json', method: 'HEAD')).statusCode == 405,
      'head_not_rejected',
    );
    _require(
      (await get('/api/v1/user/info')).statusCode == 404,
      'non_bootstrap_route_proxied',
    );
    final htmlOne = await get('/html.json');
    final htmlTwo = await get('/html.json');
    status(htmlOne, 'MISS');
    status(htmlTwo, 'MISS');
    _require(
      htmlOne.header('content-type')?.startsWith('text/html') == true,
      'html_fixture_wrong_type',
    );
    _event('CACHE_BOUNDARIES_VERIFIED', {
      'foreign_headers_stripped': true,
      'fixed_args': true,
      'key_ignores_foreign_args': true,
      'get_only': true,
      'html200_cached': false,
      'authenticated_routes_proxied': false,
    });

    stage = 'upstream_ca_refusal';
    final caFailure = await get('/wrong-ca.json');
    _require(caFailure.statusCode == 502, 'untrusted_origin_ca_accepted');
    _event('UPSTREAM_CA_REFUSED', {
      'status': caFailure.statusCode,
      'verification_disabled': false,
    });

    stage = 'mutable_cache_warm';
    final mutableWarm = await get('/mutable.json');
    status(mutableWarm, 'MISS');
    status(await get('/mutable.json'), 'HIT');
    final held = resolver(mutableUrl, FileBootstrapCache(mutableStored.path));
    await held.loadCache();
    _require(
      (await held.refresh(panel: false, doh: false)).seq == seq,
      'mutable_good_not_adopted',
    );
    final lastGood = await mutableStored.readAsString();
    await _arm(work, 'mutable-ready.flag', 'mutable-bad.flag');
    await Future<void>.delayed(const Duration(seconds: 3));
    final replaced = await get('/mutable.json');
    status(replaced, 'EXPIRED');
    status(await get('/mutable.json'), 'HIT');
    _require(
      sha256.convert(replaced.body) != sha256.convert(mutableWarm.body),
      'synthetic_bad_response_not_replaced',
    );
    final badWrapper = jsonDecode(utf8.decode(replaced.body)) as Map;
    final badPayload = (badWrapper['data'] as Map)['payload'] as String;
    final claimed =
        jsonDecode(
              utf8.decode(base64Url.decode(base64Url.normalize(badPayload))),
            )
            as Map;
    _require(
      claimed['seq'] is int && (claimed['seq'] as int) > seq,
      'bad_cache_does_not_claim_newer_seq',
    );
    _event('NGINX_BAD_JSON_CACHED', {
      'expired_replaced': true,
      'hit': true,
      'nginx_ed25519_validation': false,
    });

    stage = 'origin_stop';
    await _arm(work, 'offline-ready.flag', 'origin-stopped.flag');
    await Future<void>.delayed(const Duration(seconds: 3));
    status(await get('/bootstrap.json'), 'STALE');
    final fresh = resolver(cacheUrl, MemoryBootstrapCache());
    await fresh.loadCache();
    final rescued = await fresh.refresh(panel: false, doh: false);
    _require(
      rescued.source == BootstrapSource.oss &&
          rescued.seq == seq &&
          rescued.payload?.brand == config['brand'] &&
          !rescued.stale,
      'cold_stale_rescue_failed',
    );
    final restarted = resolver(cacheUrl, FileBootstrapCache(stored.path));
    final restored = await restarted.loadCache();
    _require(
      restored.source == BootstrapSource.cache && restored.seq == seq,
      'restart_cache_not_verified',
    );
    _require(
      (await restarted.refresh(panel: false, doh: false)).seq == seq,
      'restart_rescue_rollback',
    );
    _require(
      await stored.readAsString() == preserved,
      'restart_replaced_same_last_good',
    );
    _event('STALE_COLD_AND_RESTART_VERIFIED', {
      'nginx_status': 'STALE',
      'cold_verified': true,
      'restart_verified': true,
      'seq': seq,
      'document_expired': false,
      'test_ttl_seconds': 2,
      'production_ttl_seconds': 60,
    });

    stage = 'client_rejects_cached_signature';
    final beforeSignatureErrors = badSignatures;
    final rejected = await held.refresh(panel: false, doh: false);
    _require(
      rejected.seq == seq && await mutableStored.readAsString() == lastGood,
      'bad_cache_replaced_client_last_good',
    );
    final invalid = resolver(mutableUrl, MemoryBootstrapCache());
    await invalid.loadCache();
    _require(
      (await invalid.refresh(panel: false, doh: false)).payload == null,
      'fresh_client_accepted_bad_signature',
    );
    _require(
      badSignatures >= beforeSignatureErrors + 2,
      'signature_rejection_not_observed',
    );
    _event('CACHED_BAD_SIGNATURE_REJECTED', {
      'fresh_rejected': true,
      'last_good_preserved': true,
      'signature_errors': badSignatures - beforeSignatureErrors,
    });
    _event('CACHE_PROBE_COMPLETE', {
      'passed': true,
      'anonymous_only': true,
      'client_signature_required': true,
    });
  } catch (error) {
    final code = error is _CacheFailure
        ? error.code
        : error is TransportException
        ? error.kind.name
        : error.runtimeType.toString();
    _event('CACHE_PROBE_FAILED', {'stage': stage, 'code': code});
    throw _CacheFailure('$stage:$code');
  } finally {
    for (final resolver in resolvers) {
      resolver.dispose();
    }
    for (final transport in transports) {
      transport.close();
    }
    direct.close();
    xcLogSink = oldLog;
  }
}

void main() {
  final config = Platform.environment['XCLIENT_CACHE_CONFIG'] ?? '';
  final certificate = Platform.environment['XCLIENT_CACHE_CERT'] ?? '';
  final work = Platform.environment['XCLIENT_CACHE_WORK_DIR'] ?? '';
  test(
    'real isolated Nginx bootstrap cache, signed rescue and rejection boundaries',
    () => _runCacheProbe(config, certificate, work),
    skip: config.isEmpty || certificate.isEmpty || work.isEmpty,
    timeout: const Timeout(Duration(minutes: 6)),
  );
}
