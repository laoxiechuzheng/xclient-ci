import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'b64u.dart';
import 'crypto_exception.dart';

/// Private keys leave memory only for the secure store.
class DeviceKeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;

  const DeviceKeyPair._(this.privateKey, this.publicKey);

  static Future<DeviceKeyPair> fromPrivate(List<int> privateKey) async {
    if (privateKey.length != 32) {
      throw const XcCryptoException(XcCryptoException.badKey);
    }
    final pair = await X25519().newKeyPairFromSeed(privateKey);
    final public = await pair.extractPublicKey();
    return DeviceKeyPair._(
      Uint8List.fromList(privateKey),
      Uint8List.fromList(public.bytes),
    );
  }

  static Future<DeviceKeyPair> generate([Random? random]) {
    final rnd = random ?? Random.secure();
    return fromPrivate(List<int>.generate(32, (_) => rnd.nextInt(256)));
  }

  String get publicB64u => b64uEncode(publicKey);

  String get privateB64u => b64uEncode(privateKey);

  /// Rejects low-order points, matching libsodium's all-zero check.
  Future<Uint8List> sharedSecret(List<int> remotePublic) async {
    if (remotePublic.length != 32) {
      throw const XcCryptoException(XcCryptoException.badKey, 'epk');
    }
    final pair = await X25519().newKeyPairFromSeed(privateKey);
    final SecretKey secret;
    try {
      secret = await X25519().sharedSecretKey(
        keyPair: pair,
        remotePublicKey: SimplePublicKey(
          remotePublic,
          type: KeyPairType.x25519,
        ),
      );
    } on ArgumentError {
      throw const XcCryptoException(XcCryptoException.badKey, 'epk');
    }
    final bytes = Uint8List.fromList(await secret.extractBytes());
    if (bytes.every((b) => b == 0)) {
      throw const XcCryptoException(XcCryptoException.badKey, 'zero');
    }
    return bytes;
  }
}

Future<Uint8List> hkdfSha256({
  required List<int> ikm,
  required List<int> salt,
  required List<int> info,
  int length = 32,
}) async {
  final key = await Hkdf(
    hmac: Hmac.sha256(),
    outputLength: length,
  ).deriveKey(secretKey: SecretKey(ikm), nonce: salt, info: info);
  return Uint8List.fromList(await key.extractBytes());
}

Future<Uint8List> sha256Bytes(List<int> data) async {
  final hash = await Sha256().hash(data);
  return Uint8List.fromList(hash.bytes);
}

Uint8List randomBytes(int length, [Random? random]) {
  final rnd = random ?? Random.secure();
  return Uint8List.fromList(
    List<int>.generate(length, (_) => rnd.nextInt(256)),
  );
}

String uuidV4([Random? random]) {
  final b = randomBytes(16, random);
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final hex = hexEncode(b);
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}
