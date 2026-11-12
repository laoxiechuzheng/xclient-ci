import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'b64u.dart';
import 'crypto_exception.dart';

/// Domain prefixes prevent signatures from crossing document kinds.
abstract final class SignedDocKind {
  static const boot = 'xclient-boot-v1.';
  static const policy = 'xclient-policy-v1.';
  static const release = 'xclient-rel-v1.';
}

class TrustedKeys {
  final Map<String, Uint8List> _keys;

  TrustedKeys(Map<String, List<int>> keys)
    : _keys = {
        for (final MapEntry(:key, :value) in keys.entries)
          if (value.length == 32) key: Uint8List.fromList(value),
      };

  factory TrustedKeys.fromB64u(Map<String, String> keys) {
    final decoded = <String, List<int>>{};
    for (final MapEntry(:key, :value) in keys.entries) {
      try {
        decoded[key] = b64uDecode(value);
      } on FormatException {
        continue;
      }
    }
    return TrustedKeys(decoded);
  }

  static final empty = TrustedKeys(const {});

  Uint8List? operator [](String kid) => _keys[kid];

  bool get isEmpty => _keys.isEmpty;

  Iterable<String> get kids => _keys.keys;

  TrustedKeys merge(TrustedKeys other) =>
      TrustedKeys({..._keys, ...other._keys});
}

class VerifiedDoc {
  final String kid;

  final String payloadB64;
  final Map<String, dynamic> payload;

  const VerifiedDoc({
    required this.kid,
    required this.payloadB64,
    required this.payload,
  });
}

Future<bool> ed25519Verify(
  List<int> message,
  List<int> signature,
  List<int> publicKey,
) async {
  if (signature.length != 64 || publicKey.length != 32) return false;
  try {
    return await Ed25519().verify(
      message,
      signature: Signature(
        signature,
        publicKey: SimplePublicKey(publicKey, type: KeyPairType.ed25519),
      ),
    );
  } catch (_) {
    return false;
  }
}

/// [payloadOverride] supplies the original payload after deobfuscation.
Future<VerifiedDoc> verifySignedDoc(
  Map<String, dynamic> doc, {
  required String prefix,
  required TrustedKeys keys,
  String? payloadOverride,
}) async {
  final v = doc['v'];
  if (v != null && v != 1) {
    throw const XcCryptoException(XcCryptoException.badVersion);
  }
  final kid = doc['kid'];
  final payload = payloadOverride ?? doc['payload'];
  final sig = doc['sig'];
  if (kid is! String || payload is! String || sig is! String) {
    throw const XcCryptoException(XcCryptoException.badFormat, 'fields');
  }
  final key = keys[kid];
  if (key == null) {
    throw XcCryptoException(XcCryptoException.unknownKid, kid);
  }
  final Uint8List sigBytes;
  try {
    sigBytes = b64uDecode(sig);
  } on FormatException {
    throw const XcCryptoException(XcCryptoException.badFormat, 'sig');
  }
  final ok = await ed25519Verify(utf8.encode('$prefix$payload'), sigBytes, key);
  if (!ok) {
    throw const XcCryptoException(XcCryptoException.badSignature);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(b64uDecodeUtf8(payload));
  } on FormatException {
    throw const XcCryptoException(XcCryptoException.badFormat, 'payload');
  }
  if (decoded is! Map<String, dynamic>) {
    throw const XcCryptoException(XcCryptoException.badFormat, 'payload');
  }
  return VerifiedDoc(kid: kid, payloadB64: payload, payload: decoded);
}
