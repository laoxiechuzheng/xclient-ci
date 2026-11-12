import 'dart:async';
import 'dart:math';

import '../net/api_client.dart';
import 'push_events.dart';
import 'push_ticket.dart';
import 'push_transport.dart';

class XcPushClient {
  XcPushClient({
    required this.tickets,
    required this.transport,
    required this.userAgent,
    required this.onSeq,
    int Function(int)? randomInt,
    DateTime Function()? now,
  }) : randomInt = randomInt ?? Random.secure().nextInt,
       now = now ?? DateTime.now;

  final PushTicketIssuer tickets;
  final PushTransport transport;
  final String Function() userAgent;
  final void Function(XClientSeq) onSeq;
  final int Function(int) randomInt;
  final DateTime Function() now;
  // _cancelCurrent owns cancellation on session, lifecycle and disposal changes.
  // ignore: cancel_subscriptions
  StreamSubscription<XClientSeq>? _subscription;
  PushConnection? _connection;
  Timer? _retry;
  Timer? _idle;
  Timer? _rotation;
  DateTime? _connectedAt;
  bool _started = false;
  bool _ready = false;
  bool _foreground = true;
  bool _attemptActive = false;
  bool _disposed = false;
  int _sessionGeneration = -1;
  int _epoch = 0;
  int _failures = 0;

  bool get _desired => _started && _ready && _foreground && !_disposed;
  bool _current(int epoch) => _desired && epoch == _epoch;

  void start() {
    if (_disposed || _started) return;
    _started = true;
    _begin();
  }

  void setSession({required bool ready, required int generation}) {
    if (_disposed || (_ready == ready && generation == _sessionGeneration)) {
      return;
    }
    _ready = ready;
    _sessionGeneration = generation;
    _failures = 0;
    _cancelCurrent();
    _begin();
  }

  void setForeground(bool foreground) {
    if (_disposed || _foreground == foreground) return;
    _foreground = foreground;
    _cancelCurrent();
    _begin();
  }

  void reconnect() {
    if (_disposed) return;
    _failures = 0;
    _cancelCurrent();
    _begin();
  }

  void _begin() {
    if (!_desired || _attemptActive || _retry != null) return;
    _attemptActive = true;
    final epoch = _epoch;
    unawaited(_connect(epoch));
  }

  Future<void> _connect(int epoch) async {
    try {
      final ticket = await tickets.issue();
      if (!_current(epoch)) return;
      final connection = await transport.open(ticket, userAgent: userAgent());
      if (!_current(epoch)) {
        connection.cancel();
        return;
      }
      _connection = connection;
      _connectedAt = now();
      _touch(epoch);
      _rotation = Timer(const Duration(seconds: 130), () => _finish(epoch));
      final body = connection.body.map((chunk) {
        if (_current(epoch)) _touch(epoch);
        return chunk;
      });
      _subscription = decodePushEvents(body).listen(
        (seq) {
          if (_current(epoch)) onSeq(seq);
        },
        onError: (Object _, StackTrace _) => _finish(epoch),
        onDone: () => _finish(epoch),
        cancelOnError: true,
      );
    } on Object {
      _finish(epoch);
    }
  }

  void _touch(int epoch) {
    _idle?.cancel();
    _idle = Timer(const Duration(seconds: 45), () => _finish(epoch));
  }

  void _finish(int epoch) {
    if (!_current(epoch)) return;
    final connected = _connectedAt;
    if (connected != null &&
        now().difference(connected) >= const Duration(seconds: 20)) {
      _failures = 0;
    }
    _failures++;
    _cancelCurrent();
    final base = min(60000, 1000 * (1 << min(_failures - 1, 6)));
    final delay = Duration(milliseconds: min(60000, base + randomInt(1001)));
    _retry = Timer(delay, () {
      _retry = null;
      _begin();
    });
  }

  void _cancelCurrent() {
    _epoch++;
    _retry?.cancel();
    _idle?.cancel();
    _rotation?.cancel();
    _retry = null;
    _idle = null;
    _rotation = null;
    _connectedAt = null;
    _attemptActive = false;
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      unawaited(subscription.cancel().catchError((Object _) {}));
    }
    _connection?.cancel();
    _connection = null;
    transport.close();
    tickets.cancel();
  }

  void stop() {
    _started = false;
    _cancelCurrent();
  }

  void dispose() {
    _disposed = true;
    stop();
  }
}
