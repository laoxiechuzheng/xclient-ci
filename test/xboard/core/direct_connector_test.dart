import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:fl_clash/core/direct_socket.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/xboard/core/net/core_direct_connector.dart';
import 'package:flutter_test/flutter_test.dart';

String _encoded(int bytes, int value) =>
    base64Url.encode(List.filled(bytes, value)).replaceAll('=', '');

Map<String, Object> _reply([int value = 1]) => {
  'connectionId': _encoded(16, value),
  'bridgePort': 43210,
  'ticket': _encoded(32, value),
  'expiresInMs': 10000,
};

class _Api implements DirectSocketApi {
  final opened = <({String session, String host, int port})>[];
  final closed = <({String session, String id})>[];
  final sessions = <String>[];
  Future<DirectSocketLease>? next;
  Future<void>? closeGate;
  @override
  Future<DirectSocketLease> openDirectSocket({
    required String sessionId,
    required String host,
    required int port,
  }) async {
    opened.add((session: sessionId, host: host, port: port));
    final reply = next;
    next = null;
    return reply ?? DirectSocketLease.parse(_reply(opened.length));
  }

  @override
  Future<void> closeDirectSocket({
    required String sessionId,
    required String connectionId,
  }) async {
    closed.add((session: sessionId, id: connectionId));
    await closeGate;
  }

  @override
  Future<void> closeDirectSession({required String sessionId}) async {
    sessions.add(sessionId);
    await closeGate;
  }
}

class _Socket extends Stream<Uint8List> implements Socket {
  final closed = Completer<void>();
  final bytes = <int>[];
  bool destroyed = false;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<void> flush() async {}
  @override
  Future<void> get done => closed.future;
  @override
  void destroy() {
    destroyed = true;
    if (!closed.isCompleted) closed.complete();
  }

  @override
  Future<void> close() async => destroy();

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<Uint8List>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'awaited close drains owned remote releases before Core terminal close',
    () async {
      final gate = Completer<void>();
      final api = _Api()..closeGate = gate.future;
      final connector = CoreDirectConnector(
        api: api,
        dial: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(_Socket()), () {}),
      );
      final task = await connector.connect(
        Uri.parse('https://example.invalid'),
        secure: (_) async => _Socket(),
      );
      final socket = await task.socket as _Socket;
      addTearDown(socket.close);
      var finished = false;
      final closing = connector.closeAndWait();
      unawaited(closing.then((_) => finished = true));
      await Future<void>.delayed(Duration.zero);
      expect(socket.destroyed, isTrue);
      expect(api.sessions, hasLength(1));
      expect(finished, isFalse);
      gate.complete();
      await closing;
      expect(finished, isTrue);
    },
  );

  test(
    'late mint after awaited shutdown still releases its remote lease',
    () async {
      final mint = Completer<DirectSocketLease>();
      final api = _Api()..next = mint.future;
      final connector = CoreDirectConnector(
        api: api,
        dial: (_, _) async => throw StateError('cancelled mint must not dial'),
      );
      final task = await connector.connect(
        Uri.parse('https://example.invalid'),
        secure: (_) async =>
            throw StateError('cancelled mint must not upgrade'),
      );
      final cancelled = expectLater(
        task.socket,
        throwsA(isA<SocketException>()),
      );
      await connector.closeAndWait();
      await cancelled;
      expect(api.sessions, hasLength(1));
      expect(api.closed, isEmpty);
      final lease = DirectSocketLease.parse(_reply());
      mint.complete(lease);
      await Future<void>.delayed(Duration.zero);
      expect(api.closed, hasLength(1));
      expect(api.closed.single.id, lease.connectionId);
      expect(api.closed.single.session, api.opened.single.session);
    },
  );

  test(
    'awaited close is bounded when native stop already removed the broker',
    () async {
      final gate = Completer<void>();
      final api = _Api()..closeGate = gate.future;
      final connector = CoreDirectConnector(
        api: api,
        dial: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(_Socket()), () {}),
      );
      final task = await connector.connect(
        Uri.parse('https://example.invalid'),
        secure: (_) async => _Socket(),
      );
      final socket = await task.socket;
      addTearDown(socket.close);
      await connector.closeAndWait(timeout: const Duration(milliseconds: 5));
      expect(api.sessions, hasLength(1));
      gate.complete();
    },
  );
  test('Core exposes the isolated DIRECT socket RPC contract', () {
    expect(
      CoreMethod.values.map((method) => method.name),
      containsAll([
        'openDirectSocket',
        'closeDirectSocket',
        'closeDirectSession',
      ]),
    );
  });

  test('DIRECT replies require canonical bounded camelCase fields', () {
    final valid = DirectSocketLease.parse(_reply());
    expect(valid.ticket, List.filled(32, 1));
    expect(valid.bridgePort, 43210);
    final invalid = [
      null,
      {
        'connection_id': _encoded(16, 1),
        'bridge_port': 43210,
        'ticket': _encoded(32, 1),
        'expiresInMs': 10000,
      },
      {..._reply(), 'bridgePort': 1.0},
      {..._reply(), 'bridgePort': 0},
      {..._reply(), 'bridgePort': 65536},
      {..._reply(), 'connectionId': 'x'},
      {..._reply(), 'ticket': 'B' * 43},
      {..._reply(), 'ticket': '${_encoded(32, 1)}='},
      {..._reply(), 'expiresInMs': 10001},
      {..._reply(), 'expiresInMs': 1.5},
    ];
    for (final reply in invalid) {
      expect(
        () => DirectSocketLease.parse(reply),
        throwsA(isA<DirectSocketException>()),
      );
    }
  });

  test(
    'DIRECT request validation rejects addresses with routing or credential syntax',
    () {
      final session = _encoded(32, 1);
      for (final host in [
        'http://example.invalid',
        'name:password@example.invalid',
        'example.invalid:443',
        'bad/name',
        'bad host',
        'bad..invalid',
      ]) {
        expect(
          () => validateDirectTarget(session, host, 443),
          throwsA(isA<DirectSocketException>()),
        );
      }
      validateDirectTarget(session, 'example.invalid', 443);
      validateDirectTarget(session, '::1', 443);
      expect(isDirectSessionId('B' * 43), isFalse);
    },
  );

  testWidgets('cancellation is available before a delayed mint returns', (
    tester,
  ) async {
    final pending = Completer<DirectSocketLease>();
    final api = _Api()..next = pending.future;
    var dialled = 0;
    final connector = CoreDirectConnector(
      api: api,
      dial: (_, _) async {
        dialled++;
        throw StateError('unexpected dial');
      },
    );
    final task = await connector.connect(
      Uri.parse('https://example.invalid/path'),
      secure: (_) async => throw StateError('unexpected TLS'),
    );
    final refused = expectLater(task.socket, throwsA(isA<SocketException>()));
    task.cancel();
    await refused;
    pending.complete(DirectSocketLease.parse(_reply()));
    await tester.pump();
    expect(dialled, 0);
    expect(api.closed.single.id, _encoded(16, 1));
    connector.close();
    await tester.pump();
  });

  testWidgets(
    'a late local socket and late local task are both destroyed after cancellation',
    (tester) async {
      for (final lateTask in [false, true]) {
        final api = _Api();
        final raw = _Socket();
        addTearDown(raw.close);
        final socket = Completer<Socket>();
        final local = Completer<ConnectionTask<Socket>>();
        var tls = 0;
        final connector = CoreDirectConnector(
          api: api,
          dial: (_, _) => lateTask
              ? local.future
              : Future.value(ConnectionTask.fromSocket(socket.future, () {})),
        );
        final task = await connector.connect(
          Uri.parse('https://example.invalid'),
          secure: (_) async {
            tls++;
            return _Socket();
          },
        );
        await tester.pump();
        final refused = expectLater(
          task.socket,
          throwsA(isA<SocketException>()),
        );
        task.cancel();
        await refused;
        if (lateTask) {
          local.complete(ConnectionTask.fromSocket(Future.value(raw), () {}));
        } else {
          socket.complete(raw);
        }
        await tester.pump();
        expect(raw.destroyed, isTrue);
        expect(tls, 0);
        expect(api.closed, hasLength(1));
        connector.close();
      }
      await tester.pump();
    },
  );

  testWidgets(
    'raw ticket has no ACK and upgrading raw.done does not close final TLS',
    (tester) async {
      final api = _Api();
      final raw = _Socket();
      addTearDown(raw.close);
      final tls = _Socket();
      addTearDown(tls.close);
      final connector = CoreDirectConnector(
        api: api,
        dial: (address, port) async {
          expect(address, InternetAddress.loopbackIPv4);
          expect(port, 43210);
          return ConnectionTask.fromSocket(Future.value(raw), () {});
        },
      );
      final task = await connector.connect(
        Uri.parse('https://original.example.invalid:8443'),
        secure: (socket) async {
          expect(socket, same(raw));
          expect(raw.bytes, List.filled(32, 1));
          raw.closed.complete();
          return tls;
        },
      );
      expect(await task.socket, same(tls));
      await tester.pump();
      expect(tls.destroyed, isFalse);
      expect(api.closed, isEmpty);
      expect(api.opened.single.host, 'original.example.invalid');
      expect(api.opened.single.port, 8443);
      tls.closed.complete();
      await tester.pump();
      expect(api.closed, hasLength(1));
      connector.close();
      await tester.pump();
    },
  );

  testWidgets('a late TLS result is destroyed after cancellation', (
    tester,
  ) async {
    final api = _Api();
    final raw = _Socket();
    addTearDown(raw.close);
    final tls = _Socket();
    addTearDown(tls.close);
    final handshake = Completer<Socket>();
    final connector = CoreDirectConnector(
      api: api,
      dial: (_, _) async => ConnectionTask.fromSocket(Future.value(raw), () {}),
    );
    final task = await connector.connect(
      Uri.parse('https://example.invalid'),
      secure: (_) => handshake.future,
    );
    await tester.pump();
    final refused = expectLater(task.socket, throwsA(isA<SocketException>()));
    task.cancel();
    await refused;
    handshake.complete(tls);
    await tester.pump();
    expect(raw.destroyed, isTrue);
    expect(tls.destroyed, isTrue);
    expect(api.closed, hasLength(1));
    connector.close();
    await tester.pump();
  });

  testWidgets(
    'generation changes rotate sessions and cannot cancel a newer owner',
    (tester) async {
      final pending = Completer<DirectSocketLease>();
      final api = _Api()..next = pending.future;
      final connector = CoreDirectConnector(
        api: api,
        random: Random(7),
        dial: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(_Socket()), () {}),
      );
      final old = await connector.connect(
        Uri.parse('https://example.invalid'),
        secure: (_) async => _Socket(),
      );
      final refused = expectLater(old.socket, throwsA(isA<SocketException>()));
      connector.setCoreReady(false);
      await refused;
      final oldSession = api.opened.first.session;
      await expectLater(
        connector.connect(
          Uri.parse('https://example.invalid'),
          secure: (_) async => _Socket(),
        ),
        throwsA(isA<SocketException>()),
      );
      connector.setCoreReady(true);
      final current = await connector.connect(
        Uri.parse('https://example.invalid'),
        secure: (_) async => _Socket(),
      );
      final socket = await current.socket as _Socket;
      addTearDown(socket.close);
      pending.complete(DirectSocketLease.parse(_reply(1)));
      await tester.pump();
      expect(api.opened.last.session, isNot(oldSession));
      expect(api.closed.single.session, oldSession);
      expect(socket.destroyed, isFalse);
      connector.close();
      await tester.pump();
      expect(socket.destroyed, isTrue);
      expect(api.sessions.toSet(), hasLength(2));
    },
  );

  testWidgets(
    'one cancellation leaves sibling pipes alive and close affects only this owner',
    (tester) async {
      final api = _Api();
      final connector = CoreDirectConnector(
        api: api,
        dial: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(_Socket()), () {}),
      );
      final first = await connector.connect(
        Uri.parse('https://one.example.invalid'),
        secure: (_) async => _Socket(),
      );
      final firstSocket = await first.socket as _Socket;
      addTearDown(firstSocket.close);
      final second = await connector.connect(
        Uri.parse('https://two.example.invalid'),
        secure: (_) async => _Socket(),
      );
      final secondSocket = await second.socket as _Socket;
      addTearDown(secondSocket.close);
      first.cancel();
      await tester.pump();
      expect(firstSocket.destroyed, isTrue);
      expect(secondSocket.destroyed, isFalse);
      expect(api.sessions, isEmpty);
      connector.close();
      connector.close();
      await tester.pump();
      expect(secondSocket.destroyed, isTrue);
      expect(api.sessions, hasLength(1));
      await expectLater(
        connector.connect(
          Uri.parse('https://one.example.invalid'),
          secure: (_) async => _Socket(),
        ),
        throwsA(isA<SocketException>()),
      );
    },
  );

  testWidgets('cancelled mint failure cannot retire a healthy sibling', (
    tester,
  ) async {
    final late = Completer<DirectSocketLease>();
    final api = _Api()..next = late.future;
    final connector = CoreDirectConnector(
      api: api,
      dial: (_, _) async =>
          ConnectionTask.fromSocket(Future.value(_Socket()), () {}),
    );
    final old = await connector.connect(
      Uri.parse('https://old.example.invalid'),
      secure: (_) async => _Socket(),
    );
    final refused = expectLater(old.socket, throwsA(isA<SocketException>()));
    old.cancel();
    await refused;
    final current = await connector.connect(
      Uri.parse('https://new.example.invalid'),
      secure: (_) async => _Socket(),
    );
    final socket = await current.socket as _Socket;
    addTearDown(socket.close);
    final epoch = connector.generation;
    late.completeError(
      const DirectSocketException(DirectSocketFailure.unavailable),
    );
    await tester.pump();
    expect(connector.generation, epoch);
    expect(socket.destroyed, isFalse);
    expect(api.sessions, isEmpty);
    connector.close();
    await tester.pump();
  });

  testWidgets('a mint timeout remains cancelled when its RPC finally returns', (
    tester,
  ) async {
    final pending = Completer<DirectSocketLease>();
    final api = _Api()..next = pending.future;
    final connector = CoreDirectConnector(
      api: api,
      timeout: const Duration(milliseconds: 20),
      dial: (_, _) async => throw StateError('unexpected dial'),
    );
    final task = await connector.connect(
      Uri.parse('https://example.invalid'),
      secure: (_) async => _Socket(),
    );
    final refused = expectLater(task.socket, throwsA(isA<SocketException>()));
    await tester.pump(const Duration(milliseconds: 20));
    await refused;
    pending.complete(DirectSocketLease.parse(_reply()));
    await tester.pump();
    expect(api.closed, hasLength(1));
    connector.close();
    await tester.pump();
  });
}
