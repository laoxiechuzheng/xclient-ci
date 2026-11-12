import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/dns_codec.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

const _oss1 = 'https://oss.example.com/boot-demo.json';
const _oss2 = 'https://cdn.example.org/boot-demo.json';
const _panel = 'https://builtin.example.com';
const _resolver = 'https://doh.example.net/dns-query';

void main() {
  final v = loadVectors('envelope_v1_core.json');
  final now = v['now'] as int;
  final keys = v['keys'] as Map<String, dynamic>;
  final docs = v['bootstrap'] as Map<String, dynamic>;
  Map<String, dynamic> doc(String name) => docs[name] as Map<String, dynamic>;

  final brand = BrandConfig(
    brandId: 'demo',
    displayName: 'Demo',
    builtinApiEndpoints: const [ApiEndpointSpec('https://builtin.example.com')],
    bootstrapSources: const [_oss1, _oss2],
    dohNames: const ['example.com'],
    dohResolvers: const [_resolver],
    ctrlPubKeys: (keys['ctrl'] as Map).cast<String, String>(),
    envPubKeys: (keys['env'] as Map).cast<String, String>(),
    obfKey: keys['obf'] as String,
  );

  late FakeTransport transport;
  late MemoryBootstrapCache cache;
  var panelEndpoints = <String>[];

  BootstrapResolver resolver() => BootstrapResolver(
    brand: brand,
    transport: transport,
    cache: cache,
    panelEndpoints: () => panelEndpoints,
    userAgent: () => 'demoClient/1.0.0',
    now: () => fromUnix(now),
    panelHead: const Duration(milliseconds: 40),
    stagger: const Duration(milliseconds: 20),
    perSource: const Duration(milliseconds: 500),
    budget: const Duration(seconds: 2),
  );

  /// Serves documents by URL; anything else fails to connect.
  void serve(Map<String, Object> byUrl) {
    transport.handler = (request) {
      final key = request.uri.replace(query: '').toString().replaceAll('?', '');
      final body = byUrl[key];
      if (body == null) connectFailure();
      if (body is TransportResponse) return body;
      if (body is Duration) {
        return Future.delayed(body, () => jsonResponse(byUrl['$key#late']));
      }
      return jsonResponse(body);
    };
  }

  setUp(() {
    transport = FakeTransport((_) => connectFailure());
    cache = MemoryBootstrapCache();
    panelEndpoints = [];
  });

  test('without cache the built-in endpoints are used', () async {
    final r = resolver();
    final state = await r.loadCache();
    expect(state.source, BootstrapSource.builtin);
    expect(state.payload, isNull);
    expect(state.endpoints(brand).single.url, 'https://builtin.example.com');
    expect(state.envKeys(brand, now).kids, ['env-1']);
  });

  test('a source wins, the cache keeps the signed original', () async {
    serve({_oss2: doc('plain')});
    final r = resolver();
    await r.loadCache();
    final state = await r.refresh();
    expect(state.source, BootstrapSource.oss);
    expect(state.seq, 1730000100);
    expect(state.stale, isFalse);
    expect(state.endpoints(brand).first.url, 'https://api-a.example.com');
    expect(state.envKeys(brand, now).kids.toSet(), {'env-1', 'env-2'});
    final cached = jsonDecode(cache.content!) as Map<String, dynamic>;
    expect((cached['doc'] as Map)['sig'], doc('plain')['sig']);

    // A new run reads it back and re-verifies it.
    final again = await resolver().loadCache();
    expect(again.source, BootstrapSource.cache);
    expect(again.seq, 1730000100);
  });

  test('a tampered cache is dropped', () async {
    final tampered = Map<String, dynamic>.of(doc('plain'))
      ..['sig'] = doc('rogue')['sig'];
    cache.content = jsonEncode({'v': 1, 'doc': tampered});
    final state = await resolver().loadCache();
    expect(state.source, BootstrapSource.builtin);
  });

  test('obfuscated copies verify', () async {
    serve({_oss1: doc('obfuscated')});
    final r = resolver();
    await r.loadCache();
    final state = await r.refresh();
    expect(state.seq, 1730000100);
  });

  for (final name in ['plain', 'obfuscated']) {
    test('bootstrap source accepts a signed Gateway envelope: $name', () async {
      serve({
        _oss1: {'ok': true, 'data': doc(name)},
      });
      final r = resolver();
      await r.loadCache();
      final state = await r.refresh(panel: false, doh: false);
      expect(state.source, BootstrapSource.oss);
      expect(state.seq, 1730000100);
      expect(state.stale, isFalse);
      final cached = jsonDecode(cache.content!) as Map<String, dynamic>;
      expect(cached['doc'], doc(name));
      expect((cached['doc'] as Map).containsKey('ok'), isFalse);
      expect(
        transport.requests.every(
          (request) => !request.headers.containsKey('authorization'),
        ),
        isTrue,
      );
    });
  }

  final invalidWrappers = <String, Object>{
    'false ok': {'ok': false, 'data': doc('plain')},
    'string ok': {'ok': 'true', 'data': doc('plain')},
    'numeric ok': {'ok': 1, 'data': doc('plain')},
    'missing ok': {'data': doc('plain')},
    'missing data': {'ok': true},
    'null data': {'ok': true, 'data': null},
    'array data': {
      'ok': true,
      'data': [doc('plain')],
    },
    'string data': {'ok': true, 'data': jsonEncode(doc('plain'))},
    'nested envelope': {
      'ok': true,
      'data': {'ok': true, 'data': doc('plain')},
    },
    'refused envelope with raw decoy': {
      ...doc('plain'),
      'ok': false,
      'data': doc('plain'),
    },
    'bad inner signature with raw decoy': {
      ...doc('plain'),
      'ok': true,
      'data': doc('rogue'),
    },
  };
  for (final entry in invalidWrappers.entries) {
    test(
      'bootstrap source rejects malformed Gateway envelope: ${entry.key}',
      () async {
        serve({_oss1: entry.value});
        final r = resolver();
        await r.loadCache();
        final state = await r.refresh(panel: false, doh: false);
        expect(state.payload, isNull);
        expect(cache.content, isNull);
      },
    );
  }

  test(
    'Gateway envelopes still require a valid signature and matching brand',
    () async {
      serve({
        _oss1: {'ok': true, 'data': doc('rogue')},
        _oss2: {'ok': true, 'data': doc('other_brand')},
      });
      final r = resolver();
      await r.loadCache();
      expect((await r.refresh(panel: false, doh: false)).payload, isNull);
      expect(cache.content, isNull);
    },
  );

  test('Gateway envelope cannot roll a held source back', () async {
    serve({_oss1: doc('plain')});
    final r = resolver();
    await r.loadCache();
    await r.refresh(panel: false, doh: false);
    final lastGood = cache.content;
    serve({
      _oss1: {'ok': true, 'data': doc('older')},
    });
    expect((await r.refresh(panel: false, doh: false)).seq, 1730000100);
    expect(cache.content, lastGood);
  });

  test(
    'Gateway envelope retains the existing expired-source fallback',
    () async {
      serve({
        _oss1: {'ok': true, 'data': doc('expired')},
      });
      final r = resolver();
      await r.loadCache();
      final state = await r.refresh(panel: false, doh: false);
      expect(state.seq, 1730000300);
      expect(state.stale, isTrue);
    },
  );

  test(
    'rollback is refused, a newer document under the backup kid is taken',
    () async {
      serve({_oss1: doc('plain')});
      final r = resolver();
      await r.loadCache();
      await r.refresh();
      serve({_oss1: doc('older')});
      var state = await r.refresh(doh: false);
      expect(state.seq, 1730000100);
      serve({_oss1: doc('older'), _oss2: doc('newer_backup_kid')});
      state = await r.refresh(doh: false);
      expect(state.seq, 1730000200);
    },
  );

  test(
    'bad signatures and other brands are skipped for a valid source',
    () async {
      serve({_oss1: doc('rogue'), _oss2: doc('other_brand')});
      final r = resolver();
      await r.loadCache();
      var state = await r.refresh(doh: false);
      expect(state.payload, isNull);
      serve({_oss1: doc('rogue'), _oss2: doc('plain')});
      state = await r.refresh(doh: false);
      expect(state.seq, 1730000100);
    },
  );

  test('an expired document never replaces the last good one', () async {
    serve({_oss1: doc('plain')});
    final r = resolver();
    await r.loadCache();
    await r.refresh();
    serve({_oss1: doc('expired')});
    final state = await r.refresh(doh: false);
    expect(state.seq, 1730000100);
    expect(state.stale, isTrue);
  });

  test('with nothing held, an expired document is used but stale', () async {
    serve({_oss1: doc('expired')});
    final r = resolver();
    await r.loadCache();
    final state = await r.refresh(doh: false);
    expect(state.seq, 1730000300);
    expect(state.stale, isTrue);
    // Reloaded from cache it is still stale.
    expect((await resolver().loadCache()).stale, isTrue);
  });

  test('the panel (L1) answers first and sources are not asked', () async {
    panelEndpoints = [_panel];
    serve({
      '$_panel/api/v1/xclient/bootstrap': {
        'ok': true,
        'data': doc('newer_backup_kid'),
      },
      _oss1: doc('plain'),
    });
    final r = resolver();
    await r.loadCache();
    final state = await r.refresh();
    expect(state.source, BootstrapSource.panel);
    expect(state.seq, 1730000200);
    expect(transport.requests.single.uri.queryParameters['brand'], 'demo');
  });

  test('panel responses use the same strict Gateway envelope rule', () async {
    panelEndpoints = [_panel];
    serve({
      '$_panel/api/v1/xclient/bootstrap': {
        ...doc('plain'),
        'ok': false,
        'data': doc('plain'),
      },
    });
    final r = resolver();
    await r.loadCache();
    expect((await r.refresh(sources: false, doh: false)).payload, isNull);
    expect(cache.content, isNull);
  });

  test('a slow panel lets the staggered sources race', () async {
    panelEndpoints = [_panel];
    serve({
      '$_panel/api/v1/xclient/bootstrap': const Duration(milliseconds: 300),
      '$_panel/api/v1/xclient/bootstrap#late': {
        'ok': true,
        'data': doc('newer_backup_kid'),
      },
      _oss1: doc('plain'),
    });
    final r = resolver();
    await r.loadCache();
    final state = await r.refresh();
    expect(state.source, BootstrapSource.oss);
    expect(state.seq, 1730000100);
  });

  test('DoH TXT (L3) when every HTTP source fails', () async {
    final txt = docs['doh_txt'] as String;
    transport.handler = (request) {
      if (!request.uri.toString().startsWith(_resolver)) connectFailure();
      final query = b64uDecode(request.uri.queryParameters['dns']!);
      expect(request.headers['accept'], 'application/dns-message');
      final chunks = <String>[
        for (var i = 0; i < txt.length; i += 255)
          txt.substring(i, i + 255 > txt.length ? txt.length : i + 255),
      ];
      return TransportResponse(
        statusCode: 200,
        body: _txtAnswer(Uint8List.fromList(query), chunks),
      );
    };
    final r = resolver();
    await r.loadCache();
    final state = await r.refresh();
    expect(state.source, BootstrapSource.doh);
    expect(state.payload!.isMini, isTrue);
    expect(state.seq, 1730000250);
    final dohRequest = transport.requests.last;
    final name = decodeDnsMessage(
      Uint8List.fromList([
        ...b64uDecode(dohRequest.uri.queryParameters['dns']!),
      ]),
    );
    expect(name.answers, isEmpty);
  });

  test('a newer mini document updates the endpoints of the full one', () async {
    serve({_oss1: doc('plain')});
    final r = resolver();
    await r.loadCache();
    await r.refresh();
    final mini = await r.verifyDocument(
      jsonDecode(b64uDecodeUtf8((docs['doh_txt'] as String).substring(4)))
          as Map<String, dynamic>,
    );
    final merged = r.state.payload!.withMini(mini.payload);
    expect(merged.seq, 1730000250);
    expect(merged.envKeys, isNotEmpty);
    expect(merged.sources, r.state.payload!.sources);
  });

  test('concurrent refreshes share one round', () async {
    serve({_oss1: doc('plain')});
    final r = resolver();
    await r.loadCache();
    final results = await Future.wait([r.refresh(), r.refresh()]);
    expect(results[0].seq, results[1].seq);
    expect(
      transport.requests.where((q) => q.uri.toString() == _oss1).length,
      1,
    );
  });
}

Uint8List _txtAnswer(Uint8List query, List<String> strings) {
  final rdata = BytesBuilder();
  for (final s in strings) {
    final bytes = utf8.encode(s);
    rdata
      ..addByte(bytes.length)
      ..add(bytes);
  }
  final data = rdata.takeBytes();
  return (BytesBuilder()
        ..add([query[0], query[1], 0x81, 0x80, 0, 1, 0, 1, 0, 0, 0, 0])
        ..add(query.sublist(12))
        ..add([
          0xc0,
          0x0c,
          0,
          16,
          0,
          1,
          0,
          0,
          0,
          60,
          data.length >> 8,
          data.length & 0xff,
        ])
        ..add(data))
      .takeBytes();
}
