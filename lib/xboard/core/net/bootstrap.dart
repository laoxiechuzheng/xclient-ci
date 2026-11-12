import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../brand/brand_config.dart';
import '../crypto/b64u.dart';
import '../crypto/crypto_exception.dart';
import '../crypto/obfuscation.dart';
import '../crypto/signed_doc.dart';
import '../log.dart';
import 'dns_codec.dart';
import 'discovery.dart';
import 'spki.dart';
import 'transport.dart';

/// One env key of the bootstrap: verifies subscription envelopes until
/// [notAfter].
class EnvKeySpec {
  final String kid;
  final String pub;
  final int? notAfter;

  const EnvKeySpec({required this.kid, required this.pub, this.notAfter});
}

/// The verified payload of DESIGN §5.1. A DoH "mini" document carries only
/// api / seq / expires; [isMini] tells it apart.
class BootstrapPayload {
  final String brand;
  final int seq;
  final int issuedAt;
  final int expiresAt;
  final List<ApiEndpointSpec> api;
  final List<String> sources;
  final List<EnvKeySpec> envKeys;
  final PinPolicy pins;
  final int pollForeground;
  final int pollBackground;
  final bool isMini;
  final DiscoverySnapshot? discovery;

  const BootstrapPayload({
    required this.brand,
    required this.seq,
    this.issuedAt = 0,
    required this.expiresAt,
    this.api = const [],
    this.sources = const [],
    this.envKeys = const [],
    this.pins = const PinPolicy(),
    this.pollForeground = 60,
    this.pollBackground = 900,
    this.isMini = false,
    this.discovery,
  });

  bool isExpired(int now) => expiresAt <= now;

  /// Checks the payload against the brand and the https rule; throws
  /// [XcCryptoException] when it fails either.
  static BootstrapPayload parse(Map<String, dynamic> json, String brandId) {
    int asInt(Object? value) => switch (value) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v) ?? -1,
      _ => -1,
    };
    final schema = json['schema'];
    if (schema != null && asInt(schema) != 1) {
      throw const XcCryptoException(XcCryptoException.badVersion, 'schema');
    }
    if (json['brand'] != brandId) {
      throw const XcCryptoException(XcCryptoException.brand);
    }
    final seq = asInt(json['seq']);
    final expiresAt = asInt(json['expires_at'] ?? json['expires']);
    if (seq < 0 || expiresAt < 0) {
      throw const XcCryptoException(XcCryptoException.badFormat, 'seq');
    }
    final discovery = json.containsKey('discovery')
        ? DiscoverySnapshot.parse(json['discovery'])
        : null;
    final api = <ApiEndpointSpec>[];
    final rawApi = json['api'];
    if (discovery == null && rawApi is List) {
      for (final item in rawApi) {
        final url = item is Map ? item['url'] : item;
        final weight = item is Map ? asInt(item['weight'] ?? 100) : 100;
        final normalized = url is String ? normalizeBaseUrl(url) : null;
        if (normalized == null) {
          throw const XcCryptoException(XcCryptoException.insecureUrl, 'api');
        }
        api.add(ApiEndpointSpec(normalized, weight: weight <= 0 ? 1 : weight));
      }
    }
    final sources = <String>[];
    final rawSources = json['sources'];
    if (discovery == null && rawSources is List) {
      for (final url in rawSources) {
        if (url is! String || !isHttpsUrl(url)) {
          throw const XcCryptoException(
            XcCryptoException.insecureUrl,
            'sources',
          );
        }
        sources.add(url);
      }
    }
    final envKeys = <EnvKeySpec>[];
    final rawEnv = json['env_keys'];
    if (rawEnv is List) {
      for (final item in rawEnv) {
        if (item is! Map || item['kid'] is! String || item['pub'] is! String) {
          continue;
        }
        final notAfter = item['not_after'];
        envKeys.add(
          EnvKeySpec(
            kid: item['kid'] as String,
            pub: item['pub'] as String,
            notAfter: notAfter == null ? null : asInt(notAfter),
          ),
        );
      }
    }
    final poll = json['poll'];
    final fg = poll is Map ? asInt(poll['fg']) : -1;
    final bg = poll is Map ? asInt(poll['bg']) : -1;
    return BootstrapPayload(
      brand: brandId,
      seq: seq,
      issuedAt: asInt(json['issued_at']).clamp(0, 1 << 62),
      expiresAt: expiresAt,
      api: discovery?.api ?? api,
      sources: discovery?.sources ?? sources,
      envKeys: envKeys,
      pins: PinPolicy.fromJson(json['pins']),
      pollForeground: fg > 0 ? fg : 60,
      pollBackground: bg > 0 ? bg : 900,
      isMini:
          json['mini'] == true ||
          (discovery == null &&
              !json.containsKey('sources') &&
              !json.containsKey('env_keys')),
      discovery: discovery,
    );
  }

  /// A full document updated with what a newer mini document says.
  BootstrapPayload withMini(BootstrapPayload mini) => BootstrapPayload(
    brand: brand,
    seq: mini.seq,
    issuedAt: mini.issuedAt,
    expiresAt: mini.expiresAt,
    api: discovery != null || mini.api.isNotEmpty ? mini.api : api,
    sources: sources,
    envKeys: envKeys,
    pins: pins,
    pollForeground: pollForeground,
    pollBackground: pollBackground,
    discovery: discovery,
  );
}

enum BootstrapSource { builtin, cache, panel, oss, doh }

/// A verified document as received, kept so the cache can hold the signed
/// original.
class BootstrapDocument {
  final Map<String, dynamic> raw;
  final String payloadB64;
  final BootstrapPayload payload;

  const BootstrapDocument({
    required this.raw,
    required this.payloadB64,
    required this.payload,
  });
}

/// What the client runs on now.
class BootstrapState {
  /// Null while only the built-in endpoints are known.
  final BootstrapPayload? payload;
  final BootstrapSource source;

  /// The document has expired and no fresh one could be had.
  final bool stale;
  final DateTime? checkedAt;

  const BootstrapState({
    this.payload,
    this.source = BootstrapSource.builtin,
    this.stale = false,
    this.checkedAt,
  });

  int get seq => payload?.seq ?? -1;

  /// The pool to use: the document's API list, else the built-in one.
  List<ApiEndpointSpec> endpoints(BrandConfig brand) {
    final api = payload?.api ?? const [];
    return api.isEmpty && payload?.discovery == null
        ? brand.builtinApiEndpoints
        : api;
  }

  /// Built-in env keys plus the document's keys still in date.
  TrustedKeys envKeys(BrandConfig brand, int now) {
    final fromDoc = <String, String>{
      for (final key in payload?.envKeys ?? const <EnvKeySpec>[])
        if (key.notAfter == null || key.notAfter! >= now) key.kid: key.pub,
    };
    return brand.envKeys.merge(TrustedKeys.fromB64u(fromDoc));
  }

  PinPolicy get pins => payload?.pins ?? const PinPolicy();
}

/// Where the last good documents live between runs.
abstract class BootstrapCache {
  Future<String?> read();

  Future<void> write(String content);
}

/// A JSON file in the app support directory, replaced atomically.
class FileBootstrapCache implements BootstrapCache {
  final String path;

  const FileBootstrapCache(this.path);

  @override
  Future<String?> read() async {
    final file = File(path);
    if (!await file.exists()) return null;
    return file.readAsString();
  }

  @override
  Future<void> write(String content) async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(path);
  }
}

class MemoryBootstrapCache implements BootstrapCache {
  String? content;

  MemoryBootstrapCache([this.content]);

  @override
  Future<String?> read() async => content;

  @override
  Future<void> write(String content) async => this.content = content;
}

class _Launch {
  final Future<BootstrapDocument> Function() fetch;
  final BootstrapSource source;

  const _Launch(this.fetch, this.source);
}

/// Finds and keeps the newest valid bootstrap (DESIGN §5.1, §5.2):
/// L0 cache + built-in, L1 panel, L2 sources raced with staggering, L3 DoH.
class BootstrapResolver {
  final BrandConfig brand;
  final HttpTransport transport;
  final BootstrapCache cache;

  /// Base URLs of the endpoints to ask first (L1), best first.
  final List<String> Function() panelEndpoints;
  final String Function() userAgent;
  final DateTime Function() _now;
  final Duration panelHead;
  final Duration stagger;
  final Duration perSource;
  final Duration budget;

  BootstrapDocument? _full;
  BootstrapDocument? _mini;
  BootstrapState _state = const BootstrapState();
  final _changes = StreamController<BootstrapState>.broadcast();
  Future<BootstrapState>? _running;

  BootstrapResolver({
    required this.brand,
    required this.transport,
    required this.cache,
    required this.panelEndpoints,
    required this.userAgent,
    DateTime Function()? now,
    this.panelHead = const Duration(milliseconds: 300),
    this.stagger = const Duration(milliseconds: 250),
    this.perSource = const Duration(seconds: 5),
    this.budget = const Duration(seconds: 15),
  }) : _now = now ?? DateTime.now;

  BootstrapState get state => _state;

  int get lastFullSeq => _full?.payload.seq ?? -1;

  bool get needsFull => (_mini?.payload.seq ?? -1) > lastFullSeq;

  Stream<BootstrapState> get changes => _changes.stream;

  int get _nowSec => _now().millisecondsSinceEpoch ~/ 1000;

  void _set(BootstrapState next) {
    _state = next;
    _changes.add(next);
  }

  /// L0: re-verifies the cached documents; built-in endpoints otherwise.
  Future<BootstrapState> loadCache() async {
    try {
      final content = await cache.read();
      if (content != null) {
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          final full = decoded['doc'];
          final mini = decoded['mini'];
          if (full is Map<String, dynamic>) {
            try {
              final doc = await verifyDocument(full);
              if (!doc.payload.isMini) _full = doc;
            } catch (error) {
              xcLog(
                'bootstrap full cache unusable: ${_describe(error)}',
                warn: true,
              );
            }
          }
          if (mini is Map<String, dynamic>) {
            try {
              final doc = await verifyDocument(mini);
              if (doc.payload.isMini) _mini = doc;
            } catch (error) {
              xcLog(
                'bootstrap mini cache unusable: ${_describe(error)}',
                warn: true,
              );
            }
          }
        }
      }
    } catch (e) {
      xcLog('bootstrap cache unusable: $e', warn: true);
      _full = null;
      _mini = null;
    }
    final effective = _effective();
    _set(
      BootstrapState(
        payload: effective,
        source: effective == null
            ? BootstrapSource.builtin
            : BootstrapSource.cache,
        stale: effective?.isExpired(_nowSec) ?? false,
        checkedAt: _state.checkedAt,
      ),
    );
    return _state;
  }

  BootstrapPayload? _effective() {
    final full = _full?.payload;
    final mini = _mini?.payload;
    if (full == null) return mini;
    if (mini == null || mini.seq <= full.seq) return full;
    return full.withMini(mini);
  }

  /// Verifies a document from any source: kid ∈ built-in ctrl keys, the
  /// signature (over the de-obfuscated payload), brand, schema and https.
  Future<BootstrapDocument> verifyDocument(Map<String, dynamic> raw) async {
    final payload = raw['payload'];
    if (payload is! String) {
      throw const XcCryptoException(XcCryptoException.badFormat, 'payload');
    }
    final clear = await deobfuscateBootPayload(payload, brand.obfKeyBytes);
    final verified = await verifySignedDoc(
      raw,
      prefix: SignedDocKind.boot,
      keys: brand.ctrlKeys,
      payloadOverride: clear,
    );
    return BootstrapDocument(
      raw: Map.of(raw),
      payloadB64: clear,
      payload: BootstrapPayload.parse(verified.payload, brand.brandId),
    );
  }

  /// Runs one discovery round; concurrent callers share it.
  Future<BootstrapState> refresh({
    bool panel = true,
    bool sources = true,
    bool doh = true,
  }) {
    return _running ??= _refresh(
      panel: panel,
      sources: sources,
      doh: doh,
    ).whenComplete(() => _running = null);
  }

  Future<BootstrapState> _refresh({
    required bool panel,
    required bool sources,
    required bool doh,
  }) async {
    final active = _effective();
    final configured = {
      for (final endpoint in active?.api ?? <ApiEndpointSpec>[]) endpoint.url,
    };
    final endpoints = <String>{
      for (final url in panelEndpoints())
        if (configured.contains(url)) url,
      ...configured,
    };
    final remoteSources = _full?.payload.sources ?? const <String>[];
    final discovery = _full?.payload.discovery;
    final attemptedHttp = <String>{};
    final attemptedDoh = <String>{};
    final rounds = <(String, List<_Launch>)>[
      (
        'remote-http',
        _httpLaunches(
          panel || needsFull ? endpoints : const <String>[],
          sources ? remoteSources : const <String>[],
          attemptedHttp,
        ),
      ),
      if (doh && discovery != null)
        (
          'remote-doh',
          _dohLaunches(
            discovery.dohNames,
            discovery.dohResolvers,
            attemptedDoh,
          ),
        ),
      (
        'seed-http',
        _httpLaunches(
          brand.builtinApiEndpoints.map((e) => e.url),
          sources ? brand.bootstrapSources : const <String>[],
          attemptedHttp,
        ),
      ),
      if (doh)
        (
          'seed-doh',
          _dohLaunches(brand.dohNames, brand.dohResolvers, attemptedDoh),
        ),
    ]..removeWhere((round) => round.$2.isEmpty);
    (BootstrapDocument, BootstrapSource)? outcome;
    for (final (stage, launches) in rounds) {
      outcome = await _race(launches, stage, budget ~/ rounds.length);
      if (outcome != null) break;
    }
    final now = _now();
    if (outcome != null) {
      await _adopt(outcome.$1, outcome.$2, stale: false);
    } else if (_bestExpired case final expired?
        when _full == null && _mini == null) {
      // Nothing signed is held yet: an expired document still beats the
      // built-in list.
      await _adopt(expired.$1, expired.$2, stale: true);
    } else if (_bestExpired != null) {
      // DESIGN §5.1: an expired document never replaces the last good one;
      // keep it and flag the state stale.
      _set(
        BootstrapState(
          payload: _effective(),
          source: _state.source,
          stale: true,
          checkedAt: now,
        ),
      );
    } else {
      final effective = _effective();
      _set(
        BootstrapState(
          payload: effective,
          source: _state.source,
          stale: effective?.isExpired(_nowSec) ?? false,
          checkedAt: now,
        ),
      );
    }
    _bestExpired = null;
    return _state;
  }

  List<_Launch> _httpLaunches(
    Iterable<String> endpoints,
    Iterable<String> sources,
    Set<String> attempted,
  ) {
    final launches = <_Launch>[];
    for (final base in endpoints) {
      if (!attempted.add('panel:$base')) continue;
      launches.add(_Launch(() => _fetchPanel(base), BootstrapSource.panel));
    }
    for (final url in sources) {
      if (!attempted.add('oss:$url')) continue;
      launches.add(_Launch(() => _fetchJson(url), BootstrapSource.oss));
    }
    return launches;
  }

  List<_Launch> _dohLaunches(
    List<String> names,
    List<String> resolvers,
    Set<String> attempted,
  ) {
    final launches = <_Launch>[];
    for (final name in names) {
      for (final resolver in resolvers) {
        if (!attempted.add('$resolver\n$name')) continue;
        launches.add(
          _Launch(() => _fetchDoh(resolver, name), BootstrapSource.doh),
        );
      }
    }
    return launches;
  }

  (BootstrapDocument, BootstrapSource)? _bestExpired;

  /// Whether [doc] may replace what is held: seq never goes back, and the
  /// same seq must carry the same payload.
  bool _acceptable(BootstrapDocument doc) {
    final held = doc.payload.isMini ? (_mini ?? _full) : _full;
    final current = _effective();
    final floor = current?.seq ?? -1;
    if (doc.payload.seq < floor) return false;
    if (doc.payload.seq == floor && held != null && held.payload.seq == floor) {
      return held.payloadB64 == doc.payloadB64 ||
          (doc.payload.isMini && _full?.payload.seq == floor);
    }
    return true;
  }

  final Map<String, int> _cursors = {};

  Future<(BootstrapDocument, BootstrapSource)?> _race(
    List<_Launch> launches,
    String stage,
    Duration roundBudget,
  ) {
    final offset = (_cursors[stage] ?? 0) % launches.length;
    final queue = [...launches.skip(offset), ...launches.take(offset)];
    final completer = Completer<(BootstrapDocument, BootstrapSource)?>();
    Timer? launchTimer;
    Timer? deadline;
    var started = 0;
    var active = 0;
    void finish((BootstrapDocument, BootstrapSource)? value) {
      if (completer.isCompleted) return;
      launchTimer?.cancel();
      deadline?.cancel();
      _cursors[stage] = value != null
          ? 0
          : (offset + started) % launches.length;
      completer.complete(value);
    }

    late void Function() pump;
    void start() {
      if (completer.isCompleted) return;
      final launch = queue[started++];
      active++;
      launch
          .fetch()
          .timeout(perSource < roundBudget ? perSource : roundBudget)
          .then(
            (doc) {
              if (completer.isCompleted) return;
              if (!_acceptable(doc)) return;
              if (doc.payload.isExpired(_nowSec)) {
                final best = _bestExpired;
                if (best == null || best.$1.payload.seq < doc.payload.seq) {
                  _bestExpired = (doc, launch.source);
                }
              } else if (doc.payload.seq > _state.seq ||
                  (!doc.payload.isMini &&
                      (_full?.payload.seq ?? -1) < doc.payload.seq)) {
                finish((doc, launch.source));
              }
            },
            onError: (Object error) {
              xcLog(
                'bootstrap ${launch.source.name} failed: ${_describe(error)}',
                warn: true,
              );
            },
          )
          .whenComplete(() {
            active--;
            if (!completer.isCompleted &&
                active == 0 &&
                started < queue.length) {
              launchTimer?.cancel();
              launchTimer = null;
              start();
            } else {
              pump();
            }
          });
      pump();
    }

    pump = () {
      if (completer.isCompleted || launchTimer != null) return;
      if (started == queue.length) {
        if (active == 0) finish(null);
        return;
      }
      if (active >= 4) return;
      final next = queue[started];
      final gap =
          started > 0 &&
              next.source == BootstrapSource.oss &&
              queue[started - 1].source == BootstrapSource.panel
          ? panelHead
          : stagger;
      launchTimer = Timer(gap, () {
        launchTimer = null;
        start();
      });
    };
    deadline = Timer(roundBudget, () => finish(null));
    start();
    return completer.future;
  }

  static String _describe(Object e) => switch (e) {
    XcCryptoException(:final code) => code,
    TransportException(:final kind) => kind.name,
    TimeoutException() => 'timeout',
    _ => e.runtimeType.toString(),
  };

  Future<void> _adopt(
    BootstrapDocument doc,
    BootstrapSource source, {
    required bool stale,
  }) async {
    if (doc.payload.isMini) {
      _mini = doc;
    } else {
      _full = doc;
      if (_mini != null && _mini!.payload.seq <= doc.payload.seq) {
        _mini = null;
      }
    }
    try {
      await cache.write(
        jsonEncode({'v': 1, 'doc': ?_full?.raw, 'mini': ?_mini?.raw}),
      );
    } catch (e) {
      xcLog('bootstrap cache write failed: ${e.runtimeType}', warn: true);
    }
    _set(
      BootstrapState(
        payload: _effective(),
        source: source,
        stale: stale,
        checkedAt: _now(),
      ),
    );
  }

  Future<Map<String, dynamic>> _getJson(Uri uri, {String? accept}) async {
    final response = await transport.send(
      TransportRequest(
        method: 'GET',
        uri: uri,
        headers: {
          'user-agent': userAgent(),
          'accept': accept ?? 'application/json',
        },
        timeout: perSource,
      ),
    );
    if (response.statusCode != 200) {
      throw TransportException(
        TransportFailure.io,
        message: 'http ${response.statusCode}',
      );
    }
    final decoded = jsonDecode(utf8.decode(response.body));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('bootstrap: not an object');
    }
    return decoded;
  }

  Future<BootstrapDocument> _fetchPanel(String base) => _fetchJson(
    Uri.parse(
      '$base/api/v1/xclient/bootstrap',
    ).replace(queryParameters: {'brand': brand.brandId}).toString(),
  );

  Future<BootstrapDocument> _fetchJson(String url) async {
    final body = await _getJson(Uri.parse(url));
    if (body.containsKey('ok') || body.containsKey('data')) {
      final data = body['data'];
      if (body['ok'] != true || data is! Map<String, dynamic>) {
        throw const FormatException('bootstrap: invalid response envelope');
      }
      return verifyDocument(data);
    }
    return verifyDocument(body);
  }

  /// L3: `_xc.<name>` TXT over RFC 8484 GET; the value is `xc1:` + b64u of a
  /// signed (mini) bootstrap document.
  Future<BootstrapDocument> _fetchDoh(String resolver, String name) async {
    final qname = name.startsWith('_xc.') ? name : '_xc.$name';
    final query = b64uEncode(encodeDnsQuery(qname));
    final uri = Uri.parse(resolver).replace(queryParameters: {'dns': query});
    final response = await transport.send(
      TransportRequest(
        method: 'GET',
        uri: uri,
        headers: {
          'accept': 'application/dns-message',
          'user-agent': userAgent(),
        },
        timeout: perSource,
      ),
    );
    if (response.statusCode != 200) {
      throw TransportException(
        TransportFailure.io,
        message: 'doh ${response.statusCode}',
      );
    }
    final message = decodeDnsMessage(response.body);
    if (message.rcode != 0) {
      throw FormatException('doh rcode ${message.rcode}');
    }
    Exception? lastError;
    for (final txt in message.txtRecords) {
      if (!txt.startsWith('xc1:')) continue;
      try {
        final decoded = jsonDecode(b64uDecodeUtf8(txt.substring(4)));
        if (decoded is Map<String, dynamic>) {
          return await verifyDocument(decoded);
        }
      } on Exception catch (e) {
        lastError = e;
      }
    }
    throw lastError ?? const FormatException('doh: no xc1 record');
  }

  void dispose() {
    _changes.close();
  }
}
