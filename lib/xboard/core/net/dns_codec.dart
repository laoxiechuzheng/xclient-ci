import 'dart:convert';
import 'dart:typed_data';

const dnsTypeTxt = 16;
const dnsClassIn = 1;

/// A DNS query message for RFC 8484: id 0 (cache friendly), RD set, one
/// question.
Uint8List encodeDnsQuery(String name, {int type = dnsTypeTxt, int id = 0}) {
  final builder = BytesBuilder();
  builder.add([
    (id >> 8) & 0xff, id & 0xff, //
    0x01, 0x00, // RD
    0x00, 0x01, // QDCOUNT
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
  ]);
  var trimmed = name.trim();
  while (trimmed.endsWith('.')) {
    trimmed = trimmed.substring(0, trimmed.length - 1);
  }
  if (trimmed.isEmpty) throw const FormatException('dns: empty name');
  var total = 1;
  for (final label in trimmed.split('.')) {
    final bytes = utf8.encode(label);
    if (bytes.isEmpty || bytes.length > 63) {
      throw const FormatException('dns: bad label');
    }
    total += bytes.length + 1;
    builder
      ..addByte(bytes.length)
      ..add(bytes);
  }
  if (total > 255) throw const FormatException('dns: name too long');
  builder
    ..addByte(0)
    ..add([type >> 8, type & 0xff, dnsClassIn >> 8, dnsClassIn & 0xff]);
  return builder.takeBytes();
}

class DnsAnswer {
  final String name;
  final int type;
  final int ttl;
  final Uint8List data;

  const DnsAnswer({
    required this.name,
    required this.type,
    required this.ttl,
    required this.data,
  });

  /// The character-strings of a TXT record, each up to 255 bytes, joined.
  String get txt {
    final out = BytesBuilder();
    var i = 0;
    while (i < data.length) {
      final length = data[i];
      if (i + 1 + length > data.length) {
        throw const FormatException('dns: txt overrun');
      }
      out.add(Uint8List.sublistView(data, i + 1, i + 1 + length));
      i += 1 + length;
    }
    return utf8.decode(out.takeBytes(), allowMalformed: true);
  }
}

class DnsMessage {
  final int id;
  final int flags;
  final List<DnsAnswer> answers;

  const DnsMessage({
    required this.id,
    required this.flags,
    required this.answers,
  });

  int get rcode => flags & 0x0f;

  bool get isResponse => flags & 0x8000 != 0;

  bool get truncated => flags & 0x0200 != 0;

  /// The joined strings of every TXT answer.
  List<String> get txtRecords => [
    for (final answer in answers)
      if (answer.type == dnsTypeTxt) answer.txt,
  ];
}

class _Reader {
  final Uint8List data;
  int offset = 0;

  _Reader(this.data);

  void need(int count) {
    if (offset + count > data.length) {
      throw const FormatException('dns: short message');
    }
  }

  int u8() {
    need(1);
    return data[offset++];
  }

  int u16() {
    need(2);
    final value = (data[offset] << 8) | data[offset + 1];
    offset += 2;
    return value;
  }

  int u32() => (u16() << 16) | u16();

  /// Reads a possibly compressed name, guarding against pointer loops.
  String name() {
    final labels = <String>[];
    var cursor = offset;
    var jumped = false;
    var jumps = 0;
    while (true) {
      if (cursor >= data.length) throw const FormatException('dns: name');
      final length = data[cursor];
      if (length == 0) {
        cursor++;
        break;
      }
      if (length & 0xc0 == 0xc0) {
        if (cursor + 1 >= data.length) throw const FormatException('dns: ptr');
        final pointer = ((length & 0x3f) << 8) | data[cursor + 1];
        if (++jumps > 32 || pointer >= data.length) {
          throw const FormatException('dns: ptr loop');
        }
        if (!jumped) offset = cursor + 2;
        jumped = true;
        cursor = pointer;
        continue;
      }
      if (length & 0xc0 != 0 || cursor + 1 + length > data.length) {
        throw const FormatException('dns: label');
      }
      labels.add(
        utf8.decode(
          Uint8List.sublistView(data, cursor + 1, cursor + 1 + length),
          allowMalformed: true,
        ),
      );
      cursor += 1 + length;
    }
    if (!jumped) offset = cursor;
    return labels.join('.');
  }

  Uint8List bytes(int count) {
    need(count);
    final out = Uint8List.fromList(
      Uint8List.sublistView(data, offset, offset + count),
    );
    offset += count;
    return out;
  }
}

DnsMessage decodeDnsMessage(Uint8List message) {
  final reader = _Reader(message);
  final id = reader.u16();
  final flags = reader.u16();
  final qdCount = reader.u16();
  final anCount = reader.u16();
  reader
    ..u16()
    ..u16();
  for (var i = 0; i < qdCount; i++) {
    reader
      ..name()
      ..u16()
      ..u16();
  }
  final answers = <DnsAnswer>[];
  for (var i = 0; i < anCount; i++) {
    final name = reader.name();
    final type = reader.u16();
    reader.u16();
    final ttl = reader.u32();
    final length = reader.u16();
    answers.add(
      DnsAnswer(name: name, type: type, ttl: ttl, data: reader.bytes(length)),
    );
  }
  return DnsMessage(id: id, flags: flags, answers: answers);
}
