import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/net/dns_codec.dart';
import 'package:flutter_test/flutter_test.dart';

/// A TXT answer for the query, the name compressed to the question.
Uint8List txtResponse(Uint8List query, List<List<String>> records) {
  final out = BytesBuilder()
    ..add([query[0], query[1], 0x81, 0x80, 0, 1, 0, records.length, 0, 0, 0, 0])
    ..add(query.sublist(12));
  for (final strings in records) {
    final rdata = BytesBuilder();
    for (final s in strings) {
      final bytes = utf8.encode(s);
      rdata
        ..addByte(bytes.length)
        ..add(bytes);
    }
    final data = rdata.takeBytes();
    out.add([0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0x0e, 0x10]);
    out.add([data.length >> 8, data.length & 0xff]);
    out.add(data);
  }
  return out.takeBytes();
}

void main() {
  test('query encodes RFC 1035 form', () {
    final q = encodeDnsQuery('_xc.example.com');
    expect(
      hexEncode(q),
      '0000'
      '0100'
      '0001'
      '0000'
      '0000'
      '0000'
      '035f7863'
      '076578616d706c65'
      '03636f6d'
      '00'
      '0010'
      '0001',
    );
    expect(b64uEncode(q).contains('='), isFalse);
    expect(() => encodeDnsQuery(''), throwsFormatException);
    expect(() => encodeDnsQuery('${'a' * 64}.com'), throwsFormatException);
  });

  test('TXT answers with split character-strings join', () {
    final q = encodeDnsQuery('_xc.example.com');
    final long = 'x' * 300;
    final response = txtResponse(q, [
      ['xc1:', long.substring(0, 255), long.substring(255)],
      ['v=spf1 -all'],
    ]);
    final message = decodeDnsMessage(response);
    expect(message.isResponse, isTrue);
    expect(message.rcode, 0);
    expect(message.answers.first.name, '_xc.example.com');
    expect(message.txtRecords, ['xc1:$long', 'v=spf1 -all']);
  });

  test('pointer loops and truncation are rejected', () {
    final loop = Uint8List.fromList([
      0, 0, 0x81, 0x80, 0, 0, 0, 1, 0, 0, 0, 0, //
      0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0, 1, 0, 0,
    ]);
    expect(() => decodeDnsMessage(loop), throwsFormatException);
    final q = encodeDnsQuery('a.b');
    final response = txtResponse(q, [
      ['hello'],
    ]);
    expect(
      () => decodeDnsMessage(response.sublist(0, response.length - 2)),
      throwsFormatException,
    );
  });
}
