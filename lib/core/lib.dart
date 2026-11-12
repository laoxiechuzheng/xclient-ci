import 'dart:async';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/plugins/service.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'desktop/model.dart';
import 'event.dart';
import 'interface.dart';
import 'method.dart';
import 'spill.dart';

class CoreLib extends CoreHandlerInterface with ServiceListener {
  static CoreLib? _instance;

  final Service? _service;
  final bool _confirmedStops;

  Completer<bool> _connectedCompleter = Completer<bool>();
  Future<CoreLifecycleResult>? _closeOperation;
  int _lifecycleRevision = 0;
  int _methodCallId = 0;
  bool _closed = false;
  bool _serviceEventsAttached = false;

  CoreLib._internal()
    : _service = service,
      _confirmedStops = BrandConfig.isBranded {
    _attachServiceEvents();
  }

  @visibleForTesting
  CoreLib.scoped(Service this._service, {bool confirmedStops = false})
    : _confirmedStops = confirmedStops {
    _attachServiceEvents();
  }

  @visibleForTesting
  static void resetInstance() {
    _instance?._detachServiceEvents();
    _instance = null;
  }

  factory CoreLib() {
    _instance ??= CoreLib._internal();
    return _instance!;
  }

  void _attachServiceEvents() {
    if (!_confirmedStops || _service == null || _serviceEventsAttached) return;
    _service.addListener(this);
    _serviceEventsAttached = true;
  }

  void _detachServiceEvents() {
    if (!_serviceEventsAttached) return;
    _service?.removeListener(this);
    _serviceEventsAttached = false;
  }

  @override
  void onServiceEvent(CoreEvent event) {
    if (!_closed) coreEventManager.sendEvent(event);
  }

  @override
  void onServiceStopped() {
    if (_closed) return;
    unawaited(
      globalState.container
          .read(setupActionProvider.notifier)
          .setRunning(false)
          .catchError((Object error) {
            commonPrint.log('Android stop mirror failed: ${error.runtimeType}');
            return false;
          }),
    );
  }

  @override
  Future<CoreLifecycleResult> start() async {
    if (_closed) {
      throw StateError('Core lifecycle is closed');
    }
    final revision = ++_lifecycleRevision;
    if (_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    final initializationError = await _service?.init() ?? '';
    if (initializationError.isNotEmpty) {
      throw StateError(initializationError);
    }
    await globalState.container.read(vpnOptionsProvider.future);
    _connectedCompleter.complete(true);
    final syncError =
        await _service?.syncState(
          globalState.container.read(sharedStateProvider),
        ) ??
        '';
    if (syncError.isNotEmpty) {
      _connectedCompleter = Completer<bool>();
      await _service?.shutdown();
      throw StateError(syncError);
    }
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> restart() async {
    await stop();
    return start();
  }

  @override
  Future<CoreLifecycleResult> stop() => _stop();

  Future<CoreLifecycleResult> _stop({bool allowClosed = false}) async {
    if (_closed && !allowClosed) {
      throw StateError('Core lifecycle is closed');
    }
    final revision = ++_lifecycleRevision;
    if (!_connectedCompleter.isCompleted) {
      return CoreLifecycleResult(
        revision: revision,
        outcome: CoreLifecycleOutcome.coalesced,
      );
    }
    _connectedCompleter = Completer<bool>();
    final stopped = await _service?.shutdown() ?? true;
    if (!stopped) {
      throw StateError('Android Core service shutdown failed');
    }
    return CoreLifecycleResult(
      revision: revision,
      outcome: CoreLifecycleOutcome.applied,
    );
  }

  @override
  Future<CoreLifecycleResult> close() {
    return _closeOperation ??= _close();
  }

  Future<CoreLifecycleResult> _close() async {
    _closed = true;
    _detachServiceEvents();
    return _stop(allowClosed: true);
  }

  // The service opens and closes the Core's listeners itself and reports a run
  // that ends, so once it takes the command the Core's own answer is moot.
  @override
  Future<bool> startListener() async {
    await super.startListener();
    return await _service?.start() ?? false;
  }

  @override
  Future<bool> stopListener() async {
    final serviceStopped = await _service?.stop() ?? false;
    if (_confirmedStops) return serviceStopped;
    await super.stopListener();
    return serviceStopped;
  }

  @override
  Future<T?> invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
    Duration? timeout,
  }) {
    final call = _invokeMethod<T>(method: method, arguments: arguments);
    return call.withTimeout(
      timeout: timeout,
      onTimeout: () {
        unawaited(call.then(discardSpilledFile, onError: (_) {}));
        return null;
      },
    );
  }

  Future<T?> _invokeMethod<T>({
    required CoreMethod method,
    Object? arguments,
  }) async {
    try {
      await _connectedCompleter.future.timeout(coreConnectionWaitDuration);
    } catch (error) {
      commonPrint.log(
        'Invoke method ${method.name} before connection timed out: $error',
        logLevel: coreFailureLogLevel(error),
      );
      return null;
    }
    final id = '${++_methodCallId}';
    final response = await _service?.invokeMethod(
      CoreMethodCall(id: id, method: method, arguments: arguments),
    );
    if (response == null) {
      return null;
    }
    return response.unwrap<T>();
  }
}

CoreLib? get coreLib => system.isAndroid ? CoreLib() : null;
