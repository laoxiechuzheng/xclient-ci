import 'dart:convert';
import 'dart:typed_data';

String b64uEncode(List<int> bytes) {
  final encoded = base64Url.encode(bytes);
  final end = encoded.indexOf('=');
  return end == -1 ? encoded : encoded.substring(0, end);
}

final _b64uAlphabet = RegExp(r'^[A-Za-z0-9_-]*$');

/// Accepts optional trailing padding for manually entered values.
Uint8List b64uDecode(String value) {
  var text = value.trim();
  while (text.endsWith('=')) {
    text = text.substring(0, text.length - 1);
  }
  if (!_b64uAlphabet.hasMatch(text) || text.length % 4 == 1) {
    throw const FormatException('not base64url');
  }
  final padded = text.padRight(text.length + (4 - text.length % 4) % 4, '=');
  return base64Url.decode(padded);
}

String b64uEncodeUtf8(String text) => b64uEncode(utf8.encode(text));

String b64uDecodeUtf8(String value) => utf8.decode(b64uDecode(value));

/// Constant-time comparison for equal-length secrets and digests.
bool bytesEqual(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}

Uint8List hexDecode(String hex) {
  final text = hex.replaceAll(RegExp(r'[\s:]'), '');
  if (text.length.isOdd) throw const FormatException('odd hex length');
  final out = Uint8List(text.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(text.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String hexEncode(List<int> bytes) {
  final buffer = StringBuffer();
  for (final byte in bytes) {
    buffer.write(byte.toRadixString(16).padLeft(2, '0'));
  }
  return buffer.toString();
}
