import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../log.dart';

abstract final class SecureKeys {
  static const auth = 'xc.auth';
  static const deviceId = 'xc.device_id';
  static const deviceSk = 'xc.device_sk';
  static const email = 'xc.email';

  static const all = [auth, deviceId, deviceSk, email];
}

/// Unreadable secrets require login again; never fall back to plaintext.
abstract class SecureStore {
  Future<String?> read(String key);

  Future<void> write(String key, String value);

  Future<void> delete(String key);

  Future<void> clear() async {
    Object? failure;
    StackTrace? trace;
    for (final key in SecureKeys.all) {
      try {
        await delete(key);
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}

/// Legacy macOS keychain avoids entitlements unavailable to ad-hoc builds.
class PlatformSecureStore extends SecureStore {
  final FlutterSecureStorage _storage;
  final String _prefix;
  // Legacy Keychain queries use service+account, without bundle identity.
  final MacOsOptions _macOptions;

  PlatformSecureStore({required String brandId, FlutterSecureStorage? storage})
    : _storage = storage ?? const FlutterSecureStorage(),
      _prefix = 'xclient.$brandId.',
      _macOptions = MacOsOptions(
        accountName: 'com.xclient.$brandId.secure-storage',
        usesDataProtectionKeychain: false,
        accessibility: KeychainAccessibility.first_unlock,
      ) {
    if (!RegExp(r'^[a-z0-9]{1,16}$').hasMatch(brandId)) {
      throw ArgumentError('Invalid secure storage brand');
    }
  }

  String _physicalKey(String key) => '$_prefix$key';

  @override
  Future<String?> read(String key) async {
    try {
      return await _storage.read(key: _physicalKey(key), mOptions: _macOptions);
    } catch (e) {
      xcLog('secure read failed for $key: ${e.runtimeType}', warn: true);
      return null;
    }
  }

  @override
  Future<void> write(String key, String value) {
    return _storage.write(
      key: _physicalKey(key),
      value: value,
      mOptions: _macOptions,
    );
  }

  @override
  Future<void> delete(String key) async {
    try {
      await _storage.delete(key: _physicalKey(key), mOptions: _macOptions);
    } catch (e) {
      xcLog('secure delete failed for $key: ${e.runtimeType}', warn: true);
      rethrow;
    }
  }
}

class MemorySecureStore extends SecureStore {
  final Map<String, String> values;

  MemorySecureStore([Map<String, String>? values]) : values = values ?? {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}
