import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/crypto/crypto_exception.dart';
import 'package:fl_clash/xboard/core/crypto/signed_doc.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/dns_codec.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/push/push_ticket.dart';
import 'package:fl_clash/xboard/core/push/push_transport.dart';
import 'package:fl_clash/xboard/core/runtime.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/connection_gate.dart';
import 'package:fl_clash/xboard/lifecycle.dart';
import 'package:fl_clash/xboard/probe/probe_runtime.dart';
import 'package:fl_clash/xboard/providers.dart' as xc;
import 'package:fl_clash/xboard/update/update_providers.dart';

import 'helpers.dart';

const _active = 'https://active.example.invalid';
const _remote = 'https://remote.example.invalid/bootstrap.json';
const _seed = 'https://seed.example.invalid/bootstrap.json';
const _now = 1800000000;

Map<String, dynamic> _discovery() => {
  'version': 1,
  'api_pools': [
    {
      'id': 'primary',
      'enabled': true,
      'endpoints': [
        {'url': '$_active/', 'weight': 80},
        {'url': _active, 'weight': 90},
      ],
    },
    {
      'id': 'disabled',
      'enabled': false,
      'endpoints': [
        {'url': 'https://disabled.example.invalid', 'weight': 100},
      ],
    },
  ],
  'oss_pools': [
    {
      'id': 'primary',
      'enabled': true,
      'urls': [_remote, _remote],
    },
    {
      'id': 'disabled',
      'enabled': false,
      'urls': ['https://deleted.example.invalid/bootstrap.json'],
    },
  ],
  'doh': {
    'names': ['_xc.Remote.Example.Invalid.'],
    'resolvers': ['https://remote-dns.example.invalid/dns-query'],
  },
};

Map<String, dynamic> _payload(int seq, {Object? discovery}) => {
  'schema': 1,
  'brand': 'example',
  'seq': seq,
  'issued_at': _now - 1,
  'expires_at': _now + 3600,
  'api': [
    {'url': 'https://legacy.example.invalid', 'weight': 100},
  ],
  'sources': ['https://old.example.invalid/bootstrap.json'],
  'env_keys': <Object>[],
  'discovery': ?discovery,
};

class _Streams implements PushTransport {
  final tickets = <PushTicket>[];
  final streams = <StreamController<List<int>>>[];
  @override
  Future<PushConnection> open(
    PushTicket ticket, {
    required String userAgent,
  }) async {
    tickets.add(ticket);
    final stream = StreamController<List<int>>();
    streams.add(stream);
    return PushConnection(
      body: stream.stream,
      cancel: () => unawaited(stream.close()),
    );
  }

  @override
  void close() {
    for (final stream in streams) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}

class _Sink implements ManagedProfileSink {
  @override
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  }) async {}
  @override
  Future<void> remove() async {}
}

class _NoViewProbe extends Fake implements XcProbeRuntime {}

Uint8List _dnsAnswer(List<int> query, String txt) {
  final bytes = utf8.encode(txt);
  final record = BytesBuilder();
  for (var offset = 0; offset < bytes.length; offset += 255) {
    final end = offset + 255 < bytes.length ? offset + 255 : bytes.length;
    record
      ..addByte(end - offset)
      ..add(bytes.sublist(offset, end));
  }
  final data = record.takeBytes();
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
          data.length & 255,
        ])
        ..add(data))
      .takeBytes();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SimpleKeyPair signingKey;
  late BrandConfig brand;
  late Map<String, dynamic> signedInitial;
  late Map<String, dynamic> signedChanged;
  late Map<String, dynamic> signedPins;
  late Map<String, dynamic> signedEmpty;
  late Map<String, dynamic> signedMini;
  late Map<String, dynamic> signedMiniHigher;
  late Map<String, dynamic> signedCatchup;
  Future<Map<String, dynamic>> sign(Map<String, dynamic> payload) async {
    final encoded = b64uEncodeUtf8(jsonEncode(payload));
    final signature = await Ed25519().sign(
      utf8.encode('${SignedDocKind.boot}$encoded'),
      keyPair: signingKey,
    );
    return {
      'v': 1,
      'kid': 'test',
      'payload': encoded,
      'sig': b64uEncode(signature.bytes),
    };
  }

  setUpAll(() async {
    signingKey = await Ed25519().newKeyPairFromSeed(
      List.generate(32, (i) => i),
    );
    brand = BrandConfig(
      brandId: 'example',
      displayName: 'Example',
      builtinApiEndpoints: const [
        ApiEndpointSpec('https://seed-api.example.invalid'),
      ],
      bootstrapSources: const [_seed],
      dohNames: const ['seed.example.invalid'],
      dohResolvers: const ['https://seed-dns.example.invalid/dns-query'],
      ctrlPubKeys: {
        'test': b64uEncode((await signingKey.extractPublicKey()).bytes),
      },
    );
    signedInitial = await sign(_payload(1, discovery: _discovery()));
    final changed = _discovery();
    ((changed['api_pools'] as List).first['endpoints'] as List).insert(0, {
      'url': 'https://new-api.example.invalid',
      'weight': 100,
    });
    signedChanged = await sign(_payload(2, discovery: changed));
    signedPins = await sign(
      _payload(3, discovery: changed)
        ..['pins'] = {
          'new-api.example.invalid': {
            'mode': 'report',
            'spki': ['test-pin'],
          },
        },
    );
    signedEmpty = await sign(
      _payload(4, discovery: _discovery()..['api_pools'] = <Object>[]),
    );
    signedMini = await sign({
      'schema': 1,
      'brand': 'example',
      'seq': 2,
      'expires_at': _now + 3600,
      'mini': true,
      'api': [
        {'url': 'https://new-api.example.invalid', 'weight': 100},
      ],
    });
    signedMiniHigher = await sign({
      ...jsonDecode(b64uDecodeUtf8(signedMini['payload'] as String))
          as Map<String, dynamic>,
      'seq': 3,
    });
    final catchup = _discovery();
    catchup['api_pools'] = [
      {
        'id': 'new',
        'enabled': true,
        'endpoints': [
          {'url': 'https://new-api.example.invalid', 'weight': 100},
        ],
      },
    ];
    catchup['oss_pools'] = [
      {
        'id': 'new',
        'enabled': true,
        'urls': ['https://new-oss.example.invalid/bootstrap.json'],
      },
    ];
    signedCatchup = await sign(_payload(2, discovery: catchup));
  });

  test('discovery replaces legacy fields and deduplicates enabled pools', () {
    final parsed = BootstrapPayload.parse(
      _payload(1, discovery: _discovery()),
      'example',
    );
    expect(parsed.api.map((e) => e.url), [_active]);
    expect(parsed.api.single.weight, 80);
    expect(parsed.sources, [_remote]);
  });

  test('multiple enabled pools flatten once in configured order', () {
    final snapshot = _discovery();
    (snapshot['api_pools'] as List).add({
      'id': 'secondary',
      'enabled': true,
      'endpoints': [
        {'url': _active, 'weight': 1000},
        {'url': 'https://secondary.example.invalid/', 'weight': 1},
      ],
    });
    (snapshot['oss_pools'] as List).add({
      'id': 'secondary',
      'enabled': true,
      'urls': [
        _remote,
        'https://secondary.example.invalid/boot.json?version=1',
      ],
    });
    final payload = BootstrapPayload.parse(
      _payload(1, discovery: snapshot),
      'example',
    );
    expect(payload.api.map((e) => e.url), [
      _active,
      'https://secondary.example.invalid',
    ]);
    expect(payload.api.first.weight, 80);
    expect(payload.sources, [
      _remote,
      'https://secondary.example.invalid/boot.json?version=1',
    ]);
  });

  test('explicit empty discovery API never restores built-in endpoints', () {
    final snapshot = _discovery()..['api_pools'] = <Object>[];
    final parsed = BootstrapPayload.parse(
      _payload(1, discovery: snapshot),
      'example',
    );
    expect(BootstrapState(payload: parsed).endpoints(brand), isEmpty);
    final legacy = BootstrapPayload.parse(
      _payload(1)..['api'] = <Object>[],
      'example',
    );
    expect(
      BootstrapState(payload: legacy).endpoints(brand),
      brand.builtinApiEndpoints,
    );
  });

  test(
    'all discovery members including disabled pools validate atomically',
    () {
      final invalid = <Object?>[
        null,
        'not-an-object',
        {..._discovery()}..remove('doh'),
        {..._discovery(), 'version': '1'},
        {..._discovery(), 'api_pools': {}},
        {
          ..._discovery(),
          'api_pools': List.filled(
            33,
            (_discovery()['api_pools'] as List).first,
          ),
        },
        {
          ..._discovery(),
          'api_pools': [
            {'id': 'bad id', 'enabled': true, 'endpoints': []},
          ],
        },
        {
          ..._discovery(),
          'api_pools': [
            {'id': 'duplicate', 'enabled': true, 'endpoints': []},
            {'id': 'duplicate', 'enabled': false, 'endpoints': []},
          ],
        },
        for (final enabled in [0, 'true', null])
          {
            ..._discovery(),
            'oss_pools': [
              {'id': 'x', 'enabled': enabled, 'urls': []},
            ],
          },
        for (final weight in [0, 1001, 1.5, '100', null])
          {
            ..._discovery(),
            'api_pools': [
              {
                'id': 'x',
                'enabled': false,
                'endpoints': [
                  {'url': _active, 'weight': weight},
                ],
              },
            ],
          },
        for (final url in [
          'http://bad.invalid',
          'https://name:password@bad.invalid',
          'https://@bad.invalid',
          'https://bad.invalid/#fragment',
          'https://bad.invalid/ white',
          'https://bad.invalid/a\u0000b',
          'https://bad.invalid/a\u007fb',
          'https://bad.invalid/a\u00a0b',
          'https://bad.invalid/a\u2003b',
          'https://bad.invalid/a\uFEFFb',
          'https://-bad.invalid/path',
          'https://under_score.invalid/path',
          'https://bad.invalid./path',
          'https://bad.invalid:65536/path',
          'https://${['a' * 63, 'b' * 63, 'c' * 63, 'd' * 62].join('.')}/path',
        ])
          {
            ..._discovery(),
            'oss_pools': [
              {
                'id': 'x',
                'enabled': false,
                'urls': [url],
              },
            ],
          },
        {
          ..._discovery(),
          'api_pools': [
            {
              'id': 'x',
              'enabled': true,
              'endpoints': [
                {'url': '$_active?secret=value', 'weight': 1},
              ],
            },
          ],
        },
        for (final name in [
          '_xc.',
          '-bad.invalid',
          'bad..invalid',
          '*.invalid',
          'bad_name.invalid',
          ['a' * 63, 'b' * 63, 'c' * 63, 'd' * 58].join('.'),
          '_xc.${['a' * 63, 'b' * 63, 'c' * 63, 'd' * 58].join('.')}',
        ])
          {
            ..._discovery(),
            'doh': {
              'names': [name],
              'resolvers': [],
            },
          },
        {
          ..._discovery(),
          'doh': {
            'names': [],
            'resolvers': List.filled(17, 'https://dns.example.invalid/query'),
          },
        },
      ];
      for (var index = 0; index < invalid.length; index++) {
        final json = _payload(1)..['discovery'] = invalid[index];
        expect(
          () => BootstrapPayload.parse(json, 'example'),
          throwsA(isA<XcCryptoException>()),
          reason: 'invalid fixture $index',
        );
      }
    },
  );

  test(
    'invalid newer snapshots and older or tampered documents cannot replace last good',
    () async {
      final bad = _discovery()..remove('doh');
      final candidates = [
        await sign(_payload(9, discovery: bad)),
        await sign(_payload(0, discovery: _discovery())),
        {...signedChanged, 'payload': signedInitial['payload']},
      ];
      final cache = MemoryBootstrapCache(
        jsonEncode({'v': 1, 'doc': signedInitial}),
      );
      final transport = FakeTransport((_) => connectFailure());
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: cache,
        panelEndpoints: () => [_active],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
        stagger: Duration.zero,
        panelHead: Duration.zero,
      );
      addTearDown(resolver.dispose);
      await resolver.loadCache();
      final saved = cache.content;
      for (final candidate in candidates) {
        transport.handler = (_) => jsonResponse(candidate);
        await resolver.refresh(doh: false);
        expect(resolver.state.seq, 1);
        expect(resolver.state.payload!.sources, [_remote]);
        expect(cache.content, saved);
      }
    },
  );

  test(
    'sources-only refresh still rescues empty pools through signed seed API',
    () async {
      final snapshot = _discovery();
      snapshot['api_pools'] = <Object>[];
      snapshot['oss_pools'] = <Object>[];
      snapshot['doh'] = {'names': <Object>[], 'resolvers': <Object>[]};
      final first = await sign(_payload(1, discovery: snapshot));
      final transport = FakeTransport((request) {
        expect(request.headers.containsKey('authorization'), isFalse);
        if (request.uri.host == 'seed-api.example.invalid') {
          return jsonResponse({'ok': true, 'data': signedChanged});
        }
        connectFailure();
      });
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: MemoryBootstrapCache(jsonEncode({'v': 1, 'doc': first})),
        panelEndpoints: () => [],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
      );
      addTearDown(resolver.dispose);
      await resolver.loadCache();
      expect(resolver.state.endpoints(brand), isEmpty);
      expect((await resolver.refresh(panel: false)).seq, 2);
      expect(
        resolver.state.payload!.api.first.url,
        'https://new-api.example.invalid',
      );
    },
  );

  test(
    'an unchanged fast mirror cannot starve a newer signed snapshot',
    () async {
      const newer = 'https://newer.example.invalid/bootstrap.json';
      final snapshot = _discovery();
      snapshot['api_pools'] = <Object>[];
      snapshot['oss_pools'] = [
        {
          'id': 'mirrors',
          'enabled': true,
          'urls': [_remote, newer],
        },
      ];
      final old = await sign(_payload(1, discovery: snapshot));
      final next = await sign(_payload(2, discovery: snapshot));
      final transport = FakeTransport(
        (request) => jsonResponse(request.uri.toString() == newer ? next : old),
      );
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: MemoryBootstrapCache(jsonEncode({'v': 1, 'doc': old})),
        panelEndpoints: () => [],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
      );
      addTearDown(resolver.dispose);
      await resolver.loadCache();
      expect((await resolver.refresh(panel: false, doh: false)).seq, 2);
      expect(
        transport.requests.any((request) => request.uri.toString() == newer),
        isTrue,
      );
    },
  );

  test('remote OSS recovers all failed APIs before built-in rescue', () async {
    final first = await sign(_payload(1, discovery: _discovery()));
    final nextSnapshot = _discovery()..['oss_pools'] = <Object>[];
    final second = await sign(_payload(2, discovery: nextSnapshot));
    final cache = MemoryBootstrapCache(jsonEncode({'v': 1, 'doc': first}));
    final transport = FakeTransport((request) {
      if (request.uri.toString() == _remote) return jsonResponse(second);
      if (request.uri.toString() == _seed) return jsonResponse(first);
      connectFailure();
    });
    final resolver = BootstrapResolver(
      brand: brand,
      transport: transport,
      cache: cache,
      panelEndpoints: () => [_active],
      userAgent: () => 'ExampleClient/1.0',
      now: () => fromUnix(_now),
      stagger: Duration.zero,
      panelHead: Duration.zero,
    );
    addTearDown(resolver.dispose);
    await resolver.loadCache();
    final state = await resolver.refresh();
    expect(state.seq, 2);
    expect(transport.requests.any((r) => r.uri.toString() == _seed), isFalse);
    expect(state.payload!.sources, isEmpty);
    final restart = BootstrapResolver(
      brand: brand,
      transport: transport,
      cache: cache,
      panelEndpoints: () => [],
      userAgent: () => 'ExampleClient/1.0',
      now: () => fromUnix(_now),
    );
    addTearDown(restart.dispose);
    expect((await restart.loadCache()).payload!.sources, isEmpty);
  });

  test(
    'cache preserves full discovery under a mini and isolates invalid mini data',
    () async {
      final mini = await sign({
        'schema': 1,
        'brand': 'example',
        'seq': 2,
        'expires_at': _now + 3600,
        'mini': true,
        'api': <Object>[],
      });
      final cache = MemoryBootstrapCache(
        jsonEncode({'v': 1, 'doc': signedInitial, 'mini': mini}),
      );
      final transport = FakeTransport(
        (request) => request.uri.toString() == _remote
            ? jsonResponse(signedChanged)
            : connectFailure(),
      );
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: cache,
        panelEndpoints: () => [],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
      );
      addTearDown(resolver.dispose);
      final state = await resolver.loadCache();
      expect(state.seq, 2);
      expect(state.endpoints(brand), isEmpty);
      expect(state.payload!.discovery!.apiPools.length, 2);
      expect(state.payload!.sources, [_remote]);
      expect(state.payload!.discovery!.dohNames, [
        '_xc.remote.example.invalid',
      ]);
      await resolver.refresh(panel: false, doh: false);
      expect(
        resolver.state.payload!.api.first.url,
        'https://new-api.example.invalid',
      );
      expect((jsonDecode(cache.content!) as Map)['mini'], isNull);
      cache.content = jsonEncode({
        'v': 1,
        'doc': signedInitial,
        'mini': {...mini, 'sig': 'bad'},
      });
      final restart = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: cache,
        panelEndpoints: () => [],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
      );
      addTearDown(restart.dispose);
      final intact = await restart.loadCache();
      expect(intact.seq, 1);
      expect(intact.payload!.sources, [_remote]);
    },
  );

  test(
    'remote DoH is tried before seed rescue and unsigned seed cannot reset API',
    () async {
      final mini = await sign({
        'schema': 1,
        'brand': 'example',
        'seq': 2,
        'expires_at': _now + 3600,
        'mini': true,
        'api': [
          {'url': 'https://mini.example.invalid', 'weight': 100},
        ],
      });
      final cache = MemoryBootstrapCache(
        jsonEncode({'v': 1, 'doc': signedInitial}),
      );
      final transport = FakeTransport((request) {
        if (request.uri.host == 'remote-dns.example.invalid') {
          final query = b64uDecode(request.uri.queryParameters['dns']!);
          expect(
            query,
            encodeDnsQuery(
              '_xc.remote.example.invalid',
              id: (query[0] << 8) | query[1],
            ),
          );
          return TransportResponse(
            statusCode: 200,
            body: _dnsAnswer(query, 'xc1:${b64uEncodeUtf8(jsonEncode(mini))}'),
          );
        }
        if (request.uri.toString() == _seed) {
          return jsonResponse({...signedChanged, 'sig': 'bad'});
        }
        connectFailure();
      });
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: cache,
        panelEndpoints: () => [_active],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
        stagger: Duration.zero,
        panelHead: Duration.zero,
      );
      addTearDown(resolver.dispose);
      await resolver.loadCache();
      final state = await resolver.refresh();
      expect(state.seq, 2);
      expect(state.payload!.api.single.url, 'https://mini.example.invalid');
      expect(state.payload!.sources, [_remote]);
      expect(
        transport.requests.any((request) => request.uri.toString() == _seed),
        isFalse,
      );
      transport.requests.clear();
      transport.handler = (request) => request.uri.toString() == _seed
          ? jsonResponse({...signedChanged, 'sig': 'bad'})
          : connectFailure();
      await resolver.refresh();
      expect(resolver.state.seq, 2);
      expect(
        resolver.state.payload!.api.single.url,
        'https://mini.example.invalid',
      );
      expect(
        transport.requests.indexWhere(
          (request) => request.uri.host == 'remote-dns.example.invalid',
        ),
        lessThan(
          transport.requests.indexWhere(
            (request) => request.uri.toString() == _seed,
          ),
        ),
      );
    },
  );

  test(
    'bounded rounds eventually reach the final source without starvation',
    () async {
      final urls = List.generate(
        24,
        (index) => 'https://pool.example.invalid/$index.json',
      );
      final snapshot = _discovery();
      snapshot['api_pools'] = <Object>[];
      snapshot['oss_pools'] = [
        {'id': 'many', 'enabled': true, 'urls': urls},
      ];
      final first = await sign(_payload(1, discovery: snapshot));
      final next = await sign(_payload(2, discovery: snapshot));
      var active = 0;
      var maximum = 0;
      final transport = FakeTransport((request) async {
        if (!urls.contains(request.uri.toString())) connectFailure();
        active++;
        if (active > maximum) maximum = active;
        try {
          if (request.uri.toString() == urls.last) return jsonResponse(next);
          await Future<void>.delayed(const Duration(milliseconds: 15));
          connectFailure();
        } finally {
          active--;
        }
      });
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: MemoryBootstrapCache(jsonEncode({'v': 1, 'doc': first})),
        panelEndpoints: () => [],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
        stagger: Duration.zero,
        panelHead: Duration.zero,
        perSource: const Duration(milliseconds: 20),
        budget: const Duration(milliseconds: 20),
      );
      addTearDown(resolver.dispose);
      await resolver.loadCache();
      for (var round = 0; round < 8 && resolver.state.seq < 2; round++) {
        await resolver.refresh(panel: false, doh: false);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(resolver.state.seq, 2);
      expect(maximum, lessThanOrEqualTo(4));
      expect(
        transport.requests.any(
          (request) => request.uri.toString() == urls.last,
        ),
        isTrue,
      );
    },
  );

  test(
    'pending mini retrieves same-sequence full during sources-only refresh',
    () async {
      var available = false;
      final transport = FakeTransport(
        (request) => request.uri.host == 'new-api.example.invalid'
            ? jsonResponse({
                'ok': true,
                'data': available ? signedCatchup : signedInitial,
              })
            : jsonResponse(signedInitial),
      );
      final resolver = BootstrapResolver(
        brand: brand,
        transport: transport,
        cache: MemoryBootstrapCache(
          jsonEncode({'v': 1, 'doc': signedInitial, 'mini': signedMini}),
        ),
        panelEndpoints: () => ['https://new-api.example.invalid'],
        userAgent: () => 'ExampleClient/1.0',
        now: () => fromUnix(_now),
        stagger: Duration.zero,
        panelHead: Duration.zero,
      );
      addTearDown(resolver.dispose);
      await resolver.loadCache();
      expect(resolver.state.seq, 2);
      expect(resolver.lastFullSeq, 1);
      expect(resolver.needsFull, isTrue);
      await resolver.refresh(panel: false, doh: false);
      expect(resolver.state.seq, 2);
      expect(resolver.lastFullSeq, 1);
      expect(resolver.state.payload!.sources, [_remote]);
      available = true;
      await resolver.refresh(panel: false, doh: false);
      expect(resolver.state.payload!.sources, [
        'https://new-oss.example.invalid/bootstrap.json',
      ]);
      expect(resolver.state.seq, 2);
      expect(resolver.lastFullSeq, 2);
      expect(resolver.needsFull, isFalse);
    },
  );

  testWidgets(
    'runtime catches up network mini metadata once after its adopting round',
    (tester) async {
      var newApiRequests = 0;
      final runtime = XClientRuntime(
        brand: brand,
        client: const ClientInfo(
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '14',
          deviceName: 'Test',
        ),
        store: MemorySecureStore(),
        cache: MemoryBootstrapCache(jsonEncode({'v': 1, 'doc': signedInitial})),
        sink: _Sink(),
        now: () => fromUnix(_now),
        pushTransportFactory: ({pins, onPinReport}) => _Streams(),
        transportFactory: ({pins, onPinReport}) => FakeTransport((request) {
          if (request.uri.host == 'new-api.example.invalid') {
            newApiRequests++;
            return jsonResponse({'ok': true, 'data': signedCatchup});
          }
          return jsonResponse({'ok': true, 'data': signedMini});
        }),
      );
      addTearDown(runtime.dispose);
      await runtime.start();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      expect(runtime.bootstrap.state.payload!.sources, [
        'https://new-oss.example.invalid/bootstrap.json',
      ]);
      expect(newApiRequests, 1);
      await tester.pump(const Duration(seconds: 30));
      expect(newApiRequests, 1);
      runtime.dispose();
      await tester.pump(Duration.zero);
    },
  );

  testWidgets(
    'cached mini failed catchup does not spin and same-sequence hint retries full',
    (tester) async {
      var allowFull = false;
      var newApiRequests = 0;
      final runtime = XClientRuntime(
        brand: brand,
        client: const ClientInfo(
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '14',
          deviceName: 'Test',
        ),
        store: MemorySecureStore(),
        cache: MemoryBootstrapCache(
          jsonEncode({'v': 1, 'doc': signedInitial, 'mini': signedMini}),
        ),
        sink: _Sink(),
        now: () => fromUnix(_now),
        pushTransportFactory: ({pins, onPinReport}) => _Streams(),
        transportFactory: ({pins, onPinReport}) => FakeTransport((request) {
          if (request.uri.path.endsWith('/ping')) {
            return jsonResponse(
              {'data': <String, Object>{}},
              headers: {'x-xclient-seq': 'b=2;p=0'},
            );
          }
          if (request.uri.host == 'new-api.example.invalid' &&
              request.uri.path.endsWith('/bootstrap')) {
            newApiRequests++;
            if (allowFull) {
              return jsonResponse({'ok': true, 'data': signedCatchup});
            }
          }
          return jsonResponse({
            'ok': false,
            'error': 'unavailable',
          }, status: 503);
        }),
      );
      addTearDown(runtime.dispose);
      await runtime.start();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      final attempts = newApiRequests;
      expect(attempts, inInclusiveRange(1, 2));
      await tester.pump(const Duration(seconds: 30));
      expect(newApiRequests, attempts);
      allowFull = true;
      await runtime.api.call('GET', '/api/v1/xclient/ping', auth: false);
      await tester.pump(Duration.zero);
      expect(runtime.bootstrap.state.payload!.sources, [
        'https://new-oss.example.invalid/bootstrap.json',
      ]);
      runtime.dispose();
      await tester.pump(Duration.zero);
    },
  );

  testWidgets(
    'disposing runtime cancels a throttled newer-mini catchup timer',
    (tester) async {
      var serveNewMini = false;
      final runtime = XClientRuntime(
        brand: brand,
        client: const ClientInfo(
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '14',
          deviceName: 'Test',
        ),
        store: MemorySecureStore(),
        cache: MemoryBootstrapCache(
          jsonEncode({'v': 1, 'doc': signedInitial, 'mini': signedMini}),
        ),
        sink: _Sink(),
        now: () => fromUnix(_now),
        pushTransportFactory: ({pins, onPinReport}) => _Streams(),
        transportFactory: ({pins, onPinReport}) => FakeTransport((request) {
          if (serveNewMini && request.uri.host == 'new-api.example.invalid') {
            return jsonResponse({'ok': true, 'data': signedMiniHigher});
          }
          return jsonResponse({
            'ok': false,
            'error': 'unavailable',
          }, status: 503);
        }),
      );
      await runtime.start();
      await tester.pump(Duration.zero);
      await tester.pump(Duration.zero);
      serveNewMini = true;
      await runtime.bootstrap.refresh();
      await tester.pump();
      expect(runtime.bootstrap.state.seq, 3);
      expect(runtime.bootstrap.needsFull, isTrue);
      runtime.dispose();
      await tester.pump();
    },
  );

  test(
    'NoView active control applies signed pools and reconnects push only on API or pin changes',
    () async {
      var document = signedInitial;
      final requests = <TransportRequest>[];
      final streams = _Streams();
      final device = loadVectors('envelope_v1_core.json')['device'] as Map;
      final runtime = XClientRuntime(
        brand: brand,
        client: const ClientInfo(
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '14',
          deviceName: 'Test',
        ),
        store: MemorySecureStore({
          SecureKeys.auth: 'Bearer dummy',
          SecureKeys.deviceId: device['id'] as String,
          SecureKeys.deviceSk: device['sk'] as String,
        }),
        cache: MemoryBootstrapCache(jsonEncode({'v': 1, 'doc': signedInitial})),
        sink: _Sink(),
        now: () => fromUnix(_now),
        pushTransportFactory: ({pins, onPinReport}) => streams,
        transportFactory: ({pins, onPinReport}) => FakeTransport((request) {
          requests.add(request);
          if (request.uri.path.endsWith('/bootstrap')) {
            return jsonResponse({'ok': true, 'data': document});
          }
          if (request.uri.path.endsWith('/push/ticket')) {
            return jsonResponse({
              'ok': true,
              'data': {
                'ticket': 'A' * 43,
                'expires_in': 60,
                'path': '/api/v1/xclient/events',
              },
            });
          }
          if (request.uri.path.endsWith('/info')) {
            return jsonResponse({'data': <String, Object>{}});
          }
          if (request.uri.path.endsWith('/device/register')) {
            return jsonResponse({'ok': true, 'data': <String, Object>{}});
          }
          if (request.uri.path.endsWith('/state')) {
            return jsonResponse({
              'ok': true,
              'data': {'boot_seq': 1, 'policy_seq': 0},
            });
          }
          return jsonResponse({'ok': false, 'error': 'not_found'}, status: 404);
        }),
      );
      await runtime.start();
      final container = ProviderContainer(
        overrides: [
          xc.xcManagedAndroidProvider.overrideWithValue(true),
          appVisibleProvider.overrideWithBuild((_, _) => false),
          isStartProvider.overrideWithValue(true),
          xcConnectionMustStopProvider.overrideWithValue(false),
          xc.xcRuntimeProvider.overrideWith((_) async => runtime),
          xcProbeRuntimeProvider.overrideWithValue(_NoViewProbe()),
          xcUpdateManagerProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);
      mountXcLifecycle(container);
      await container.read(xc.xcRuntimeProvider.future);
      expect(container.read(appVisibleProvider), isFalse);
      expect(container.read(xc.xcControlActiveProvider), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(streams.tickets.length, 1);
      await runtime.bootstrap.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(streams.tickets.length, 1);
      document = signedChanged;
      final bootRequests = requests
          .where((r) => r.uri.path.endsWith('/bootstrap'))
          .length;
      streams.streams.last.add(
        utf8.encode('event: seq\ndata: {"boot_seq":2,"policy_seq":0}\n\n'),
      );
      await Future<void>.delayed(Duration.zero);
      await runtime.bootstrap.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(
        requests.where((r) => r.uri.path.endsWith('/bootstrap')).length,
        greaterThan(bootRequests),
      );
      expect(streams.tickets.length, 2);
      expect(streams.tickets.last.uri.host, 'new-api.example.invalid');
      document = signedPins;
      await runtime.bootstrap.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(streams.tickets.length, 3);
      await runtime.bootstrap.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(streams.tickets.length, 3);
      document = signedEmpty;
      await runtime.bootstrap.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(runtime.pool.isEmpty, isTrue);
      expect(streams.streams.last.isClosed, isTrue);
      expect(
        requests
            .where((r) => r.headers.containsKey('authorization'))
            .every((r) => r.uri.host != 'seed-api.example.invalid'),
        isTrue,
      );
      runtime.dispose();
      await Future<void>.delayed(Duration.zero);
    },
  );

  testWidgets(
    'fresh runtime verifies discovery before sending restored credentials',
    (tester) async {
      final device = loadVectors('envelope_v1_core.json')['device'] as Map;
      final credentialHosts = <String>[];
      final runtime = XClientRuntime(
        brand: brand,
        client: const ClientInfo(
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          appVersion: '1.0.0',
          build: '1',
          osVersion: '14',
          deviceName: 'Test',
        ),
        store: MemorySecureStore({
          SecureKeys.auth: 'Bearer dummy',
          SecureKeys.deviceId: device['id'] as String,
          SecureKeys.deviceSk: device['sk'] as String,
        }),
        cache: MemoryBootstrapCache(),
        sink: _Sink(),
        now: () => fromUnix(_now),
        pushTransportFactory: ({pins, onPinReport}) => _Streams(),
        transportFactory: ({pins, onPinReport}) => FakeTransport((request) {
          if (request.headers.containsKey('authorization')) {
            credentialHosts.add(request.uri.host);
          }
          if (request.uri.path.endsWith('/bootstrap')) {
            return jsonResponse({'ok': true, 'data': signedInitial});
          }
          if (request.uri.path.endsWith('/info')) {
            return jsonResponse({'data': <String, Object>{}});
          }
          if (request.uri.path.endsWith('/device/register')) {
            return jsonResponse({'ok': true, 'data': <String, Object>{}});
          }
          return jsonResponse({'ok': false, 'error': 'not_found'}, status: 404);
        }),
      );
      await runtime.start();
      await tester.pump();
      expect(credentialHosts, isNotEmpty);
      expect(
        credentialHosts.every((host) => host == 'active.example.invalid'),
        isTrue,
      );
      runtime.dispose();
      await tester.pump();
    },
  );
}
