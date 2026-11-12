import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/direct_socket.dart';
import 'package:fl_clash/core/desktop/model.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:fl_clash/core/method.dart';
import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/providers/app.dart';
import 'package:fl_clash/providers/core.dart';
import 'package:fl_clash/xboard/providers.dart';
import 'package:fl_clash/xboard/core/net/core_direct_connector.dart';
import 'package:fl_clash/xboard/update/update_http.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

String _encoded(int length) =>
    base64Url.encode(List.filled(length, 1)).replaceAll('=', '');

class _Core extends CoreHandlerInterface {
  final calls = <({CoreMethod method, Object? arguments, Duration? timeout})>[];
  bool fail = false;
  int lifecycleCalls = 0;
  Completer<Object?>? nextOpen;
  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) async {
    calls.add((method: method, arguments: arguments, timeout: timeout));
    if (method == CoreMethod.openDirectSocket && nextOpen != null) {
      final pending = nextOpen!;
      nextOpen = null;
      return await pending.future as T?;
    }
    if (fail) {
      throw const CoreMethodException(
        code: 'transport_error',
        message: 'fixture-sensitive-detail',
        details: 'fixture-sensitive-detail',
      );
    }
    final result = method == CoreMethod.openDirectSocket
        ? <String, Object>{
            'connectionId': _encoded(16),
            'bridgePort': 43210,
            'ticket': _encoded(32),
            'expiresInMs': 10000,
          }
        : true;
    return result as T?;
  }

  Future<CoreLifecycleResult> _lifecycle() async {
    lifecycleCalls++;
    return const CoreLifecycleResult(
      revision: 1,
      outcome: CoreLifecycleOutcome.coalesced,
    );
  }

  @override
  Future<CoreLifecycleResult> start() => _lifecycle();
  @override
  Future<CoreLifecycleResult> restart() => _lifecycle();
  @override
  Future<CoreLifecycleResult> stop() => _lifecycle();
  @override
  Future<CoreLifecycleResult> close() => _lifecycle();
}

class _LeaseSocket implements Socket {
  final finished = Completer<void>();
  bool destroyed = false;
  @override
  Future<void> get done => finished.future;
  @override
  void add(List<int> data) {}
  @override
  Future<void> flush() async {}
  @override
  void destroy() {
    destroyed = true;
    if (!finished.isCompleted) finished.complete();
  }

  @override
  Future<void> close() async => destroy();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'typed DIRECT facade uses the generic RPC with camelCase arguments',
    () async {
      final native = _Core();
      final controller = CoreController.scoped(native);
      final session = _encoded(32);
      final lease = await controller.openDirectSocket(
        sessionId: session,
        host: 'example.invalid',
        port: 8443,
      );
      await controller.closeDirectSocket(
        sessionId: session,
        connectionId: lease.connectionId,
      );
      await controller.closeDirectSession(sessionId: session);
      expect(native.calls.map((call) => call.method), [
        CoreMethod.openDirectSocket,
        CoreMethod.closeDirectSocket,
        CoreMethod.closeDirectSession,
      ]);
      expect(native.calls.first.arguments, {
        'sessionId': session,
        'host': 'example.invalid',
        'port': 8443,
      });
      expect(native.calls[1].arguments, {
        'sessionId': session,
        'connectionId': lease.connectionId,
      });
      expect(native.calls[2].arguments, {'sessionId': session});
      expect(native.calls.every((call) => call.timeout != null), isTrue);
      expect(native.lifecycleCalls, 0);
    },
  );

  test(
    'facade rejects invalid targets and does not expose RPC error detail',
    () async {
      final native = _Core();
      final controller = CoreController.scoped(native);
      await expectLater(
        controller.openDirectSocket(
          sessionId: _encoded(32),
          host: 'https://example.invalid/path',
          port: 443,
        ),
        throwsA(isA<DirectSocketException>()),
      );
      expect(native.calls, isEmpty);
      native.fail = true;
      await expectLater(
        controller.openDirectSocket(
          sessionId: _encoded(32),
          host: 'example.invalid',
          port: 443,
        ),
        throwsA(
          isA<DirectSocketException>().having(
            (error) => error.toString(),
            'safe error',
            isNot(contains('sensitive')),
          ),
        ),
      );
    },
  );

  test('safe-mode connector does not access or start native Core', () {
    final container = ProviderContainer(
      overrides: [
        safeModeProvider.overrideWithValue(true),
        coreHandlerProvider.overrideWith(
          (ref) => throw StateError('native Core accessed'),
        ),
      ],
    );
    addTearDown(container.dispose);
    expect(container.read(xcDirectConnectorProvider), isNull);
  });

  test(
    'normal connector owns no Runtime and rotates when Core status changes',
    () async {
      final native = _Core();
      final container = ProviderContainer(
        overrides: [
          coreHandlerProvider.overrideWithValue(CoreController.scoped(native)),
          safeModeProvider.overrideWithValue(false),
        ],
      );
      addTearDown(container.dispose);
      final listener = container.listen(coreStatusProvider, (_, _) {});
      addTearDown(listener.close);
      container.read(coreStatusProvider.notifier).value = CoreStatus.connected;
      final connector = container.read(xcDirectConnectorProvider)!;
      final epoch = connector.generation;
      container.read(coreStatusProvider.notifier).value = CoreStatus.connecting;
      await container.pump();
      expect(connector.generation, greaterThan(epoch));
      expect(native.lifecycleCalls, 0);
      expect(container.read(xcDirectConnectorProvider), same(connector));
    },
  );

  test(
    'Runtime provider release and late mint cannot close a newer owner',
    () async {
      final late = Completer<Object?>();
      final native = _Core()..nextOpen = late;
      final connector = CoreDirectConnector(
        api: CoreController.scoped(native),
        dial: (_, _) async =>
            ConnectionTask.fromSocket(Future.value(_LeaseSocket()), () {}),
      );
      final container = ProviderContainer(
        overrides: [xcDirectConnectorProvider.overrideWithValue(connector)],
      );
      addTearDown(container.dispose);
      addTearDown(connector.close);
      final firstRuntime = Provider((ref) => watchRuntimeDirectConnector(ref));
      final nextRuntime = Provider((ref) => watchRuntimeDirectConnector(ref));
      container.read(firstRuntime);
      final old = await connector.connect(
        Uri.parse('https://old.example.invalid'),
        secure: (_) async => _LeaseSocket(),
      );
      final refused = expectLater(old.socket, throwsA(isA<SocketException>()));
      final oldSession = (native.calls.first.arguments as Map)['sessionId'];
      container.read(nextRuntime);
      await refused;
      final current = await connector.connect(
        Uri.parse('https://new.example.invalid'),
        secure: (_) async => _LeaseSocket(),
      );
      final socket = await current.socket as _LeaseSocket;
      addTearDown(socket.close);
      final epoch = connector.generation;
      IoUpdateHttp(connector: connector).close();
      expect(connector.generation, epoch);
      container.invalidate(firstRuntime);
      await container.pump();
      expect(connector.generation, epoch);
      expect(socket.destroyed, isFalse);
      late.complete({
        'connectionId': _encoded(16),
        'bridgePort': 43210,
        'ticket': _encoded(32),
        'expiresInMs': 10000,
      });
      await container.pump();
      final lateClose =
          native.calls
                  .where((call) => call.method == CoreMethod.closeDirectSocket)
                  .single
                  .arguments
              as Map;
      expect(lateClose['sessionId'], oldSession);
      expect(socket.destroyed, isFalse);
      container.invalidate(nextRuntime);
      await container.pump();
      expect(socket.destroyed, isTrue);
      expect(native.lifecycleCalls, 0);
    },
  );
}
