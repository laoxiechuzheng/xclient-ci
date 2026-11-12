import 'dart:async';
import 'dart:convert';

import '../auth/session.dart';
import '../crypto/crypto_exception.dart';
import '../crypto/signed_doc.dart';
import '../log.dart';
import '../net/api_client.dart';
import '../net/api_exception.dart';
import 'policy_cache.dart';
import 'update_docs.dart';

enum PolicyCheckPhase { unknown, checking, error, verified }

class RemoteState {
  final int? bootSeq;
  final int? policySeq;
  final XcPolicy? policy;
  final XcNotice? notice;
  final DateTime? checkedAt;
  final PolicyCheckPhase phase;
  final int requiredPolicySeq;

  const RemoteState({
    this.bootSeq,
    this.policySeq,
    this.policy,
    this.notice,
    this.checkedAt,
    this.phase = PolicyCheckPhase.unknown,
    this.requiredPolicySeq = -1,
  });

  bool get canConnect => phase == PolicyCheckPhase.verified;
  XcNotice? get effectiveNotice => policy?.notice ?? notice;
  String? get connectionMessage => switch (phase) {
    PolicyCheckPhase.verified => null,
    PolicyCheckPhase.unknown => '正在等待安全核验客户端版本',
    PolicyCheckPhase.checking => '正在安全核验客户端版本，请稍候',
    PolicyCheckPhase.error => '客户端版本策略核验失败，请重试；账号和购买仍可使用',
  };
}

class StatePoller {
  final ApiClient api;
  final Session session;
  final TrustedKeys Function() ctrlKeys;
  final String brandId;
  final PolicyCache cache;
  final DateTime Function() _now;

  Duration foreground;
  Duration background;
  RemoteState _state = const RemoteState();
  final _changes = StreamController<RemoteState>.broadcast();
  PolicyDocument? _document;
  int _floor = -1;
  int _required = -1;
  int? _verifiedGeneration;
  Future<void>? _loading;
  Future<void> _cacheTail = Future.value();
  String? _etag;
  Timer? _timer;
  Timer? _expiryTimer;
  bool _active = false;
  bool _disposed = false;
  bool _inForeground = true;
  Future<void>? _running;
  int? _runningGeneration;

  StatePoller({
    required this.api,
    required this.session,
    required this.ctrlKeys,
    required this.brandId,
    PolicyCache? cache,
    this.foreground = const Duration(seconds: 60),
    this.background = const Duration(seconds: 900),
    DateTime Function()? now,
  }) : cache = cache ?? MemoryPolicyCache(),
       _now = now ?? DateTime.now {
    session.addLogoutHook(_onLogout);
  }

  RemoteState get state {
    if (_state.canConnect &&
        (_verifiedGeneration != session.generation ||
            !session.state.isLoggedIn ||
            _document?.expired(_now()) == true)) {
      return _copy(phase: PolicyCheckPhase.unknown);
    }
    return _state;
  }

  Stream<RemoteState> get changes => _changes.stream;
  Duration get _period => _inForeground ? foreground : background;
  bool _current(int generation) =>
      !_disposed &&
      session.state.isLoggedIn &&
      session.generation == generation;

  void _set(RemoteState next) {
    if (_disposed) return;
    _state = next;
    _changes.add(next);
  }

  Future<void> loadCache() => _loading ??= _loadCache();

  Future<void> _loadCache() async {
    try {
      final raw = await cache.read();
      if (raw == null || _disposed) return;
      final saved = jsonDecode(raw);
      if (saved is! Map ||
          saved['document'] is! Map<String, dynamic> ||
          saved['floor'] is! int) {
        throw const XcCryptoException(
          XcCryptoException.badFormat,
          'policy cache',
        );
      }
      final document = await PolicyDocument.verify(
        saved['document'] as Map<String, dynamic>,
        keys: ctrlKeys(),
        brandId: brandId,
        now: _now(),
        allowExpired: true,
      );
      if (_disposed) return;
      final floor = saved['floor'] as int;
      if (floor != document.policy.seq) {
        throw const XcCryptoException(XcCryptoException.rollback);
      }
      _document = document;
      _floor = floor;
      _set(
        RemoteState(
          policy: document.policy,
          policySeq: floor,
          requiredPolicySeq: _required,
        ),
      );
    } catch (error) {
      xcLog('policy cache refused: ${error.runtimeType}', warn: true);
    }
  }

  void requirePolicy(int? seq) {
    if (seq == null || seq <= _required || seq < 0) return;
    _required = seq;
    if (seq > (_document?.policy.seq ?? -1)) {
      _etag = null;
      _set(_copy(phase: PolicyCheckPhase.unknown));
    }
  }

  void start() {
    if (_active || _disposed) return;
    _active = true;
    unawaited(pollNow());
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }

  void setForeground(bool value) {
    if (_inForeground == value) return;
    _inForeground = value;
    if (value && _active) {
      unawaited(pollNow());
    } else {
      _reschedule();
    }
  }

  void setIntervals({
    required Duration foreground,
    required Duration background,
  }) {
    this.foreground = foreground < const Duration(seconds: 15)
        ? const Duration(seconds: 15)
        : foreground;
    this.background = background < const Duration(minutes: 1)
        ? const Duration(minutes: 1)
        : background;
    _reschedule();
  }

  void _reschedule() {
    _timer?.cancel();
    if (!_active || _disposed) return;
    _timer = Timer(_period, () => unawaited(pollNow()));
  }

  Future<void> pollNow() {
    final generation = session.generation;
    if (_running != null && _runningGeneration == generation) return _running!;
    late final Future<void> running;
    running = _poll(generation).whenComplete(() {
      if (!identical(_running, running)) return;
      _running = null;
      _runningGeneration = null;
      _reschedule();
    });
    _runningGeneration = generation;
    _running = running;
    return running;
  }

  Future<void> _poll(int generation) async {
    if (!_current(generation)) return;
    await loadCache();
    if (!_current(generation)) return;
    _set(_copy(phase: PolicyCheckPhase.checking));
    try {
      await session.withDevice(() => _fetch(generation));
    } catch (error) {
      if (!_current(generation)) return;
      _verifiedGeneration = null;
      _set(_copy(phase: PolicyCheckPhase.error));
      if (error is XcCryptoException) {
        xcLog('policy refused: ${error.code}', warn: true);
      } else if (error is! XbApiException || !error.endsSession) {
        xcLog('state poll failed: ${error.runtimeType}', warn: true);
      }
    }
  }

  Future<void> _fetch(int generation) async {
    final etag = _verifiedGeneration == generation ? _etag : null;
    final response = await api.send(
      'GET',
      '/api/v1/xclient/state',
      device: true,
      headers: {'if-none-match': ?etag},
    );
    if (!_current(generation)) return;
    if (response.statusCode == 304) {
      final document = _document;
      if (etag == null ||
          _verifiedGeneration != generation ||
          document == null ||
          document.expired(_now()) ||
          document.policy.seq < _required) {
        throw const XcCryptoException(
          XcCryptoException.badFormat,
          'policy 304',
        );
      }
      _set(_copy(phase: PolicyCheckPhase.verified, checkedAt: _now()));
      return;
    }
    final data = api.unwrap(response, ApiShape.plugin);
    if (data is! Map || data['policy'] is! Map<String, dynamic>) {
      throw const XbApiException(
        XbErrorKind.badResponse,
        message: 'signed policy missing',
      );
    }
    final document = await PolicyDocument.verify(
      data['policy'] as Map<String, dynamic>,
      keys: ctrlKeys(),
      brandId: brandId,
      now: _now(),
    );
    if (!_current(generation)) return;
    final advertised = data['policy_seq'];
    if (advertised is! int ||
        advertised < 0 ||
        document.policy.seq < advertised ||
        document.policy.seq < _required ||
        document.policy.seq < _floor) {
      throw const XcCryptoException(XcCryptoException.rollback);
    }
    final previous = _document;
    if (previous != null &&
        document.policy.seq == previous.policy.seq &&
        document.content != previous.content) {
      throw const XcCryptoException(
        XcCryptoException.rollback,
        'policy content',
      );
    }
    _document = document;
    _floor = document.policy.seq;
    _set(
      RemoteState(
        bootSeq: data['boot_seq'] is int
            ? data['boot_seq'] as int
            : _state.bootSeq,
        policySeq: _floor,
        policy: document.policy,
        notice: XcNotice.fromJson(data['notice']),
        phase: PolicyCheckPhase.checking,
        requiredPolicySeq: _required,
      ),
    );
    final writing = _cacheTail.then((_) async {
      if (document.policy.seq != _floor || !_current(generation)) return;
      await cache.write(
        jsonEncode({'document': document.raw, 'floor': _floor}),
      );
    });
    _cacheTail = writing.then<void>((_) {}, onError: (Object _) {});
    await writing;
    if (!_current(generation) || !identical(_document, document)) return;
    if (document.policy.seq < _required || document.expired(_now())) {
      throw const XcCryptoException(XcCryptoException.rollback);
    }
    _verifiedGeneration = generation;
    _etag = response.header('etag');
    _set(_copy(phase: PolicyCheckPhase.verified, checkedAt: _now()));
    _expiryTimer?.cancel();
    final expiry = document.expiresAt;
    if (expiry != null) {
      _expiryTimer = Timer(
        DateTime.fromMillisecondsSinceEpoch(expiry * 1000).difference(_now()),
        () {
          if (!_current(generation)) return;
          _verifiedGeneration = null;
          _set(_copy(phase: PolicyCheckPhase.error));
          if (_active) unawaited(pollNow());
        },
      );
    }
  }

  RemoteState _copy({required PolicyCheckPhase phase, DateTime? checkedAt}) =>
      RemoteState(
        bootSeq: _state.bootSeq,
        policySeq: _state.policySeq,
        policy: _state.policy,
        notice: _state.notice,
        checkedAt: checkedAt,
        phase: phase,
        requiredPolicySeq: _required,
      );

  Future<void> _onLogout() async {
    stop();
    _expiryTimer?.cancel();
    _verifiedGeneration = null;
    _etag = null;
    _running = null;
    _runningGeneration = null;
    _set(_copy(phase: PolicyCheckPhase.unknown));
  }

  void dispose() {
    stop();
    _expiryTimer?.cancel();
    _disposed = true;
    _changes.close();
  }
}
