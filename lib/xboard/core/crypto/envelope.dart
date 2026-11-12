import 'dart:convert';
import 'dart:typed_data';

import 'aead.dart';
import 'b64u.dart';
import 'crypto_exception.dart';
import 'device_keys.dart';
import 'signed_doc.dart';

const envelopeAlg = 'X25519-HKDF-SHA256-XCHACHA20POLY1305';
const envelopeSigPrefix = 'xclient-env-v1.';
const envelopeInfoLabel = 'xclient/v1/sub';

class EnvelopeAdmission {
  const EnvelopeAdmission({
    required this.status,
    this.code = '',
    this.message = '',
    this.retryAfter = const Duration(seconds: 60),
  });
  final String status;
  final String code;
  final String message;
  final Duration retryAfter;
  bool get blocked => status == 'blocked';

  static EnvelopeAdmission? fromJson(Object? value) {
    if (value == null) return null;
    if (value is! Map ||
        value['status'] != 'blocked' && value['status'] != 'allowed') {
      throw const FormatException('admission');
    }
    final seconds = _asInt(value['retry_after']);
    return EnvelopeAdmission(
      status: value['status'] as String,
      code: value['code'] is String ? value['code'] as String : '',
      message: value['message'] is String
          ? (value['message'] as String).trim()
          : '',
      retryAfter: Duration(
        seconds: seconds != null && seconds > 0 ? seconds.clamp(1, 86400) : 60,
      ),
    );
  }
}

/// The plaintext `P` of DESIGN §4.1.
class EnvelopePlain {
  final int status;

  /// Lower-cased header names.
  final Map<String, String> headers;
  final Uint8List body;
  final Map<String, dynamic> header;
  final EnvelopeAdmission? admission;

  const EnvelopePlain({
    required this.status,
    required this.headers,
    required this.body,
    required this.header,
    this.admission,
  });

  int? get bootSeq => _asInt(header['boot_seq']);

  int? get policySeq => _asInt(header['policy_seq']);
}

int? _asInt(Object? value) => switch (value) {
  final int v => v,
  final num v when v.isFinite => v.toInt(),
  final String v => int.tryParse(v),
  _ => null,
};

/// Opens `{h, ct, sig}` per DESIGN §4.1, in the order the contract gives:
/// kid → signature → binding and time → decryption.
Future<EnvelopePlain> openEnvelope(
  Map<String, dynamic> envelope, {
  required DeviceKeyPair device,
  required String deviceId,
  required String reqNonce,
  required TrustedKeys envKeys,
  required int now,
}) async {
  final h = envelope['h'];
  final ct = envelope['ct'];
  final sig = envelope['sig'];
  if (h is! String || ct is! String || sig is! String) {
    throw const XcCryptoException(XcCryptoException.badFormat, 'envelope');
  }
  final Map<String, dynamic> header;
  final Uint8List sigBytes;
  final Uint8List sealed;
  try {
    final decoded = jsonDecode(b64uDecodeUtf8(h));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    header = decoded;
    sigBytes = b64uDecode(sig);
    sealed = b64uDecode(ct);
  } on FormatException {
    throw const XcCryptoException(XcCryptoException.badFormat, 'header');
  }
  final kid = header['kid'];
  final key = kid is String ? envKeys[kid] : null;
  if (key == null) {
    throw XcCryptoException(XcCryptoException.unknownKid, '$kid');
  }
  final signed = utf8.encode('$envelopeSigPrefix$h.$ct');
  if (!await ed25519Verify(signed, sigBytes, key)) {
    throw const XcCryptoException(XcCryptoException.badSignature);
  }
  if (header['v'] != 1 || header['alg'] != envelopeAlg) {
    throw const XcCryptoException(XcCryptoException.badVersion);
  }
  if (header['device_id'] != deviceId || header['req_nonce'] != reqNonce) {
    throw const XcCryptoException(XcCryptoException.binding);
  }
  final exp = _asInt(header['exp']);
  final iat = _asInt(header['iat']);
  if (exp == null || iat == null) {
    throw const XcCryptoException(XcCryptoException.badFormat, 'iat/exp');
  }
  if (now > exp + 120) {
    throw const XcCryptoException(XcCryptoException.expired);
  }
  if (iat > now + 300) {
    throw const XcCryptoException(XcCryptoException.notYetValid);
  }
  final Uint8List epk;
  final Uint8List salt;
  final Uint8List nonce;
  try {
    epk = b64uDecode(header['epk'] as String);
    salt = b64uDecode(header['salt'] as String);
    nonce = b64uDecode(header['nonce'] as String);
  } on Object {
    throw const XcCryptoException(XcCryptoException.badFormat, 'epk/salt');
  }
  final shared = await device.sharedSecret(epk);
  final info = <int>[
    ...utf8.encode(envelopeInfoLabel),
    0,
    ...epk,
    ...device.publicKey,
    ...utf8.encode(deviceId),
  ];
  final key32 = await hkdfSha256(ikm: shared, salt: salt, info: info);
  final clear = await xchachaOpen(
    key: key32,
    nonce: nonce,
    sealed: sealed,
    aad: ascii.encode(h),
  );
  return _parsePlain(clear, header);
}

EnvelopePlain _parsePlain(Uint8List clear, Map<String, dynamic> header) {
  try {
    final decoded = jsonDecode(utf8.decode(clear));
    if (decoded is! Map<String, dynamic>) throw const FormatException();
    final admission = EnvelopeAdmission.fromJson(decoded['admission']);
    final status =
        _asInt(decoded['status']) ?? (admission?.blocked == true ? 403 : null);
    if (status == null) throw const FormatException();
    final rawHeaders = decoded['headers'];
    final headers = <String, String>{};
    if (rawHeaders is Map) {
      for (final MapEntry(:key, :value) in rawHeaders.entries) {
        if (value == null) continue;
        headers['$key'.toLowerCase()] = '$value';
      }
    }
    final body = decoded['body_b64'];
    return EnvelopePlain(
      status: status,
      headers: headers,
      body: admission?.blocked == true || status == 403
          ? Uint8List(0)
          : body is String && body.isNotEmpty
          ? b64uDecode(body)
          : Uint8List(0),
      header: header,
      admission: admission,
    );
  } on FormatException {
    throw const XcCryptoException(XcCryptoException.badFormat, 'plaintext');
  }
}
