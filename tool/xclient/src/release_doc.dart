import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path/path.dart' as p;

import 'artifacts.dart';
import 'brand_config.dart';

export 'artifacts.dart';

/// Signed document kinds of docs/DESIGN.md §5.1, §7.1 and §7.2; the prefix is
/// what Ed25519 signs in front of the b64u payload.
enum SignedDocType {
  boot('xclient-boot-v1.'),
  policy('xclient-policy-v1.'),
  rel('xclient-rel-v1.');

  final String prefix;

  const SignedDocType(this.prefix);

  static SignedDocType parse(String name) {
    return SignedDocType.values.firstWhere(
      (type) => type.name == name,
      orElse: () => throw FormatException('unknown document type "$name"'),
    );
  }
}

class SignedDocException implements Exception {
  final String message;

  const SignedDocException(this.message);

  @override
  String toString() => 'SignedDocException: $message';
}

/// Builds the §7.2 payload from the artifacts of [brand]/[version] found in
/// [assetsDir].
Future<Map<String, Object?>> buildReleasePayload({
  required String brand,
  required String version,
  required String assetsDir,
  required List<String> urlBases,
  int? build,
  DateTime? publishedAt,
}) async {
  if (!isValidVersion(version)) {
    throw SignedDocException('invalid version "$version"');
  }
  if (urlBases.isEmpty) {
    throw const SignedDocException('at least one URL base is required');
  }
  final dir = Directory(assetsDir);
  if (!dir.existsSync()) {
    throw SignedDocException('$assetsDir does not exist');
  }
  final files = dir.listSync().whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final assets = <String, Object?>{};
  for (final file in files) {
    final name = p.basename(file.path);
    final asset = assetKeyFor(brand, version, name);
    if (asset == null) continue;
    final digest = await crypto.sha256.bind(file.openRead()).first;
    assets[asset.key] = {
      'urls': [for (final base in urlBases) assetUrl(base, version, name)],
      'sha256': digest.toString(),
      'size': file.lengthSync(),
      if (asset.kind != null) 'kind': asset.kind,
    };
  }
  if (assets.isEmpty) {
    throw SignedDocException(
      'no $brand v$version update assets in $assetsDir '
      '(expected e.g. ${androidApkName(brand, androidAbis.first, version)})',
    );
  }
  final published = (publishedAt ?? DateTime.now()).millisecondsSinceEpoch;
  return {
    'brand': brand,
    'version': version,
    'build': build ?? buildNumberFor(version),
    'published_at': published ~/ 1000,
    'assets': assets,
  };
}

Future<SimpleKeyPair> keyPairFromSeed(List<int> seed) {
  if (seed.length != 32) {
    throw SignedDocException('an Ed25519 seed is 32 bytes, got ${seed.length}');
  }
  return Ed25519().newKeyPairFromSeed(seed);
}

Future<String> publicKeyOf(List<int> seed) async {
  final keyPair = await keyPairFromSeed(seed);
  final publicKey = await keyPair.extractPublicKey();
  return encodeB64u(publicKey.bytes);
}

/// Signs [payload] as a `{v, kid, payload, sig}` document.
Future<Map<String, Object>> signDoc({
  required SignedDocType type,
  required String kid,
  required List<int> seed,
  required Map<String, Object?> payload,
}) async {
  final encoded = encodeB64u(utf8.encode(jsonEncode(payload)));
  final keyPair = await keyPairFromSeed(seed);
  final signature = await Ed25519().sign(
    ascii.encode('${type.prefix}$encoded'),
    keyPair: keyPair,
  );
  return {
    'v': 1,
    'kid': kid,
    'payload': encoded,
    'sig': encodeB64u(signature.bytes),
  };
}

/// Verifies [doc] against [trustedKeys] (kid -> b64u public key) and returns
/// the decoded payload.
Future<Map<String, Object?>> verifyDoc({
  required SignedDocType type,
  required Map<String, Object?> doc,
  required Map<String, String> trustedKeys,
}) async {
  if (doc['v'] != 1) throw const SignedDocException('v must be 1');
  final kid = doc['kid'];
  final payload = doc['payload'];
  final sig = doc['sig'];
  if (kid is! String || payload is! String || sig is! String) {
    throw const SignedDocException('kid, payload and sig must be strings');
  }
  final publicKey = trustedKeys[kid];
  if (publicKey == null) throw SignedDocException('untrusted kid "$kid"');
  final List<int> sigBytes;
  final List<int> keyBytes;
  try {
    sigBytes = decodeB64u(sig);
    keyBytes = decodeB64u(publicKey);
  } on FormatException catch (e) {
    throw SignedDocException('bad base64url: $e');
  }
  if (sigBytes.length != 64 || keyBytes.length != 32) {
    throw const SignedDocException('bad signature or key length');
  }
  final valid = await Ed25519().verify(
    ascii.encode('${type.prefix}$payload'),
    signature: Signature(
      sigBytes,
      publicKey: SimplePublicKey(keyBytes, type: KeyPairType.ed25519),
    ),
  );
  if (!valid) throw const SignedDocException('signature does not verify');
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(decodeB64u(payload)));
  } on FormatException catch (e) {
    throw SignedDocException('payload is not b64u JSON: $e');
  }
  if (decoded is! Map<String, Object?>) {
    throw const SignedDocException('payload must be a JSON object');
  }
  return decoded;
}

/// Reads a 32-byte seed written by `xsign keygen` (b64u, base64 or hex).
List<int> parseSeed(String text) {
  final value = text.trim();
  if (RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)) {
    return [
      for (var i = 0; i < 64; i += 2)
        int.parse(value.substring(i, i + 2), radix: 16),
    ];
  }
  final List<int> bytes;
  try {
    bytes = decodeB64u(value);
  } on FormatException {
    throw const SignedDocException('seed is neither hex nor base64');
  }
  if (bytes.length != 32) {
    throw SignedDocException('seed must be 32 bytes, got ${bytes.length}');
  }
  return bytes;
}
