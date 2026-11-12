import 'dart:async';

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/plugins/app.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'connection_gate.dart';
import 'core/log.dart';
import 'probe/probe_runtime.dart';
import 'providers.dart';
import 'update/update_providers.dart';
import 'update/update_manager.dart';

ProviderSubscription<XcLifecycleBinding> mountXcLifecycle(
  ProviderContainer container,
) {
  final binding = container.read(xcLifecycleBindingProvider);
  if (binding._closed) throw StateError('Client lifecycle is closed');
  return binding._anchor ??= container.listen(
    xcLifecycleBindingProvider,
    (_, _) {},
  );
}

final xcLifecycleBindingProvider = Provider<XcLifecycleBinding>((ref) {
  ref.watch(xcProbeRuntimeProvider);
  final binding = XcLifecycleBinding(ref);
  ref.onDispose(binding.close);
  binding.start();
  return binding;
});

class XcLifecycleBinding {
  XcLifecycleBinding(this.ref);

  final Ref ref;
  final _cancel = <void Function()>[];
  ProviderSubscription<XcLifecycleBinding>? _anchor;
  bool _closed = false;
  bool _stopQueued = false;
  XClientRuntime? _lastRuntime;
  bool? _lastActive;
  bool _activityKnown = false;
  int _activityRevision = 0;
  bool _consumingUpdate = false;
  bool _consumeAgain = false;
  String? _notificationKey;
  bool _managedAndroid = false;

  void start() {
    _managedAndroid = ref.read(xcManagedAndroidProvider);
    _cancel.add(
      ref
          .listen(
            xcRuntimeProvider,
            (_, _) => _applyControl(),
            fireImmediately: true,
          )
          .close,
    );
    _cancel.add(
      ref.listen(xcControlActiveProvider, (_, _) => _applyControl()).close,
    );
    _cancel.add(
      ref
          .listen(
            xcConnectionMustStopProvider,
            (_, _) => _stopIfRequired(),
            fireImmediately: true,
          )
          .close,
    );
    _cancel.add(ref.listen(isStartProvider, (_, _) => _stopIfRequired()).close);
    _cancel.add(
      ref
          .listen(
            xcUpdateStateProvider,
            (_, _) => _notifyUpdate(),
            fireImmediately: true,
          )
          .close,
    );
    if (_managedAndroid) {
      final app = App();
      app.activityAttached.addListener(_activityChanged);
      app.updateRequests.addListener(_consumeUpdateRequest);
      _cancel.add(() => app.activityAttached.removeListener(_activityChanged));
      _cancel.add(
        () => app.updateRequests.removeListener(_consumeUpdateRequest),
      );
      _cancel.add(
        ref.listen(xcUpdateUiReadyProvider, (_, _) => _notifyUpdate()).close,
      );
      unawaited(_readActivity());
      unawaited(_consumeUpdateRequest());
    }
  }

  Future<void> _readActivity() async {
    final revision = _activityRevision;
    var attached = false;
    try {
      attached = await App().hasActivity();
    } on Object {
      attached = false;
    }
    if (_closed || !ref.mounted || revision != _activityRevision) return;
    _activityKnown = true;
    ref.read(xcAndroidActivityProvider.notifier).set(attached);
    _notifyUpdate();
  }

  void _activityChanged() {
    if (_closed || !ref.mounted) return;
    _activityRevision++;
    _activityKnown = true;
    ref
        .read(xcAndroidActivityProvider.notifier)
        .set(App().activityAttached.value);
    _notifyUpdate();
  }

  Future<void> _consumeUpdateRequest() async {
    if (_consumingUpdate) {
      _consumeAgain = true;
      return;
    }
    _consumingUpdate = true;
    try {
      do {
        _consumeAgain = false;
        final pending = await App().consumeUpdateRequest();
        if (_closed || !ref.mounted) return;
        if (pending) ref.read(xcUpdateOpenRequestedProvider.notifier).set(true);
      } while (_consumeAgain && !_closed);
    } on Object {
      return;
    } finally {
      _consumingUpdate = false;
    }
  }

  void _notifyUpdate() {
    if (_closed ||
        !ref.read(xcManagedAndroidProvider) ||
        !_activityKnown ||
        ref.read(xcClosingProvider)) {
      return;
    }
    final state = ref.read(xcUpdateStateProvider).value;
    String? kind;
    if (!ref.read(xcUpdateUiReadyProvider) && state != null) {
      kind = switch (state.phase) {
        XcUpdatePhase.needsPermission => 'permission',
        XcUpdatePhase.failed || XcUpdatePhase.manual => 'failed',
        XcUpdatePhase.awaitingUser || XcUpdatePhase.restarting => null,
        _ =>
          state.isForced ? 'required' : (state.noticeDue ? 'available' : null),
      };
    }
    final key = kind == null ? null : '${state!.decision.latest}:$kind';
    if (key == _notificationKey) return;
    _notificationKey = key;
    unawaited(notifyAndroidUpdateAction(kind));
  }

  void _applyControl() {
    if (_closed) return;
    final runtime = ref.read(xcRuntimeProvider).value;
    if (runtime == null) return;
    final active = ref.read(xcControlActiveProvider);
    if (identical(runtime, _lastRuntime) && active == _lastActive) return;
    _lastRuntime = runtime;
    _lastActive = active;
    runtime.setForeground(active);
  }

  void _stopIfRequired() {
    if (_closed ||
        _stopQueued ||
        !ref.read(xcConnectionMustStopProvider) ||
        !ref.read(isStartProvider)) {
      return;
    }
    _stopQueued = true;
    scheduleMicrotask(() async {
      try {
        if (!_closed &&
            ref.mounted &&
            ref.read(xcConnectionMustStopProvider) &&
            ref.read(isStartProvider)) {
          await ref.read(setupActionProvider.notifier).setRunning(false);
        }
      } on Object catch (error) {
        xcLog('connection stop failed: ${error.runtimeType}', warn: true);
      } finally {
        _stopQueued = false;
      }
    });
  }

  void close() {
    if (_closed) return;
    _closed = true;
    if (_managedAndroid) unawaited(notifyAndroidUpdateAction(null));
    _anchor?.close();
    _anchor = null;
    for (final cancel in _cancel) {
      cancel();
    }
    _cancel.clear();
  }
}

Future<void> shutdownXcRuntime(Ref ref) async {
  Object? failure;
  StackTrace? failureTrace;
  for (final operation in <Future<void> Function()>[
    () async {
      if (ref.exists(xcLifecycleBindingProvider)) {
        ref.read(xcLifecycleBindingProvider).close();
      }
    },
    () async {
      if (ref.exists(xcUpdateManagerProvider)) {
        ref.read(xcUpdateManagerProvider)?.dispose();
      }
    },
    () async {
      if (ref.exists(xcProbeRuntimeProvider)) {
        ref.read(xcProbeRuntimeProvider).dispose();
      }
    },
    () async {
      if (ref.exists(xcRuntimeShutdownProvider)) {
        ref.read(xcRuntimeShutdownProvider).close();
      }
    },
    () async {
      if (ref.exists(xcDirectConnectorProvider)) {
        await ref.read(xcDirectConnectorProvider)?.closeAndWait();
      }
    },
  ]) {
    try {
      await operation();
    } on Object catch (error, trace) {
      failure ??= error;
      failureTrace ??= trace;
    }
  }
  if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
}

class ManagedAndroidExitCoordinator {
  ManagedAndroidExitCoordinator({
    required this.begin,
    required this.stop,
    required this.abort,
    required this.complete,
    required this.release,
    required this.closeCore,
    required this.setClosing,
    this.onStopFailure,
    this.stopTimeout = const Duration(seconds: 30),
  });

  final Future<int?> Function() begin;
  final Future<bool> Function() stop;
  final Future<bool> Function(int generation) abort;
  final Future<bool> Function(int generation) complete;
  final Future<void> Function() release;
  final Future<void> Function() closeCore;
  final void Function(bool closing) setClosing;
  final void Function()? onStopFailure;
  final Duration stopTimeout;
  Future<void>? _running;
  bool _terminal = false;

  Future<void> exit({required Future<void> Function() cleanup}) =>
      _running ??= _exit(cleanup).whenComplete(() {
        if (!_terminal) _running = null;
      });

  Future<void> _exit(Future<void> Function() cleanup) async {
    int? generation;
    setClosing(true);
    try {
      generation = await begin();
      if (generation == null || !await stop().timeout(stopTimeout)) {
        throw StateError('VPN stop could not be confirmed');
      }
    } on Object catch (error, trace) {
      var released = generation == null;
      try {
        if (generation != null) released = await abort(generation);
      } on Object {
        released = false;
      }
      if (released) setClosing(false);
      onStopFailure?.call();
      Error.throwWithStackTrace(error, trace);
    }
    _terminal = true;
    Object? failure;
    StackTrace? failureTrace;
    for (final operation in <Future<void> Function()>[
      cleanup,
      release,
      closeCore,
      () async {
        if (!await complete(generation!)) {
          throw StateError('Engine release could not be accepted');
        }
      },
    ]) {
      try {
        await operation();
      } on Object catch (error, trace) {
        failure ??= error;
        failureTrace ??= trace;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, failureTrace!);
  }
}
