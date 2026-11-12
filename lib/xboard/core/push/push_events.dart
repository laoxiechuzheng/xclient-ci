import 'dart:async';
import 'dart:convert';

import '../net/api_client.dart';
import 'push_connection.dart';

class _PushEventParser {
  final StringBuffer _line = StringBuffer();
  final List<String> _data = [];
  String _event = '';
  int _lineSize = 0;
  int _eventSize = 0;
  bool _skipLf = false;
  bool _first = true;

  Iterable<XClientSeq> add(String chunk) sync* {
    for (final unit in chunk.codeUnits) {
      if (_first) {
        _first = false;
        if (unit == 0xfeff) continue;
      }
      if (_skipLf) {
        _skipLf = false;
        if (unit == 10) continue;
      }
      if (unit == 10 || unit == 13) {
        _skipLf = unit == 13;
        final value = _line.toString();
        _line.clear();
        _lineSize = 0;
        final seq = _onLine(value);
        if (seq != null) yield seq;
      } else {
        _line.writeCharCode(unit);
        _lineSize++;
        if (_lineSize > 4096) throw const PushException('line_too_large');
      }
    }
  }

  XClientSeq? _onLine(String line) {
    if (line.isEmpty) {
      XClientSeq? result;
      if (_event == 'seq' && _data.isNotEmpty) {
        try {
          final data = jsonDecode(_data.join('\n'));
          if (data is Map &&
              _validSeq(data['boot_seq']) &&
              _validSeq(data['policy_seq'])) {
            result = XClientSeq(
              boot: data['boot_seq'] as int,
              policy: data['policy_seq'] as int,
            );
          }
        } on FormatException {
          result = null;
        }
      }
      _event = '';
      _data.clear();
      _eventSize = 0;
      return result;
    }
    _eventSize += line.length;
    if (_eventSize > 16384) throw const PushException('event_too_large');
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    if (field == 'event') _event = value;
    if (field == 'data') _data.add(value);
    return null;
  }

  bool _validSeq(Object? value) =>
      value is int && value >= 0 && value <= 9007199254740991;
}

Stream<XClientSeq> decodePushEvents(Stream<List<int>> bytes) {
  final parser = _PushEventParser();
  return bytes
      .transform(utf8.decoder)
      .transform(
        StreamTransformer<String, XClientSeq>.fromHandlers(
          handleData: (chunk, sink) {
            try {
              for (final event in parser.add(chunk)) {
                sink.add(event);
              }
            } on Object catch (error, stack) {
              sink.addError(error, stack);
            }
          },
        ),
      );
}
