import 'dart:convert';

import 'aead.dart';
import 'b64u.dart';
import 'crypto_exception.dart';

Map<String, String>? _obfuscatedParts(String payload) {
  try {
    final decoded = jsonDecode(b64uDecodeUtf8(payload));
    if (decoded is Map &&
        decoded.length == 2 &&
        decoded['n'] is String &&
        decoded['c'] is String) {
      return {'n': decoded['n'] as String, 'c': decoded['c'] as String};
    }
  } on FormatException {
    return null;
  }
  return null;
}

bool isObfuscatedPayload(String payload) => _obfuscatedParts(payload) != null;

/// Empty AAD; signatures cover the original base64url payload string.
Future<String> deobfuscateBootPayload(String payload, List<int>? key) async {
  final parts = _obfuscatedParts(payload);
  if (parts == null) return payload;
  if (key == null || key.length != 32) {
    throw const XcCryptoException(XcCryptoException.badKey, 'obf key');
  }
  final List<int> nonce;
  final List<int> sealed;
  try {
    nonce = b64uDecode(parts['n']!);
    sealed = b64uDecode(parts['c']!);
  } on FormatException {
    throw const XcCryptoException(XcCryptoException.badFormat, 'obf');
  }
  final clear = await xchachaOpen(key: key, nonce: nonce, sealed: sealed);
  try {
    return ascii.decode(clear);
  } on FormatException {
    throw const XcCryptoException(XcCryptoException.badFormat, 'obf text');
  }
}
