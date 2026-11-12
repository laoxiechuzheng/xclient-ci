import 'dart:convert';
import 'dart:typed_data';

import '../crypto/device_keys.dart';

class _Tlv {
  final int tag;
  final int start;
  final int contentStart;
  final int end;

  const _Tlv(this.tag, this.start, this.contentStart, this.end);
}

_Tlv _readTlv(Uint8List der, int offset) {
  if (offset + 2 > der.length) throw const FormatException('der: short');
  final tag = der[offset];
  var length = der[offset + 1];
  var cursor = offset + 2;
  if (length & 0x80 != 0) {
    final count = length & 0x7f;
    if (count == 0 || count > 4 || cursor + count > der.length) {
      throw const FormatException('der: length');
    }
    length = 0;
    for (var i = 0; i < count; i++) {
      length = (length << 8) | der[cursor + i];
    }
    cursor += count;
  }
  final end = cursor + length;
  if (end > der.length) throw const FormatException('der: overrun');
  return _Tlv(tag, offset, cursor, end);
}

/// The DER of the SubjectPublicKeyInfo of an X.509 certificate.
Uint8List extractSpki(Uint8List certificateDer) {
  final cert = _readTlv(certificateDer, 0);
  if (cert.tag != 0x30) throw const FormatException('der: certificate');
  final tbs = _readTlv(certificateDer, cert.contentStart);
  if (tbs.tag != 0x30) throw const FormatException('der: tbs');
  var cursor = tbs.contentStart;
  var field = _readTlv(certificateDer, cursor);
  // [0] EXPLICIT version is optional.
  if (field.tag == 0xa0) {
    cursor = field.end;
  }
  // serialNumber, signature, issuer, validity, subject, then the key.
  for (var i = 0; i < 5; i++) {
    field = _readTlv(certificateDer, cursor);
    cursor = field.end;
  }
  final spki = _readTlv(certificateDer, cursor);
  if (spki.tag != 0x30) throw const FormatException('der: spki');
  return Uint8List.sublistView(certificateDer, spki.start, spki.end);
}

/// base64(SHA-256(SPKI)), the pin format of DESIGN §5.3.
Future<String> spkiSha256Base64(Uint8List certificateDer) async {
  return base64.encode(await sha256Bytes(extractSpki(certificateDer)));
}

enum PinMode { off, report, enforce }

class HostPin {
  final PinMode mode;
  final Set<String> spki;

  const HostPin({required this.mode, this.spki = const {}});

  static HostPin? fromJson(Object? json) {
    if (json is! Map) return null;
    final mode = switch (json['mode']) {
      'report' => PinMode.report,
      'enforce' => PinMode.enforce,
      _ => PinMode.off,
    };
    final pins = json['spki'];
    return HostPin(
      mode: mode,
      spki: {
        if (pins is List)
          for (final pin in pins)
            if (pin is String && pin.isNotEmpty) pin,
      },
    );
  }
}

/// The `pins` map of the bootstrap, by lower-cased host.
class PinPolicy {
  final Map<String, HostPin> hosts;

  const PinPolicy([this.hosts = const {}]);

  static PinPolicy fromJson(Object? json) {
    if (json is! Map) return const PinPolicy();
    return PinPolicy({
      for (final MapEntry(:key, :value) in json.entries)
        '$key'.toLowerCase(): ?HostPin.fromJson(value),
    });
  }

  HostPin? forHost(String host) {
    final pin = hosts[host.toLowerCase()];
    return pin == null || pin.mode == PinMode.off ? null : pin;
  }

  bool get isEmpty => hosts.values.every((pin) => pin.mode == PinMode.off);
}
