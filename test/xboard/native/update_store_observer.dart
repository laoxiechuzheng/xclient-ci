import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'update_qa_contract.dart';

enum UpdateQaStoreOperation {
  initialRead,
  initialWrite,
  initialVerify,
  crossRead,
  replacementWrite,
  replacementRead,
  cleanupDelete,
  cleanupRead,
}

enum UpdateQaStoreMethod { read, write, delete }

class _StoreCall {
  _StoreCall(this.id, this.operation)
    : started = DateTime.now().millisecondsSinceEpoch;

  final int id;
  final UpdateQaStoreOperation operation;
  final int started;
  final clock = Stopwatch()..start();
  bool ended = false;
}

class UpdateQaStoreDiagnostics {
  UpdateQaStoreDiagnostics({required this.stage, required this.write}) {
    requireUpdateQa(stage == '1' || stage == '2', 'store_stage_invalid');
  }

  final String stage;
  final Future<void> Function(String name, Map<String, Object?> value) write;
  static final _callKey = Object();
  int _sequence = 0;

  Future<void> _record(
    _StoreCall call,
    String event,
    String outcome, {
    UpdateQaStoreMethod? method,
    Object? error,
  }) =>
      write('store-$stage-${call.id.toString().padLeft(2, '0')}-$event.json', {
        'stage': stage,
        'id': call.id,
        'operation': call.operation.name,
        'event': event,
        'outcome': outcome,
        'started_ms': call.started,
        'elapsed_ms': call.clock.elapsedMilliseconds,
        if (method != null) 'method': method.name,
        if (method != null) 'late': call.ended,
        if (error != null) ...updateQaStoreError(error),
      });

  Future<T> run<T>(
    UpdateQaStoreOperation operation,
    Future<T> Function() action,
  ) async {
    requireUpdateQa(_sequence < 32, 'store_operation_limit');
    final call = _StoreCall(++_sequence, operation);
    await _record(call, 'begin', 'pending');
    return runZoned(() async {
      final T value;
      try {
        value = await action();
      } catch (error, trace) {
        call.ended = true;
        try {
          await _record(
            call,
            'end',
            error is TimeoutException ? 'timeout' : 'error',
            error: error,
          );
        } finally {
          Error.throwWithStackTrace(error, trace);
        }
      }
      call.ended = true;
      await _record(call, 'end', 'success');
      return value;
    }, zoneValues: {_callKey: call});
  }

  Future<T> native<T>(
    UpdateQaStoreMethod method,
    Future<T> Function() action,
  ) async {
    final call = Zone.current[_callKey];
    requireUpdateQa(call is _StoreCall, 'owned_store_operation_required');
    final owned = call as _StoreCall;
    final T value;
    try {
      value = await action();
    } catch (error, trace) {
      try {
        await _record(
          owned,
          'nativeReturn',
          'error',
          method: method,
          error: error,
        );
      } finally {
        Error.throwWithStackTrace(error, trace);
      }
    }
    await _record(owned, 'nativeReturn', 'success', method: method);
    return value;
  }
}

Map<String, Object?> updateQaStoreError(Object error) {
  if (error is! PlatformException) {
    return {'exception_kind': updateQaExceptionKind(error).name};
  }
  final detail = error.details;
  final status = detail is int && detail >= -2147483648 && detail <= 2147483647
      ? detail
      : null;
  return {
    'exception_kind': 'platform',
    'plugin_code': switch (error.code) {
      'Unexpected security result code' => 'securityStatus',
      'Missing Parameter' => 'missingParameter',
      _ => 'unknown',
    },
    'os_status': status,
  };
}

class UpdateQaObservedStorage extends FlutterSecureStorage {
  const UpdateQaObservedStorage(this.diagnostics);

  final UpdateQaStoreDiagnostics diagnostics;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => diagnostics.native(
    UpdateQaStoreMethod.read,
    () => super.read(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => diagnostics.native(
    UpdateQaStoreMethod.write,
    () => super.write(
      key: key,
      value: value,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) => diagnostics.native(
    UpdateQaStoreMethod.delete,
    () => super.delete(
      key: key,
      iOptions: iOptions,
      aOptions: aOptions,
      lOptions: lOptions,
      webOptions: webOptions,
      mOptions: mOptions,
      wOptions: wOptions,
    ),
  );
}
