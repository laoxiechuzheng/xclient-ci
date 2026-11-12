import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../auth/session.dart';
import '../crypto/b64u.dart';
import '../crypto/crypto_exception.dart';
import '../crypto/device_keys.dart';
import '../crypto/envelope.dart';
import '../crypto/signed_doc.dart';
import '../log.dart';
import '../net/api_client.dart';
import '../net/api_exception.dart';
import 'config_rewrite.dart';

/// The one FlClash profile the sync owns. Nothing else may create or edit
/// it; it has no URL.
abstract class ManagedProfileSink {
  /// Saves [yaml] as the managed profile, makes it current and applies it.
  /// Throws when the core rejects the config.
  Future<void> apply(
    Uint8List yaml, {
    required String label,
    String? subscriptionUserinfo,
  });

  /// Deletes the managed profile and its file (logout, revocation).
  Future<void> remove();
}

enum SyncPhase { idle, syncing, ok, blocked, error }

/// `subscription-userinfo` parsed for display (bytes; [expire] Unix seconds,
/// 0 when none).
class SubscriptionUsage {
  final int upload;
  final int download;
  final int total;
  final int expire;

  const SubscriptionUsage({
    this.upload = 0,
    this.download = 0,
    this.total = 0,
    this.expire = 0,
  });

  static SubscriptionUsage? parse(String? header) {
    if (header == null || header.isEmpty) return null;
    final values = <String, int>{};
    for (final field in header.split(';')) {
      final eq = field.indexOf('=');
      if (eq == -1) continue;
      final raw = field.substring(eq + 1).trim();
      final value = int.tryParse(raw) ?? double.tryParse(raw)?.truncate();
      if (value != null) {
        values[field.substring(0, eq).trim().toLowerCase()] = value;
      }
    }
    return SubscriptionUsage(
      upload: values['upload'] ?? 0,
      download: values['download'] ?? 0,
      total: values['total'] ?? 0,
      expire: values['expire'] ?? 0,
    );
  }
}

class SyncStatus {
  final SyncPhase phase;
  final DateTime? lastSuccess;

  /// The status the panel's subscription route answered inside the
  /// envelope (200, 403, …).
  final int? panelStatus;

  /// Chinese text for the UI when [phase] is blocked or error.
  final String? message;
  final XbApiException? error;
  final SubscriptionUsage? usage;
  final DateTime? nextSync;
  final DateTime? retryAt;
  final String? blockedCode;
  final String? cleanupWarning;

  const SyncStatus({
    this.phase = SyncPhase.idle,
    this.lastSuccess,
    this.panelStatus,
    this.message,
    this.error,
    this.usage,
    this.nextSync,
    this.retryAt,
    this.blockedCode,
    this.cleanupWarning,
  });

  SyncStatus copyWith({
    SyncPhase? phase,
    DateTime? lastSuccess,
    int? panelStatus,
    String? message,
    bool clearMessage = false,
    XbApiException? error,
    bool clearError = false,
    SubscriptionUsage? usage,
    DateTime? nextSync,
    DateTime? retryAt,
    String? blockedCode,
    String? cleanupWarning,
    bool clearRestriction = false,
  }) => SyncStatus(
    phase: phase ?? this.phase,
    lastSuccess: lastSuccess ?? this.lastSuccess,
    panelStatus: panelStatus ?? this.panelStatus,
    message: clearMessage ? null : message ?? this.message,
    error: clearError ? null : error ?? this.error,
    usage: usage ?? this.usage,
    nextSync: nextSync ?? this.nextSync,
    retryAt: retryAt ?? this.retryAt,
    blockedCode: clearRestriction ? null : blockedCode ?? this.blockedCode,
    cleanupWarning: clearRestriction
        ? null
        : cleanupWarning ?? this.cleanupWarning,
  );
}

abstract final class SyncMessages {
  static const blocked = '账号当前不可用或订阅已被限制，请检查套餐、流量与到期时间';
  static const network = '节点更新失败：网络连接异常，将自动重试';
  static const invalid = '节点更新失败：收到的配置无法校验';
  static const config = '节点更新失败：配置无法被内核加载';
  static const device = '节点更新失败：设备尚未注册';

  static String panelStatus(int status) => '节点更新失败：服务端返回 $status';
}

/// Pulls the encrypted subscription (DESIGN §4.1), turns it into the managed
/// profile, and keeps it fresh: the `profile-update-interval` the panel sets
/// (at least an hour), plus whenever the runtime asks after a seq change.
class SubscriptionSync {
  static const minInterval = Duration(hours: 1);
  static const defaultInterval = Duration(hours: 24);

  final ApiClient api;
  final Session session;
  final ManagedProfileSink sink;
  final TrustedKeys Function() envKeys;
  final Set<String> Function() directHosts;
  final String label;
  final DateTime Function() _now;
  final Random _random;

  SyncStatus _status = const SyncStatus();
  final _changes = StreamController<SyncStatus>.broadcast();
  Timer? _timer;
  Future<SyncStatus>? _running;
  Duration _interval = defaultInterval;
  int _failures = 0;
  int _blockedAttempts = 0;
  DateTime? _nextAllowed;
  DateTime? _automaticAfter;
  static const minimumCheckGap = Duration(seconds: 10);
  bool _active = false;

  SubscriptionSync({
    required this.api,
    required this.session,
    required this.sink,
    required this.envKeys,
    required this.directHosts,
    required this.label,
    DateTime Function()? now,
    Random? random,
  }) : _now = now ?? DateTime.now,
       _random = random ?? Random.secure() {
    session.addLogoutHook(_onLogout);
  }

  SyncStatus get status => _status;

  Stream<SyncStatus> get changes => _changes.stream;

  Duration get interval => _interval;

  void _set(SyncStatus next) {
    _status = next;
    if (!_changes.isClosed) _changes.add(next);
  }

  /// Starts periodic syncing with one sync right away.
  void start() {
    if (_active) return;
    _active = true;
    _schedule(Duration.zero);
  }

  void stop() {
    _active = false;
    _timer?.cancel();
    _timer = null;
  }

  /// A sync soon, coalescing bursts (seq changes, resets).
  void requestSync({Duration delay = const Duration(seconds: 2)}) {
    if (!_active) return;
    final at = _now().add(delay);
    final next = _status.nextSync;
    if (next != null && next.isBefore(at) && _timer != null) return;
    _schedule(delay);
  }

  void _schedule(Duration delay) {
    _timer?.cancel();
    if (!_active) return;
    var at = _now().add(delay);
    for (final bound in [_nextAllowed, _automaticAfter]) {
      if (bound != null && bound.isAfter(at)) at = bound;
    }
    _set(_status.copyWith(nextSync: at));
    _timer = Timer(
      at.difference(_now()) < Duration.zero
          ? Duration.zero
          : at.difference(_now()),
      () {
        _timer = null;
        unawaited(syncNow());
      },
    );
  }

  /// One pull now; concurrent callers share it.
  Future<SyncStatus> syncNow() {
    final existing = _running;
    if (existing != null) return existing;
    if (!session.state.isLoggedIn) return Future.value(_status);
    final now = _now();
    final next = _nextAllowed;
    if (next != null && now.isBefore(next)) return Future.value(_status);
    _nextAllowed = now.add(minimumCheckGap);
    late final Future<SyncStatus> running;
    running = _sync().whenComplete(() {
      if (identical(_running, running)) _running = null;
    });
    _running = running;
    return running;
  }

  Future<SyncStatus> _sync() async {
    if (!session.state.isLoggedIn) return _status;
    final generation = _generation;
    _set(
      _status.copyWith(
        phase: _status.phase == SyncPhase.blocked
            ? SyncPhase.blocked
            : SyncPhase.syncing,
        retryAt: _nextAllowed,
      ),
    );
    try {
      final plain = await session.withDevice(_pull);
      if (generation != _generation || !session.state.isLoggedIn) {
        return _status;
      }
      final result = await _handle(plain, generation);
      if (generation != _generation) return _status;
      if (result.phase == SyncPhase.blocked) {
        _scheduleNext(_automaticAfter!.difference(_now()));
      } else {
        _failures = 0;
        _blockedAttempts = 0;
        _automaticAfter = null;
        _scheduleNext(_interval);
      }
      return _status;
    } on XbApiException catch (e) {
      if (generation != _generation) return _status;
      if (e.endsSession) {
        _set(const SyncStatus());
        return _status;
      }
      if (e.status == 403 && e.kind != XbErrorKind.deviceLimit) {
        final result = await _restrict(
          generation,
          status: 403,
          message: e.displayMessage.isEmpty
              ? SyncMessages.blocked
              : e.displayMessage,
          retryAfter: e.retryAfter ?? const Duration(seconds: 60),
        );
        if (generation == _generation) {
          _scheduleNext(_automaticAfter!.difference(_now()));
        }
        return result;
      }
      _failures++;
      if (e.retryAfter case final retry? when retry > Duration.zero) {
        final at = _now().add(retry);
        if (_nextAllowed == null || at.isAfter(_nextAllowed!)) {
          _nextAllowed = at;
        }
        _automaticAfter = at;
      }
      if (_status.phase == SyncPhase.blocked) {
        _set(_status.copyWith(error: e, retryAt: _nextAllowed));
        _scheduleNext(_retryDelay(e));
        return _status;
      }
      _set(
        _status.copyWith(
          phase: SyncPhase.error,
          error: e,
          retryAt: _nextAllowed,
          message: switch (e.kind) {
            XbErrorKind.network || XbErrorKind.tls => SyncMessages.network,
            XbErrorKind.deviceLimit => SessionMessages.deviceLimit,
            _ =>
              e.displayMessage.isEmpty
                  ? SyncMessages.panelStatus(e.status ?? 0)
                  : e.displayMessage,
          },
        ),
      );
      _scheduleNext(_retryDelay(e));
      return _status;
    } on XcCryptoException catch (e) {
      if (generation != _generation) return _status;
      xcLog('envelope refused: ${e.code}', warn: true);
      _failures++;
      if (_status.phase == SyncPhase.blocked) {
        _scheduleNext(_retryDelay(null));
        return _status;
      }
      _set(
        _status.copyWith(
          phase: SyncPhase.error,
          message: SyncMessages.invalid,
          clearError: true,
        ),
      );
      _scheduleNext(_retryDelay(null));
      return _status;
    } catch (e) {
      if (generation != _generation) return _status;
      xcLog('profile apply failed: ${e.runtimeType}', warn: true);
      _failures++;
      if (_status.phase == SyncPhase.blocked) {
        _scheduleNext(_retryDelay(null));
        return _status;
      }
      _set(
        _status.copyWith(
          phase: SyncPhase.error,
          message: SyncMessages.config,
          clearError: true,
        ),
      );
      _scheduleNext(_retryDelay(null));
      return _status;
    }
  }

  Duration _retryDelay(XbApiException? e) {
    if (e?.retryAfter case final after? when after > Duration.zero) {
      return after;
    }
    if (_status.phase == SyncPhase.blocked) {
      final seconds = min(300, 60 * pow(2, min(_failures, 3)).toInt());
      final jitter = seconds < 300
          ? _random.nextInt(min(15, 300 - seconds) + 1)
          : 0;
      return Duration(seconds: seconds + jitter);
    }
    final minutes = min(60, 2 * pow(2, min(_failures, 5)).toInt());
    final jitter = Duration(seconds: _random.nextInt(30));
    final delay = Duration(minutes: minutes) + jitter;
    return delay < _interval ? delay : _interval;
  }

  void _scheduleNext(Duration delay) {
    if (_status.phase == SyncPhase.blocked) {
      final at = _now().add(delay);
      if (_automaticAfter == null || at.isAfter(_automaticAfter!)) {
        _automaticAfter = at;
      }
      _set(_status.copyWith(nextSync: _automaticAfter));
    }
    if (_active) _schedule(delay);
  }

  Future<EnvelopePlain> _pull() async {
    final identity = session.identity;
    final sessionGeneration = session.generation;
    if (identity == null) {
      throw const XbApiException(XbErrorKind.unauthorized);
    }
    for (var attempt = 0; ; attempt++) {
      if (session.generation != sessionGeneration) {
        throw const XbApiException(XbErrorKind.unauthorized);
      }
      final reqNonce = b64uEncode(randomBytes(16, _random));
      final ts = _now().millisecondsSinceEpoch ~/ 1000;
      try {
        final data = await api.call(
          'POST',
          '/api/v1/xclient/subscribe',
          shape: ApiShape.plugin,
          device: true,
          json: {
            'device_id': identity.deviceId,
            'ts': ts,
            'req_nonce': reqNonce,
          },
          timeout: const Duration(seconds: 40),
          idempotent: true,
        );
        if (data is! Map<String, dynamic>) {
          throw const XbApiException(
            XbErrorKind.badResponse,
            message: 'envelope',
          );
        }
        return await openEnvelope(
          data,
          device: identity.keys,
          deviceId: identity.deviceId,
          reqNonce: reqNonce,
          envKeys: envKeys(),
          now: _now().millisecondsSinceEpoch ~/ 1000,
        );
      } on XbApiException catch (e) {
        if (e.kind == XbErrorKind.replay && attempt == 0) continue;
        rethrow;
      }
    }
  }

  int _generation = 0;
  Future<void>? _applying;

  Future<SyncStatus> _handle(EnvelopePlain plain, int generation) async {
    final usage = SubscriptionUsage.parse(
      plain.headers['subscription-userinfo'],
    );
    final hours = int.tryParse(
      (plain.headers['profile-update-interval'] ?? '').trim(),
    );
    final wanted = hours == null || hours <= 0
        ? defaultInterval
        : Duration(hours: hours);
    _interval = wanted < minInterval ? minInterval : wanted;
    final admission = plain.admission;
    if (admission?.blocked == true || plain.status == 403) {
      return _restrict(
        generation,
        status: plain.status,
        message: admission?.message.isNotEmpty == true
            ? admission!.message
            : SyncMessages.blocked,
        code: admission?.code.isNotEmpty == true
            ? admission!.code
            : 'subscription_restricted',
        retryAfter: admission?.retryAfter ?? const Duration(seconds: 60),
        usage: usage,
      );
    }
    if (plain.status != 200) {
      throw XbApiException(
        plain.status == 429
            ? XbErrorKind.rateLimited
            : plain.status >= 500
            ? XbErrorKind.server
            : XbErrorKind.failed,
        status: plain.status,
        message: SyncMessages.panelStatus(plain.status),
        retryAfter: plain.status == 429
            ? Duration(
                seconds: int.tryParse(plain.headers['retry-after'] ?? '') ?? 60,
              )
            : null,
      );
    }
    final yaml = ConfigRewrite.apply(
      utf8.decode(plain.body, allowMalformed: true),
      directHosts: directHosts(),
    );
    final applying = sink.apply(
      Uint8List.fromList(utf8.encode(yaml)),
      label: label,
      subscriptionUserinfo: plain.headers['subscription-userinfo'],
    );
    _applying = applying;
    try {
      await applying;
    } finally {
      if (identical(_applying, applying)) _applying = null;
    }
    if (generation != _generation) return _status;
    _set(
      _status.copyWith(
        phase: SyncPhase.ok,
        panelStatus: 200,
        lastSuccess: _now(),
        usage: usage,
        clearMessage: true,
        clearError: true,
        clearRestriction: true,
      ),
    );
    return _status;
  }

  Future<SyncStatus> _restrict(
    int generation, {
    required int status,
    required String message,
    String code = 'subscription_restricted',
    required Duration retryAfter,
    SubscriptionUsage? usage,
  }) async {
    _blockedAttempts++;
    final base = min(300, 60 * pow(2, min(_blockedAttempts - 1, 3)).toInt());
    final jitter = base < 300 ? _random.nextInt(min(15, 300 - base) + 1) : 0;
    final backoff = Duration(seconds: base + jitter);
    final delay = retryAfter > backoff ? retryAfter : backoff;
    _automaticAfter = _now().add(delay);
    _set(
      SyncStatus(
        phase: SyncPhase.blocked,
        panelStatus: status,
        message: message,
        blockedCode: code,
        usage: usage,
        retryAt: _nextAllowed,
        nextSync: _automaticAfter,
      ),
    );
    final removal = sink.remove();
    _applying = removal;
    try {
      await removal;
    } catch (error) {
      xcLog(
        'restricted profile cleanup failed: ${error.runtimeType}',
        warn: true,
      );
      if (generation == _generation) {
        _set(
          _status.copyWith(
            cleanupWarning: '旧连接或缓存未能完全清理，请手动断开系统 VPN 或重启客户端后重试；当前禁止新的连接',
          ),
        );
      }
    } finally {
      if (identical(_applying, removal)) _applying = null;
    }
    return _status;
  }

  Future<void> _onLogout() async {
    _generation++;
    _running = null;
    stop();
    _interval = defaultInterval;
    _failures = 0;
    _blockedAttempts = 0;
    _nextAllowed = null;
    _automaticAfter = null;
    try {
      await _applying;
    } catch (_) {
      // Cleanup must also run when an in-flight profile write fails.
    }
    await sink.remove();
    _set(const SyncStatus());
  }

  void dispose() {
    stop();
    _changes.close();
  }
}
