import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/xclient/src/brand_config.dart';
import '../../../tool/xclient/src/release_doc.dart';
import '../../../tool/xclient/xsign.dart';

List<int> _hex(String hex) => [
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
];

// RFC 8032 §7.1, TEST 1.
final _rfcSeed = _hex(
  '9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
);
final _rfcPub = _hex(
  'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
);
final _rfcSig = _hex(
  'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
);

final _seed = List<int>.generate(32, (i) => i * 7 % 256);

void main() {
  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('xsign_test_');
  });

  tearDown(() {
    temp.deleteSync(recursive: true);
  });

  group('Ed25519 usage', () {
    test(
      'a 32-byte seed yields the RFC 8032 public key and signature',
      () async {
        expect(await publicKeyOf(_rfcSeed), encodeB64u(_rfcPub));
        final signature = await Ed25519().sign(
          const [],
          keyPair: await keyPairFromSeed(_rfcSeed),
        );
        expect(signature.bytes, _rfcSig);
      },
    );

    test('parseSeed reads b64u, padded base64 and hex', () {
      expect(parseSeed(encodeB64u(_seed)), _seed);
      expect(parseSeed('${base64.encode(_seed)}\n'), _seed);
      expect(
        parseSeed(_seed.map((b) => b.toRadixString(16).padLeft(2, '0')).join()),
        _seed,
      );
      expect(() => parseSeed('abcd'), throwsA(isA<SignedDocException>()));
    });
  });

  group('signed documents', () {
    test('verify returns the payload that was signed', () async {
      final doc = await signDoc(
        type: SignedDocType.policy,
        kid: 'ctrl-1',
        seed: _seed,
        payload: {'brand': 'example', 'seq': 3},
      );
      expect(doc.keys, ['v', 'kid', 'payload', 'sig']);
      expect(doc['payload'], isNot(contains('=')));
      final payload = await verifyDoc(
        type: SignedDocType.policy,
        doc: doc,
        trustedKeys: {'ctrl-1': await publicKeyOf(_seed)},
      );
      expect(payload, {'brand': 'example', 'seq': 3});
    });

    test('the signature covers "<prefix><payload>" exactly', () async {
      final doc = await signDoc(
        type: SignedDocType.rel,
        kid: 'rel-1',
        seed: _rfcSeed,
        payload: {'a': 1},
      );
      final valid = await Ed25519().verify(
        ascii.encode('xclient-rel-v1.${doc['payload']}'),
        signature: Signature(
          decodeB64u(doc['sig']! as String),
          publicKey: SimplePublicKey(_rfcPub, type: KeyPairType.ed25519),
        ),
      );
      expect(valid, isTrue);
    });

    test('rejects another document type, a tampered payload and an unknown '
        'kid', () async {
      final pub = await publicKeyOf(_seed);
      final doc = await signDoc(
        type: SignedDocType.rel,
        kid: 'rel-1',
        seed: _seed,
        payload: {'brand': 'example'},
      );
      await expectLater(
        verifyDoc(
          type: SignedDocType.boot,
          doc: doc,
          trustedKeys: {'rel-1': pub},
        ),
        throwsA(isA<SignedDocException>()),
      );
      final tampered = {
        ...doc,
        'payload': encodeB64u(utf8.encode('{"brand":"other"}')),
      };
      await expectLater(
        verifyDoc(
          type: SignedDocType.rel,
          doc: tampered,
          trustedKeys: {'rel-1': pub},
        ),
        throwsA(isA<SignedDocException>()),
      );
      await expectLater(
        verifyDoc(
          type: SignedDocType.rel,
          doc: doc,
          trustedKeys: {'rel-2': pub},
        ),
        throwsA(isA<SignedDocException>()),
      );
    });
  });

  group('artifact naming', () {
    test('build numbers grow with the version', () {
      expect(buildNumberFor('1.0.0'), 10000999);
      expect(buildNumberFor('1.2.3'), 10203999);
      expect(buildNumberFor('1.2.3-rc.1'), 10203601);
      expect(buildNumberFor('0.9.10'), lessThan(buildNumberFor('1.0.0')));
      expect(() => buildNumberFor('1.2'), throwsFormatException);
      expect(() => buildNumberFor('1.1000.0'), throwsFormatException);
    });

    test('maps only the in-app update assets to keys', () {
      expect(assetKeyFor('98k', '1.0.0', '98k-android-arm64-v8a-v1.0.0.apk'), (
        key: 'android-arm64-v8a',
        kind: null,
      ));
      expect(assetKeyFor('98k', '1.0.0', '98k-windows-x64-setup-v1.0.0.exe'), (
        key: 'windows-x64',
        kind: null,
      ));
      expect(assetKeyFor('98k', '1.0.0', '98k-macos-universal-v1.0.0.zip'), (
        key: 'macos-universal',
        kind: 'zip',
      ));
      expect(
        assetKeyFor('98k', '1.0.0', '98k-macos-universal-v1.0.0.dmg'),
        isNull,
      );
      expect(
        assetKeyFor('98k', '1.0.0', 'mg-android-arm64-v8a-v1.0.0.apk'),
        isNull,
      );
      expect(
        assetKeyFor('98k', '1.0.0', '98k-android-arm64-v8a-v1.0.1.apk'),
        isNull,
      );
    });

    test('expands URL bases and refuses plain http', () {
      expect(
        assetUrl('https://cdn.example.com/x/{tag}/', '1.0.0', 'a b.apk'),
        'https://cdn.example.com/x/v1.0.0/a%20b.apk',
      );
      expect(
        () => assetUrl('http://cdn.example.com', '1.0.0', 'a.apk'),
        throwsFormatException,
      );
    });
  });

  group('xsign CLI', () {
    Future<(int, String, String)> run(
      List<String> args, {
      Map<String, String> environment = const {},
    }) async {
      final out = StringBuffer();
      final err = StringBuffer();
      final code = await runXsign(
        args,
        environment: environment,
        out: out,
        err: err,
        now: DateTime.utc(2026, 11, 2, 12),
      );
      return (code, out.toString(), err.toString());
    }

    void writeAsset(String name, String content) {
      File(p.join(temp.path, name)).writeAsStringSync(content);
    }

    test('sign-release writes a verifiable §7.2 document', () async {
      writeAsset('98k-android-arm64-v8a-v1.2.0.apk', 'arm64');
      writeAsset('98k-android-armeabi-v7a-v1.2.0.apk', 'arm');
      writeAsset('98k-android-x86_64-v1.2.0.apk', 'x64');
      writeAsset('98k-windows-x64-setup-v1.2.0.exe', 'setup');
      writeAsset('98k-macos-universal-v1.2.0.dmg', 'dmg');
      writeAsset('98k-macos-universal-v1.2.0.zip', 'zip');
      writeAsset('mg-android-arm64-v8a-v1.2.0.apk', 'other brand');

      final (code, out, err) = await run(
        [
          'sign-release',
          '98k',
          '1.2.0',
          temp.path,
          'https://github.com/owner/repo/releases/download/{tag}',
          'https://mirror.example.com/98k/{version}/',
        ],
        environment: {'XCLIENT_REL_SEED': encodeB64u(_seed)},
      );
      expect(code, 0, reason: err);
      expect(out, contains('98k-release-v1.2.0.json'));
      expect(out, isNot(contains(encodeB64u(_seed))));
      expect(err, isNot(contains(encodeB64u(_seed))));

      final doc =
          jsonDecode(
                File(
                  p.join(temp.path, '98k-release-v1.2.0.json'),
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      expect(doc['kid'], 'rel-1');
      final payload = await verifyDoc(
        type: SignedDocType.rel,
        doc: doc,
        trustedKeys: {'rel-1': await publicKeyOf(_seed)},
      );
      expect(payload['brand'], '98k');
      expect(payload['version'], '1.2.0');
      expect(payload['build'], 10200999);
      expect(
        payload['published_at'],
        DateTime.utc(2026, 11, 2, 12).millisecondsSinceEpoch ~/ 1000,
      );
      final assets = payload['assets']! as Map<String, Object?>;
      expect(assets.keys.toSet(), {
        'android-arm64-v8a',
        'android-armeabi-v7a',
        'android-x86_64',
        'windows-x64',
        'macos-universal',
      });
      final arm64 = assets['android-arm64-v8a']! as Map<String, Object?>;
      expect(
        arm64['sha256'],
        crypto.sha256.convert(utf8.encode('arm64')).toString(),
      );
      expect(arm64['size'], 5);
      expect(arm64['urls'], [
        'https://github.com/owner/repo/releases/download/v1.2.0/98k-android-arm64-v8a-v1.2.0.apk',
        'https://mirror.example.com/98k/1.2.0/98k-android-arm64-v8a-v1.2.0.apk',
      ]);
      expect(arm64.containsKey('kind'), isFalse);
      expect(
        (assets['macos-universal']! as Map<String, Object?>)['kind'],
        'zip',
      );

      final (verifyCode, verifyOut, _) = await run([
        'verify',
        p.join(temp.path, '98k-release-v1.2.0.json'),
        'rel-1=${await publicKeyOf(_seed)}',
      ]);
      expect(verifyCode, 0);
      expect(verifyOut, contains('"windows-x64"'));

      final (wrongCode, _, wrongErr) = await run([
        'verify',
        p.join(temp.path, '98k-release-v1.2.0.json'),
        await publicKeyOf(_rfcSeed),
      ]);
      expect(wrongCode, 1);
      expect(wrongErr, contains('verification failed'));
    });

    test('sign-release fails without a seed or without assets', () async {
      writeAsset('98k-android-arm64-v8a-v1.0.0.apk', 'x');
      final (noSeed, _, noSeedErr) = await run([
        'sign-release',
        '98k',
        '1.0.0',
        temp.path,
        'https://example.com',
      ]);
      expect(noSeed, 1);
      expect(noSeedErr, contains('XCLIENT_REL_SEED'));

      final (noAssets, _, noAssetsErr) = await run(
        ['sign-release', 'mg', '1.0.0', temp.path, 'https://example.com'],
        environment: {'XCLIENT_REL_SEED': encodeB64u(_seed)},
      );
      expect(noAssets, 1);
      expect(noAssetsErr, contains('no mg v1.0.0 update assets'));
    });

    test(
      'keygen writes a new seed file and prints only the public key',
      () async {
        final seedPath = p.join(temp.path, 'keys', 'rel-9.seed');
        final (code, out, _) = await run([
          'keygen',
          'rel-9',
          '--out',
          seedPath,
        ]);
        expect(code, 0);
        final printed = jsonDecode(out) as Map<String, Object?>;
        expect(printed['kid'], 'rel-9');
        final seedText = File(seedPath).readAsStringSync();
        expect(out, isNot(contains(seedText.trim())));
        expect(printed['pub'], await publicKeyOf(parseSeed(seedText)));
        if (!Platform.isWindows) {
          expect(File(seedPath).statSync().modeString(), 'rw-------');
        }

        final (again, _, againErr) = await run([
          'keygen',
          'rel-9',
          '--out',
          seedPath,
        ]);
        expect(again, 1);
        expect(againErr, contains('refusing to overwrite'));

        final (pubCode, pubOut, _) = await run(['pub', seedPath]);
        expect(pubCode, 0);
        expect(pubOut.trim(), printed['pub']);
      },
    );

    test('sign signs any payload with the seed from --seed-env', () async {
      final payloadFile = File(p.join(temp.path, 'boot.json'))
        ..writeAsStringSync('{"schema":1,"brand":"example","seq":7}');
      final (code, out, err) = await run(
        [
          'sign',
          'boot',
          payloadFile.path,
          '--kid',
          'ctrl-1',
          '--seed-env',
          'S',
        ],
        environment: {'S': encodeB64u(_seed)},
      );
      expect(code, 0, reason: err);
      final payload = await verifyDoc(
        type: SignedDocType.boot,
        doc: jsonDecode(out) as Map<String, Object?>,
        trustedKeys: {'ctrl-1': await publicKeyOf(_seed)},
      );
      expect(payload['seq'], 7);
    });
  });
}
