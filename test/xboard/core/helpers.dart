import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/xboard/core/net/transport.dart';

Map<String, dynamic> loadVectors(String name) {
  final file = File('test/xboard/vectors/$name');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

bool vectorsExist(String name) =>
    File('test/xboard/vectors/$name').existsSync();

DateTime fromUnix(int seconds) =>
    DateTime.fromMillisecondsSinceEpoch(seconds * 1000);

typedef FakeHandler =
    FutureOr<TransportResponse> Function(TransportRequest request);

/// Answers requests from a handler and records them.
class FakeTransport implements HttpTransport {
  FakeHandler handler;
  final requests = <TransportRequest>[];

  FakeTransport(this.handler);

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    requests.add(request);
    return handler(request);
  }

  @override
  void close() {}
}

TransportResponse jsonResponse(
  Object? body, {
  int status = 200,
  Map<String, String> headers = const {},
}) {
  return TransportResponse(
    statusCode: status,
    headers: {'content-type': 'application/json', ...headers},
    body: Uint8List.fromList(utf8.encode(jsonEncode(body))),
  );
}

Never connectFailure() =>
    throw const TransportException(TransportFailure.connect, beforeSend: true);

/// A [Random] that yields the given bytes first, then zeros.
class ScriptedRandom implements Random {
  final List<int> bytes;
  var _index = 0;

  ScriptedRandom(this.bytes);

  void reset() => _index = 0;

  @override
  int nextInt(int max) {
    final value = _index < bytes.length ? bytes[_index] : 0;
    _index++;
    return value % max;
  }

  @override
  bool nextBool() => nextInt(2) == 1;

  @override
  double nextDouble() => 0;
}
