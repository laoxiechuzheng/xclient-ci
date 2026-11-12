import 'dart:async';

import '../client_info.dart';
import '../log.dart';
import '../net/api_client.dart';
import '../net/api_exception.dart';
import 'device_identity.dart';
import 'secure_store.dart';

enum XcSessionStatus { restoring, loggedOut, loggingIn, loggedIn, error }

/// UI texts the session sets as [XcSessionState.message].
abstract final class SessionMessages {
  static const expired = '登录已过期，请重新登录';
  static const deviceRevoked = '此设备已在设备管理中被移除，请重新登录';
  static const deviceLimit = '登录设备数已达上限，请在设备管理中移除不用的设备';
  static const network = '网络连接失败，请稍后重试';
  static const storage = '无法读写系统安全存储，请重新登录';
  static const cleanup = '本机登录数据未能完全清除，已退出当前会话，请重试清理';
}

class XcSessionState {
  final XcSessionStatus status;

  /// For display only.
  final String? email;

  /// `GET /user/info` data once fetched.
  final Map<String, dynamic>? user;

  /// The device is registered for this login; subscription pulls wait on it.
  final bool deviceRegistered;

  /// Why registration failed (e.g. [XbErrorKind.deviceLimit]).
  final XbApiException? deviceError;

  /// `{device_id, max_devices, active_devices, env_kid}` from the plugin.
  final Map<String, dynamic>? device;

  /// Why the session ended or the login failed, in Chinese.
  final String? message;

  const XcSessionState({
    required this.status,
    this.email,
    this.user,
    this.deviceRegistered = false,
    this.deviceError,
    this.device,
    this.message,
  });

  static const restoring = XcSessionState(status: XcSessionStatus.restoring);

  bool get isLoggedIn => status == XcSessionStatus.loggedIn;

  XcSessionState copyWith({
    XcSessionStatus? status,
    String? email,
    Map<String, dynamic>? user,
    bool? deviceRegistered,
    XbApiException? deviceError,
    bool clearDeviceError = false,
    Map<String, dynamic>? device,
    String? message,
  }) => XcSessionState(
    status: status ?? this.status,
    email: email ?? this.email,
    user: user ?? this.user,
    deviceRegistered: deviceRegistered ?? this.deviceRegistered,
    deviceError: clearDeviceError ? null : deviceError ?? this.deviceError,
    device: device ?? this.device,
    message: message ?? this.message,
  );
}

typedef LogoutHook = Future<void> Function();

/// Login with Xboard e-mail and password, device registration and logout
/// (DESIGN §3). Keeps only `auth_data` (never the password or the
/// subscription token) in the secure store.
class Session {
  final ApiClient api;
  final SecureStore store;
  final ClientInfo client;

  DeviceIdentity? _identity;
  XcSessionState _state = XcSessionState.restoring;
  final _changes = StreamController<XcSessionState>.broadcast();
  final _logoutHooks = <LogoutHook>[];
  Future<Map<String, dynamic>>? _registering;
  Future<void>? _ending;
  Future<void> _storeTail = Future<void>.value();
  int _generation = 0;
  bool _disposed = false;

  Session({required this.api, required this.store, required this.client}) {
    api.addErrorListener(_onApiError);
  }

  XcSessionState get state => _state;
  Stream<XcSessionState> get changes => _changes.stream;
  DeviceIdentity? get identity => _identity;
  int get generation => _generation;

  void addLogoutHook(LogoutHook hook) => _logoutHooks.add(hook);

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<T> _inStore<T>(Future<T> Function() operation) {
    final run = _storeTail.then((_) => operation());
    _storeTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  void _set(XcSessionState next) {
    if (_disposed) return;
    _state = next;
    _changes.add(next);
  }

  void _onApiError(XbApiException error) {
    if (!_state.isLoggedIn) return;
    final message = switch (error.kind) {
      XbErrorKind.unauthorized => SessionMessages.expired,
      XbErrorKind.deviceRevoked => SessionMessages.deviceRevoked,
      _ => null,
    };
    if (message == null) return;
    unawaited(
      _end(message).catchError((Object error) {
        xcLog('session cleanup failed: ${error.runtimeType}', warn: true);
      }),
    );
  }

  Future<void> restore() async {
    final generation = ++_generation;
    await _ending;
    if (!_current(generation)) return;
    _set(XcSessionState.restoring);
    try {
      final restored = await _inStore(() async {
        if (!_current(generation)) return null;
        final auth = await store.read(SecureKeys.auth);
        if (auth == null || auth.isEmpty || !_current(generation)) return null;
        final identity = await DeviceIdentity.loadOrCreate(store);
        final email = await store.read(SecureKeys.email);
        return (auth, identity, email);
      });
      if (!_current(generation)) return;
      if (restored == null) {
        _set(const XcSessionState(status: XcSessionStatus.loggedOut));
        return;
      }
      final (auth, identity, email) = restored;
      _identity = identity;
      api
        ..authorization = auth
        ..deviceId = identity.deviceId;
      _set(XcSessionState(status: XcSessionStatus.loggedIn, email: email));
      unawaited(
        ensureRegistered().then<void>(
          (_) {},
          onError: (Object error) {
            xcLog(
              'device register on restore failed: ${error.runtimeType}',
              warn: true,
            );
          },
        ),
      );
      unawaited(refreshUser().then<void>((_) {}, onError: (Object _) {}));
    } catch (error) {
      if (!_current(generation)) return;
      xcLog('secure store unusable: ${error.runtimeType}', warn: true);
      _set(
        const XcSessionState(
          status: XcSessionStatus.loggedOut,
          message: SessionMessages.storage,
        ),
      );
      rethrow;
    }
  }

  Future<void> login(String email, String password) async {
    var generation = ++_generation;
    final ending = _ending;
    if (ending != null) await ending;
    if (!_current(generation)) return;
    if (_state.isLoggedIn) {
      final cleanup = _end(null);
      generation = _generation;
      await cleanup;
      if (!_current(generation)) return;
    }
    _registering = null;
    final address = email.trim();
    _set(XcSessionState(status: XcSessionStatus.loggingIn, email: address));
    final String auth;
    try {
      final data = await api.call(
        'POST',
        '/api/v1/passport/auth/login',
        form: {'email': address, 'password': password},
        auth: false,
        idempotent: false,
      );
      if (!_current(generation)) return;
      final value = data is Map ? data['auth_data'] : null;
      if (value is! String || value.isEmpty) {
        throw const XbApiException(
          XbErrorKind.badResponse,
          message: 'no auth_data',
        );
      }
      auth = value;
    } on XbApiException catch (error) {
      if (!_current(generation)) return;
      _set(
        XcSessionState(
          status: XcSessionStatus.error,
          email: address,
          message:
              error.kind == XbErrorKind.network || error.kind == XbErrorKind.tls
              ? SessionMessages.network
              : error.displayMessage,
        ),
      );
      rethrow;
    }
    final DeviceIdentity? identity;
    try {
      identity = await _inStore(() async {
        if (!_current(generation)) return null;
        final identity = await DeviceIdentity.loadOrCreate(store);
        if (!_current(generation)) return null;
        await store.write(SecureKeys.auth, auth);
        if (!_current(generation)) return null;
        await store.write(SecureKeys.email, address);
        return identity;
      });
    } catch (error) {
      if (!_current(generation)) return;
      xcLog('secure store write failed: ${error.runtimeType}', warn: true);
      try {
        await _inStore(() async {
          if (_current(generation)) await store.clear();
        });
      } catch (cleanup) {
        xcLog(
          'partial login cleanup failed: ${cleanup.runtimeType}',
          warn: true,
        );
      }
      if (!_current(generation)) return;
      _set(
        XcSessionState(
          status: XcSessionStatus.error,
          email: address,
          message: SessionMessages.storage,
        ),
      );
      rethrow;
    }
    if (!_current(generation) || identity == null) return;
    _identity = identity;
    api
      ..authorization = auth
      ..deviceId = identity.deviceId;
    _set(XcSessionState(status: XcSessionStatus.loggedIn, email: address));
    try {
      await registerDevice();
    } on XbApiException catch (error) {
      xcLog('device register failed: ${error.kind.name}', warn: true);
    }
    if (!_current(generation)) return;
    unawaited(refreshUser().then<void>((_) {}, onError: (Object _) {}));
  }

  Future<Map<String, dynamic>> registerDevice() {
    final existing = _registering;
    if (existing != null) return existing;
    late final Future<Map<String, dynamic>> registering;
    registering = _register(_generation).whenComplete(() {
      if (identical(_registering, registering)) _registering = null;
    });
    _registering = registering;
    return registering;
  }

  Future<Map<String, dynamic>> _register(int generation) async {
    final identity = _identity;
    if (identity == null || !_state.isLoggedIn || !_current(generation)) {
      throw const XbApiException(XbErrorKind.unauthorized);
    }
    try {
      final data = await api.call(
        'POST',
        '/api/v1/xclient/device/register',
        shape: ApiShape.plugin,
        device: true,
        json: {
          'device_id': identity.deviceId,
          'pub': identity.publicKeyB64u,
          'platform': client.platform.name,
          'arch': client.arch,
          'app_version': client.appVersion,
          'build': client.build,
          'os_version': client.osVersion,
          'device_name': client.deviceName,
        },
        idempotent: true,
      );
      final device = data is Map<String, dynamic> ? data : <String, dynamic>{};
      if (_current(generation) && _state.isLoggedIn) {
        _set(
          _state.copyWith(
            deviceRegistered: true,
            device: device,
            clearDeviceError: true,
          ),
        );
      }
      return device;
    } on XbApiException catch (error) {
      if (_current(generation) && _state.isLoggedIn && !error.endsSession) {
        _set(
          _state.copyWith(
            deviceRegistered: false,
            deviceError: error,
            message: error.kind == XbErrorKind.deviceLimit
                ? SessionMessages.deviceLimit
                : null,
          ),
        );
      }
      rethrow;
    }
  }

  Future<void> ensureRegistered() async {
    if (_state.isLoggedIn && !_state.deviceRegistered) await registerDevice();
  }

  void _requireCurrent(int generation) {
    if (!_current(generation) || !_state.isLoggedIn) {
      throw const XbApiException(XbErrorKind.unauthorized);
    }
  }

  Future<T> withDevice<T>(Future<T> Function() action) async {
    final generation = _generation;
    await ensureRegistered();
    _requireCurrent(generation);
    try {
      final value = await action();
      _requireCurrent(generation);
      return value;
    } on XbApiException catch (error) {
      if (error.kind != XbErrorKind.deviceUnknown || !_current(generation)) {
        rethrow;
      }
      _requireCurrent(generation);
      _set(_state.copyWith(deviceRegistered: false));
      await registerDevice();
      _requireCurrent(generation);
      final value = await action();
      _requireCurrent(generation);
      return value;
    }
  }

  Future<Map<String, dynamic>?> refreshUser() async {
    if (!_state.isLoggedIn) return null;
    final generation = _generation;
    final data = await api.call('GET', '/api/v1/user/info');
    if (!_current(generation) ||
        !_state.isLoggedIn ||
        data is! Map<String, dynamic>) {
      return null;
    }
    _set(_state.copyWith(user: data));
    return data;
  }

  Future<void> logout() {
    final ending = _ending;
    if (ending != null) return ending;
    final auth = api.authorization;
    final device = api.deviceId;
    return _end(
      null,
      revoke: auth == null
          ? null
          : () async {
              await api.call(
                'POST',
                '/api/v1/xclient/logout',
                shape: ApiShape.plugin,
                auth: false,
                headers: {'authorization': auth, 'x-xclient-device': ?device},
                json: const {},
                timeout: const Duration(seconds: 5),
                idempotent: true,
              );
            },
    );
  }

  Future<void> _end(String? message, {Future<void> Function()? revoke}) {
    final ending = _ending;
    if (ending != null) return ending;
    _generation++;
    _registering = null;
    api
      ..authorization = null
      ..deviceId = null;
    _identity = null;
    _set(XcSessionState(status: XcSessionStatus.loggedOut, message: message));
    final completion = Completer<void>();
    final future = completion.future;
    _ending = future;
    unawaited(
      _wipe(message, revoke).then<void>(
        (_) {
          if (identical(_ending, future)) _ending = null;
          completion.complete();
        },
        onError: (Object error, StackTrace stack) {
          if (identical(_ending, future)) _ending = null;
          completion.completeError(error, stack);
        },
      ),
    );
    return future;
  }

  Future<void> _wipe(String? message, Future<void> Function()? revoke) async {
    final remote = revoke == null
        ? null
        : Future<void>.sync(revoke).catchError((Object error) {
            xcLog('server logout failed: ${error.runtimeType}', warn: true);
          });
    Object? failure;
    for (final hook in List.of(_logoutHooks)) {
      try {
        await hook();
      } catch (error) {
        failure ??= error;
        xcLog('logout hook failed: ${error.runtimeType}', warn: true);
      }
    }
    try {
      await _inStore(store.clear);
    } catch (error) {
      failure ??= error;
      xcLog('secure cleanup failed: ${error.runtimeType}', warn: true);
    }
    await remote;
    if (failure != null) {
      _set(
        XcSessionState(
          status: XcSessionStatus.loggedOut,
          message: [?message, SessionMessages.cleanup].join('；'),
        ),
      );
      throw const XbApiException(
        XbErrorKind.failed,
        message: SessionMessages.cleanup,
      );
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    api.removeErrorListener(_onApiError);
    _changes.close();
  }
}
