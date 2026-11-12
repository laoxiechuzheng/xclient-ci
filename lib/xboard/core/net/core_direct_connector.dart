import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../../core/direct_socket.dart';
import 'direct_socket_connector.dart';

typedef BridgeDial =
    Future<ConnectionTask<Socket>> Function(InternetAddress address, int port);

class _Opening {
  _Opening(this.epoch, this.sessionId);
  final int epoch;
  final String sessionId;
  final result = Completer<Socket>();
  DirectSocketLease? lease;
  ConnectionTask<Socket>? dial;
  Socket? raw;
  Socket? secured;
  Timer? deadline;
  bool released = false;
  bool remoteClosed = false;
}

class CoreDirectConnector implements DirectSocketConnector {
  CoreDirectConnector({
    required this.api,
    bool ready = true,
    Random? random,
    BridgeDial? dial,
    this.timeout = const Duration(seconds: 10),
  }) : _ready = ready,
       _random = random ?? Random.secure(),
       _dial = dial ?? ((address, port) => Socket.startConnect(address, port));

  final DirectSocketApi api;
  final Duration timeout;
  final Random _random;
  final BridgeDial _dial;
  final _openings = <_Opening>{};
  final _remoteClosures = <Future<void>>{};
  int _epoch = 0;
  String? _sessionId;
  bool _ready;
  bool _closed = false;
  Object? _runtimeOwner;
  Future<void>? _closeOperation;
  bool _drainFinished = false;

  @override
  int get generation => _epoch;

  String get _session => _sessionId ??= base64Url
      .encode(List.generate(32, (_) => _random.nextInt(256)))
      .replaceAll('=', '');
  bool _current(_Opening opening) =>
      !_closed && _ready && !opening.released && opening.epoch == _epoch;

  @override
  Future<ConnectionTask<Socket>> connect(
    Uri uri, {
    required SocketUpgrade secure,
  }) {
    if (_closed || !_ready) {
      return Future.error(const SocketException('DIRECT Core unavailable'));
    }
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      return Future.error(const HandshakeException('HTTPS required'));
    }
    validateDirectTarget(_session, uri.host, uri.port);
    final opening = _Opening(_epoch, _session);
    _openings.add(opening);
    unawaited(opening.result.future.then<void>((_) {}, onError: (Object _) {}));
    opening.deadline = Timer(timeout, () => _cancel(opening));
    unawaited(_open(opening, uri, secure));
    return Future.value(
      ConnectionTask.fromSocket(opening.result.future, () => _cancel(opening)),
    );
  }

  Future<void> _open(_Opening opening, Uri uri, SocketUpgrade secure) async {
    var upgrading = false;
    try {
      opening.lease = await api.openDirectSocket(
        sessionId: opening.sessionId,
        host: uri.host,
        port: uri.port,
      );
      if (!_current(opening)) {
        _release(opening);
        return;
      }
      final lease = opening.lease!;
      opening.dial = await _dial(
        InternetAddress.loopbackIPv4,
        lease.bridgePort,
      );
      if (!_current(opening)) {
        unawaited(
          opening.dial!.socket.then<void>(
            (socket) => socket.destroy(),
            onError: (Object _) {},
          ),
        );
        _release(opening);
        return;
      }
      // _release owns teardown, including sockets arriving after cancellation.
      // ignore: close_sinks
      final raw = await opening.dial!.socket;
      opening.raw = raw;
      if (!_current(opening)) {
        _release(opening);
        return;
      }
      raw.add(lease.ticket);
      await raw.flush();
      if (!_current(opening)) {
        _release(opening);
        return;
      }
      upgrading = true;
      final socket = await secure(raw);
      opening.secured = socket;
      opening.raw = null;
      if (!_current(opening)) {
        _release(opening);
        return;
      }
      opening.deadline?.cancel();
      // Upgrading completes raw.done; ownership follows only the final TLS socket.
      unawaited(
        socket.done.then<void>(
          (_) => _release(opening),
          onError: (Object _) => _release(opening),
        ),
      );
      opening.result.complete(socket);
    } catch (error, trace) {
      if (error is DirectSocketException &&
          error.failure == DirectSocketFailure.unavailable &&
          _current(opening)) {
        invalidate();
      }
      if (!opening.result.isCompleted) {
        opening.result.completeError(
          upgrading
              ? error
              : const SocketException('DIRECT bridge unavailable'),
          trace,
        );
      }
      _release(opening);
    }
  }

  void _cancel(_Opening opening) {
    if (!opening.result.isCompleted) {
      opening.result.completeError(
        const SocketException('DIRECT connection cancelled'),
      );
    }
    _release(opening);
  }

  void _release(_Opening opening) {
    if (!opening.released) {
      opening.released = true;
      opening.deadline?.cancel();
      opening.dial?.cancel();
      opening.secured?.destroy();
      opening.raw?.destroy();
      _openings.remove(opening);
    } else {
      opening.secured?.destroy();
      opening.raw?.destroy();
      opening.dial?.cancel();
    }
    final lease = opening.lease;
    if (lease != null && !opening.remoteClosed) {
      opening.remoteClosed = true;
      _trackClose(
        () => api.closeDirectSocket(
          sessionId: opening.sessionId,
          connectionId: lease.connectionId,
        ),
      );
    }
  }

  void invalidate() {
    if (_closed) return;
    final session = _sessionId;
    _epoch++;
    _sessionId = null;
    for (final opening in _openings.toList()) {
      _cancel(opening);
    }
    if (session != null) {
      _trackClose(() => api.closeDirectSession(sessionId: session));
    }
  }

  void setCoreReady(bool ready) {
    if (_closed || _ready == ready) return;
    _ready = ready;
    if (!ready) invalidate();
  }

  void Function() attachRuntime() {
    final owner = Object();
    invalidate();
    _runtimeOwner = owner;
    return () {
      if (!identical(_runtimeOwner, owner)) return;
      _runtimeOwner = null;
      invalidate();
    };
  }

  @override
  void close() {
    if (_closed) return;
    invalidate();
    _runtimeOwner = null;
    _closed = true;
    _ready = false;
  }

  void _trackClose(Future<void> Function() operation) {
    final closing = Future.sync(operation).catchError((Object _) {});
    if (_drainFinished) {
      unawaited(closing);
      return;
    }
    late final Future<void> pending;
    pending = closing.whenComplete(() {
      _remoteClosures.remove(pending);
    });
    _remoteClosures.add(pending);
  }

  Future<void> closeAndWait({Duration timeout = const Duration(seconds: 2)}) {
    close();
    return _closeOperation ??= _drain(timeout);
  }

  Future<void> _drain(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    try {
      while (_remoteClosures.isNotEmpty) {
        final remaining = deadline.difference(DateTime.now());
        if (remaining <= Duration.zero) return;
        await Future.wait(_remoteClosures.toList()).timeout(remaining);
      }
    } on TimeoutException {
      return;
    } finally {
      _drainFinished = true;
      _remoteClosures.clear();
    }
  }
}
