import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import 'crypto_exception.dart';

const _tagLength = 16;

/// XChaCha20-Poly1305-IETF as libsodium writes it: ciphertext ‖ 16-byte tag.
Future<Uint8List> xchachaOpen({
  required List<int> key,
  required List<int> nonce,
  required List<int> sealed,
  List<int> aad = const [],
}) {
  return _open(Xchacha20.poly1305Aead(), key, nonce, sealed, aad, 24);
}

/// ChaCha20-Poly1305 of RFC 8439 (12-byte nonce), same layout.
Future<Uint8List> chachaOpen({
  required List<int> key,
  required List<int> nonce,
  required List<int> sealed,
  List<int> aad = const [],
}) {
  return _open(Chacha20.poly1305Aead(), key, nonce, sealed, aad, 12);
}

Future<Uint8List> xchachaSeal({
  required List<int> key,
  required List<int> nonce,
  required List<int> plain,
  List<int> aad = const [],
}) async {
  final box = await Xchacha20.poly1305Aead().encrypt(
    plain,
    secretKey: SecretKey(key),
    nonce: nonce,
    aad: aad,
  );
  return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
}

Future<Uint8List> _open(
  Cipher cipher,
  List<int> key,
  List<int> nonce,
  List<int> sealed,
  List<int> aad,
  int nonceLength,
) async {
  if (key.length != 32 ||
      nonce.length != nonceLength ||
      sealed.length < _tagLength) {
    throw const XcCryptoException(XcCryptoException.decrypt, 'sizes');
  }
  final split = sealed.length - _tagLength;
  try {
    final clear = await cipher.decrypt(
      SecretBox(
        sealed.sublist(0, split),
        nonce: nonce,
        mac: Mac(sealed.sublist(split)),
      ),
      secretKey: SecretKey(key),
      aad: aad,
    );
    return Uint8List.fromList(clear);
  } on SecretBoxAuthenticationError {
    throw const XcCryptoException(XcCryptoException.decrypt);
  }
}
