import 'dart:convert';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/crypto/aead.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/crypto/crypto_exception.dart';
import 'package:fl_clash/xboard/core/crypto/device_keys.dart';
import 'package:fl_clash/xboard/core/crypto/envelope.dart';
import 'package:fl_clash/xboard/core/crypto/obfuscation.dart';
import 'package:fl_clash/xboard/core/crypto/signed_doc.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:flutter_test/flutter_test.dart';

import 'helpers.dart';

Matcher throwsCrypto(String code) =>
    throwsA(isA<XcCryptoException>().having((e) => e.code, 'code', code));

void main() {
  final v = loadVectors('envelope_v1_core.json');
  final now = v['now'] as int;
  final keys = v['keys'] as Map<String, dynamic>;
  final envKeys = TrustedKeys.fromB64u(
    (keys['env'] as Map).cast<String, String>(),
  );
  final ctrlKeys = TrustedKeys.fromB64u(
    (keys['ctrl'] as Map).cast<String, String>(),
  );
  final relKeys = TrustedKeys.fromB64u(
    (keys['rel'] as Map).cast<String, String>(),
  );
  final device = v['device'] as Map<String, dynamic>;
  final envelope = v['envelope'] as Map<String, dynamic>;
  final reqNonce = envelope['req_nonce'] as String;

  group('standard vectors', () {
    final s = v['standard'] as Map<String, dynamic>;
    final plain = utf8.encode(s['sunscreen'] as String);
    final key = hexDecode(s['key'] as String);
    final aad = hexDecode(s['aad'] as String);

    test('RFC 8439 2.8.2 ChaCha20-Poly1305', () async {
      final r = s['rfc8439'] as Map<String, dynamic>;
      final sealed = hexDecode(r['sealed'] as String);
      expect(
        hexEncode(sealed.sublist(sealed.length - 16)),
        '1ae10b594f09e26a7e902ecbd0600691',
      );
      final clear = await chachaOpen(
        key: key,
        nonce: hexDecode(r['nonce'] as String),
        sealed: sealed,
        aad: aad,
      );
      expect(clear, plain);
    });

    test('draft-irtf-cfrg-xchacha A.3.1 XChaCha20-Poly1305', () async {
      final r = s['xchacha'] as Map<String, dynamic>;
      final nonce = hexDecode(r['nonce'] as String);
      final sealed = await xchachaSeal(
        key: key,
        nonce: nonce,
        plain: plain,
        aad: aad,
      );
      expect(hexEncode(sealed), r['sealed']);
      expect(
        hexEncode(sealed.sublist(sealed.length - 16)),
        'c0875924c1c7987947deafd8780acf49',
      );
      expect(
        await xchachaOpen(key: key, nonce: nonce, sealed: sealed, aad: aad),
        plain,
      );
      final tampered = [...sealed]..[0] ^= 1;
      expect(
        () => xchachaOpen(key: key, nonce: nonce, sealed: tampered, aad: aad),
        throwsCrypto(XcCryptoException.decrypt),
      );
    });

    test('RFC 8032 Ed25519 test 1', () async {
      final r = s['ed25519'] as Map<String, dynamic>;
      expect(
        await ed25519Verify(
          const [],
          hexDecode(r['sig'] as String),
          hexDecode(r['pk'] as String),
        ),
        isTrue,
      );
      expect(
        await ed25519Verify(
          utf8.encode('x'),
          hexDecode(r['sig'] as String),
          hexDecode(r['pk'] as String),
        ),
        isFalse,
      );
    });

    test('RFC 5869 HKDF-SHA256 case 1', () async {
      final r = s['hkdf'] as Map<String, dynamic>;
      final okm = await hkdfSha256(
        ikm: hexDecode(r['ikm'] as String),
        salt: hexDecode(r['salt'] as String),
        info: hexDecode(r['info'] as String),
        length: 42,
      );
      expect(hexEncode(okm), r['okm']);
    });

    test('RFC 7748 X25519', () async {
      final r = s['x25519'] as Map<String, dynamic>;
      final alice = await DeviceKeyPair.fromPrivate(
        hexDecode(r['alice_sk'] as String),
      );
      expect(
        hexEncode(alice.publicKey),
        '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a',
      );
      final shared = await alice.sharedSecret(hexDecode(r['bob_pk'] as String));
      expect(hexEncode(shared), r['shared']);
      expect(
        () => alice.sharedSecret(List.filled(32, 0)),
        throwsA(isA<XcCryptoException>()),
      );
    });
  });

  group('b64u', () {
    test('round trip without padding', () {
      for (var n = 0; n < 40; n++) {
        final bytes = List<int>.generate(n, (i) => (i * 37 + n) & 0xff);
        final text = b64uEncode(bytes);
        expect(text.contains('='), isFalse);
        expect(text.contains('+') || text.contains('/'), isFalse);
        expect(b64uDecode(text), bytes);
      }
    });

    test('rejects standard alphabet and junk', () {
      expect(() => b64uDecode('ab+/'), throwsFormatException);
      expect(() => b64uDecode('a'), throwsFormatException);
    });
  });

  group('envelope (PHP vectors)', () {
    late DeviceKeyPair deviceKeys;
    final deviceId = device['id'] as String;

    setUpAll(() async {
      deviceKeys = await DeviceKeyPair.fromPrivate(
        b64uDecode(device['sk'] as String),
      );
      expect(deviceKeys.publicB64u, device['pk']);
    });

    Future<EnvelopePlain> open(
      Object env, {
      String? id,
      String? nonce,
      int? at,
      TrustedKeys? trusted,
    }) => openEnvelope(
      env as Map<String, dynamic>,
      device: deviceKeys,
      deviceId: id ?? deviceId,
      reqNonce: nonce ?? reqNonce,
      envKeys: trusted ?? envKeys,
      now: at ?? now,
    );

    test('opens the 200 envelope', () async {
      final plain = await open(envelope['ok'] as Object);
      final expected = envelope['ok_plain'] as Map<String, dynamic>;
      expect(plain.status, 200);
      expect(plain.headers['profile-update-interval'], '24');
      expect(
        plain.headers['subscription-userinfo'],
        (expected['headers'] as Map)['subscription-userinfo'],
      );
      expect(utf8.decode(plain.body), b64uDecodeUtf8(expected['body_b64']));
      expect(plain.bootSeq, 7);
      expect(plain.policySeq, 3);
    });

    test('opens the blocked 403 envelope', () async {
      final plain = await open(envelope['blocked'] as Object);
      expect(plain.status, 403);
      expect(plain.body, isEmpty);
    });

    test('refuses an expired envelope', () {
      expect(
        () => open(envelope['old'] as Object),
        throwsCrypto(XcCryptoException.expired),
      );
    });

    test('refuses a signature by an untrusted key', () {
      expect(
        () => open(envelope['rogue'] as Object),
        throwsCrypto(XcCryptoException.badSignature),
      );
    });

    test('refuses an unknown kid', () {
      expect(
        () => open(envelope['ok'] as Object, trusted: TrustedKeys.empty),
        throwsCrypto(XcCryptoException.unknownKid),
      );
    });

    test('binds device id and request nonce', () {
      expect(
        () => open(envelope['ok'] as Object, nonce: 'AAAAAAAAAAAAAAAAAAAAAA'),
        throwsCrypto(XcCryptoException.binding),
      );
      expect(
        () => open(
          envelope['ok'] as Object,
          id: '00000000-0000-4000-8000-000000000000',
        ),
        throwsCrypto(XcCryptoException.binding),
      );
    });

    test('accepts within the time skew and refuses beyond it', () async {
      final h = jsonDecode(
        b64uDecodeUtf8((envelope['ok'] as Map)['h'] as String),
      );
      final exp = h['exp'] as int;
      final iat = h['iat'] as int;
      await open(envelope['ok'] as Object, at: exp + 120);
      expect(
        () => open(envelope['ok'] as Object, at: exp + 121),
        throwsCrypto(XcCryptoException.expired),
      );
      await open(envelope['ok'] as Object, at: iat - 300);
      expect(
        () => open(envelope['ok'] as Object, at: iat - 301),
        throwsCrypto(XcCryptoException.notYetValid),
      );
    });

    test('refuses a tampered ciphertext', () {
      final env = Map<String, dynamic>.of(
        envelope['ok'] as Map<String, dynamic>,
      );
      final ct = b64uDecode(env['ct'] as String);
      ct[3] ^= 0x40;
      env['ct'] = b64uEncode(ct);
      expect(() => open(env), throwsCrypto(XcCryptoException.badSignature));
    });
  });

  group('signed documents (PHP vectors)', () {
    final boot = v['bootstrap'] as Map<String, dynamic>;
    final brand = BrandConfig(
      brandId: v['brand'] as String,
      displayName: 'Demo',
      ctrlPubKeys: (keys['ctrl'] as Map).cast<String, String>(),
      obfKey: keys['obf'] as String,
    );
    final resolver = BootstrapResolver(
      brand: brand,
      transport: FakeTransport((_) => connectFailure()),
      cache: MemoryBootstrapCache(),
      panelEndpoints: () => const [],
      userAgent: () => 'test',
    );

    test('plain and obfuscated bootstrap verify to the same payload', () async {
      final plain = await resolver.verifyDocument(
        boot['plain'] as Map<String, dynamic>,
      );
      final obf = boot['obfuscated'] as Map<String, dynamic>;
      expect(isObfuscatedPayload(obf['payload'] as String), isTrue);
      final hidden = await resolver.verifyDocument(obf);
      expect(hidden.payloadB64, plain.payloadB64);
      expect(plain.payload.seq, 1730000100);
      expect(plain.payload.api.map((e) => e.url), [
        'https://api-a.example.com',
        'https://api-b.example.net',
      ]);
      expect(plain.payload.envKeys.single.kid, 'env-2');
      expect(plain.payload.isMini, isFalse);
    });

    test('backup ctrl kid verifies', () async {
      final doc = await resolver.verifyDocument(
        boot['newer_backup_kid'] as Map<String, dynamic>,
      );
      expect(doc.payload.seq, 1730000200);
    });

    test('rogue signature, other brand and wrong prefix are refused', () {
      expect(
        () => resolver.verifyDocument(boot['rogue'] as Map<String, dynamic>),
        throwsCrypto(XcCryptoException.badSignature),
      );
      expect(
        () => resolver.verifyDocument(
          boot['other_brand'] as Map<String, dynamic>,
        ),
        throwsCrypto(XcCryptoException.brand),
      );
      final policy = v['policy'] as Map<String, dynamic>;
      expect(
        () => resolver.verifyDocument(policy['doc'] as Map<String, dynamic>),
        throwsCrypto(XcCryptoException.badSignature),
      );
    });

    test('mini document from the DoH TXT value', () async {
      final txt = boot['doh_txt'] as String;
      expect(txt.startsWith('xc1:'), isTrue);
      final doc = await resolver.verifyDocument(
        jsonDecode(b64uDecodeUtf8(txt.substring(4))) as Map<String, dynamic>,
      );
      expect(doc.payload.isMini, isTrue);
      expect(doc.payload.seq, 1730000250);
    });

    test('policy verifies only as a policy', () async {
      final policy = v['policy'] as Map<String, dynamic>;
      final parsed = await verifyPolicyDoc(
        policy['doc'] as Map<String, dynamic>,
        ctrlKeys: ctrlKeys,
        brandId: 'demo',
      );
      expect(parsed.seq, 12);
      expect(parsed.latest, '1.2.0');
      expect(parsed.hasUpdate('1.1.5'), isTrue);
      expect(parsed.mustUpdate('1.1.5'), isFalse);
      expect(parsed.mustUpdate('1.0.9'), isTrue);
      expect(parsed.hasUpdate('1.2.0'), isFalse);
      expect(parsed.notice?.title, 'Hello');
      expect(
        () => verifyPolicyDoc(
          policy['as_boot'] as Map<String, dynamic>,
          ctrlKeys: ctrlKeys,
          brandId: 'demo',
        ),
        throwsCrypto(XcCryptoException.badSignature),
      );
    });

    test('release manifest', () async {
      final manifest = await verifyReleaseDoc(
        v['release'] as Map<String, dynamic>,
        relKeys: relKeys,
        brandId: 'demo',
        expectedVersion: '1.2.0',
      );
      expect(manifest.build, 120);
      expect(manifest.assets['macos-universal']?.kind, 'zip');
      expect(manifest.assets['android-arm64-v8a']?.size, 123);
      expect(
        () => verifyReleaseDoc(
          v['release'] as Map<String, dynamic>,
          relKeys: relKeys,
          brandId: 'demo',
          expectedVersion: '1.3.0',
        ),
        throwsCrypto(XcCryptoException.binding),
      );
      expect(
        () => verifyReleaseDoc(
          v['release'] as Map<String, dynamic>,
          relKeys: ctrlKeys,
          brandId: 'demo',
        ),
        throwsCrypto(XcCryptoException.unknownKid),
      );
    });

    test('obfuscation round trip', () async {
      final key = b64uDecode(keys['obf'] as String);
      final sealed = await xchachaSeal(
        key: key,
        nonce: List.filled(24, 7),
        plain: ascii.encode('abc'),
      );
      final payload = b64uEncodeUtf8(
        jsonEncode({
          'n': b64uEncode(List.filled(24, 7)),
          'c': b64uEncode(sealed),
        }),
      );
      expect(await deobfuscateBootPayload(payload, key), 'abc');
      expect(await deobfuscateBootPayload('eyJ4IjoxfQ', key), 'eyJ4IjoxfQ');
    });
  });

  group('panel plugin vectors (cross-implementation)', () {
    test('envelope_v1_plugin.json opens', () async {
      if (!vectorsExist('envelope_v1_plugin.json')) {
        markTestSkipped('plugin vectors not present');
        return;
      }
      final p = loadVectors('envelope_v1_plugin.json');
      final dev = p['device'] as Map<String, dynamic>;
      final keys = await DeviceKeyPair.fromPrivate(b64uDecode(dev['sk']));
      expect(keys.publicB64u, dev['pk']);
      final trusted = TrustedKeys.fromB64u(
        (p['trusted_env_keys'] as Map).cast<String, String>(),
      );
      for (final c in (p['cases'] as List).cast<Map<String, dynamic>>()) {
        final expected = c['expected'] as Map<String, dynamic>;
        final plain = await openEnvelope(
          c['envelope'] as Map<String, dynamic>,
          device: keys,
          deviceId: dev['device_id'] as String,
          reqNonce: p['req_nonce'] as String,
          envKeys: trusted,
          now: p['verify_at'] as int,
        );
        expect(plain.status, expected['status'], reason: c['name'] as String);
        expect(utf8.decode(plain.body), expected['body']);
        expect(
          () => openEnvelope(
            c['tampered_envelope_must_fail'] as Map<String, dynamic>,
            device: keys,
            deviceId: dev['device_id'] as String,
            reqNonce: p['req_nonce'] as String,
            envKeys: trusted,
            now: p['verify_at'] as int,
          ),
          throwsA(isA<XcCryptoException>()),
        );
      }
      final checks = p['checks'] as Map<String, dynamic>;
      final first = (p['cases'] as List).first as Map<String, dynamic>;
      Future<EnvelopePlain> at(int t) => openEnvelope(
        first['envelope'] as Map<String, dynamic>,
        device: keys,
        deviceId: dev['device_id'] as String,
        reqNonce: p['req_nonce'] as String,
        envKeys: trusted,
        now: t,
      );
      await at(checks['accept_until'] as int);
      expect(
        () => at(checks['reject_after'] as int),
        throwsCrypto(XcCryptoException.expired),
      );
      expect(
        () => at(checks['reject_if_now_before'] as int),
        throwsCrypto(XcCryptoException.notYetValid),
      );
    });

    test(
      'bootstrap_v1_plugin.json verifies, incl. obfuscated and DoH',
      () async {
        if (!vectorsExist('bootstrap_v1_plugin.json')) {
          markTestSkipped('plugin vectors not present');
          return;
        }
        final p = loadVectors('bootstrap_v1_plugin.json');
        final payload = jsonDecode(p['payload_json'] as String) as Map;
        final brand = BrandConfig(
          brandId: payload['brand'] as String,
          displayName: 'Test',
          ctrlPubKeys: (p['trusted_ctrl_keys'] as Map).cast<String, String>(),
          obfKey: p['obf_key'] as String,
        );
        final resolver = BootstrapResolver(
          brand: brand,
          transport: FakeTransport((_) => connectFailure()),
          cache: MemoryBootstrapCache(),
          panelEndpoints: () => const [],
          userAgent: () => 'test',
        );
        final plain = await resolver.verifyDocument(p['doc']);
        final obf = await resolver.verifyDocument(p['doc_obfuscated']);
        expect(obf.payloadB64, plain.payloadB64);
        expect(plain.payload.seq, payload['seq']);
        expect(plain.payload.api.length, 2);
        final mini = p['mini'] as Map<String, dynamic>;
        final miniDoc = await resolver.verifyDocument(mini['doc']);
        expect(miniDoc.payload.isMini, isTrue);
        await resolver.verifyDocument(mini['doc_obfuscated']);
        final txt = (mini['txt_chunks'] as List).join();
        expect(txt.startsWith('xc1:'), isTrue);
        await resolver.verifyDocument(
          jsonDecode(b64uDecodeUtf8(txt.substring(4))) as Map<String, dynamic>,
        );
        expect(
          () => resolver.verifyDocument(p['tampered_doc_must_fail']),
          throwsCrypto(XcCryptoException.badSignature),
        );
      },
    );

    test('policy_v1_plugin.json verifies', () async {
      if (!vectorsExist('policy_v1_plugin.json')) {
        markTestSkipped('plugin vectors not present');
        return;
      }
      final p = loadVectors('policy_v1_plugin.json');
      final trusted = TrustedKeys.fromB64u(
        (p['trusted_ctrl_keys'] as Map).cast<String, String>(),
      );
      final brandId =
          (jsonDecode(p['payload_json'] as String) as Map)['brand'] as String;
      final policy = await verifyPolicyDoc(
        p['doc'],
        ctrlKeys: trusted,
        brandId: brandId,
      );
      expect(policy.latest, '1.2.0');
      final none = await verifyPolicyDoc(
        (p['no_update'] as Map)['doc'],
        ctrlKeys: trusted,
        brandId: brandId,
      );
      expect(none.hasUpdate('1.0.0'), isFalse);
      expect(none.mustUpdate('1.0.0'), isFalse);
      expect(
        () => verifyPolicyDoc(
          p['boot_doc_must_not_verify_as_policy'],
          ctrlKeys: trusted,
          brandId: brandId,
        ),
        throwsCrypto(XcCryptoException.badSignature),
      );
    });
  });
}
