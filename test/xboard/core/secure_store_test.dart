import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

const _channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

class _SharedBackend {
  final values = <String, String>{};
  final calls = <({String method, String key, Map<String, String> options})>[];
  String? failingMethod;
  String? failingKey;

  Future<Object?> handle(MethodCall call) async {
    final arguments = Map<String, Object?>.from(call.arguments as Map);
    final options = Map<String, String>.from(arguments['options'] as Map);
    final key = arguments['key'] as String;
    calls.add((method: call.method, key: key, options: options));
    if (call.method == failingMethod &&
        (failingKey == null || key == failingKey)) {
      throw PlatformException(
        code: 'keychain_denied',
        message: 'fixture-secret-detail',
      );
    }
    final identity = '${options['accountName'] ?? ''}|$key';
    switch (call.method) {
      case 'read':
        return values[identity];
      case 'write':
        values[identity] = arguments['value'] as String;
        return null;
      case 'delete':
        values.remove(identity);
        return null;
      default:
        throw UnsupportedError(call.method);
    }
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _SharedBackend backend;
  late XcLogSink? previousLog;
  final logs = <String>[];
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    backend = _SharedBackend();
    logs.clear();
    previousLog = xcLogSink;
    xcLogSink = (message, {required warn}) => logs.add(message);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, backend.handle);
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
    debugDefaultTargetPlatformOverride = null;
    xcLogSink = previousLog;
  });

  for (final platform in [
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.android,
  ]) {
    test(
      'brands retain credentials and logout independently on shared $platform storage',
      () async {
        debugDefaultTargetPlatformOverride = platform;
        const raw = FlutterSecureStorage();
        await raw.write(key: SecureKeys.auth, value: 'legacy-fixture');
        await raw.write(
          key: 'unrelated-plugin-key',
          value: 'unrelated-fixture',
        );
        final first = PlatformSecureStore(brandId: '98k');
        final second = PlatformSecureStore(brandId: 'mg');
        final third = PlatformSecureStore(brandId: 'yzy');
        for (final key in SecureKeys.all) {
          await first.write(key, 'first-brand-fixture:$key');
          await second.write(key, 'second-brand-fixture:$key');
          await third.write(key, 'third-brand-fixture:$key');
        }
        final reopened = PlatformSecureStore(brandId: '98k');
        for (final key in SecureKeys.all) {
          expect(await reopened.read(key), 'first-brand-fixture:$key');
          expect(await second.read(key), 'second-brand-fixture:$key');
        }
        await reopened.clear();
        for (final key in SecureKeys.all) {
          expect(await first.read(key), isNull);
          expect(await second.read(key), 'second-brand-fixture:$key');
          expect(await third.read(key), 'third-brand-fixture:$key');
        }
        expect(await raw.read(key: SecureKeys.auth), 'legacy-fixture');
        expect(
          await raw.read(key: 'unrelated-plugin-key'),
          'unrelated-fixture',
        );
        expect(
          backend.calls.any((call) => call.method == 'deleteAll'),
          isFalse,
        );
      },
    );
  }

  test(
    'Darwin queries use stable brand services and legacy ad-hoc options',
    () async {
      const shared = FlutterSecureStorage(
        mOptions: MacOsOptions(accountName: 'injected-shared-service'),
      );
      for (final brand in ['98k', 'mg', 'yzy']) {
        final store = PlatformSecureStore(brandId: brand, storage: shared);
        await store.write(SecureKeys.auth, 'fixture');
        await store.read(SecureKeys.auth);
        await store.delete(SecureKeys.auth);
      }
      final services = backend.calls
          .map((call) => call.options['accountName'])
          .toSet();
      expect(services, hasLength(3));
      expect(services, isNot(contains(AppleOptions.defaultAccountName)));
      expect(services, isNot(contains('injected-shared-service')));
      for (final call in backend.calls) {
        expect(call.options['usesDataProtectionKeychain'], 'false');
        expect(
          call.options['accessibility'],
          KeychainAccessibility.first_unlock.name,
        );
        expect(call.options['synchronizable'], 'false');
        expect(call.options['groupId'], isNull);
        expect(call.key, isNot(SecureKeys.auth));
      }
      expect(
        backend.calls
            .take(3)
            .map((call) => call.options['accountName'])
            .toSet(),
        hasLength(1),
      );
    },
  );

  test('unscoped legacy credentials are neither read nor migrated', () async {
    const raw = FlutterSecureStorage();
    for (final key in SecureKeys.all) {
      await raw.write(key: key, value: 'legacy-fixture');
    }
    backend.calls.clear();
    final store = PlatformSecureStore(brandId: '98k');
    for (final key in SecureKeys.all) {
      expect(await store.read(key), isNull);
    }
    await store.clear();
    expect(
      backend.calls.every((call) => !SecureKeys.all.contains(call.key)),
      isTrue,
    );
    expect(backend.calls.any((call) => call.method == 'write'), isFalse);
    for (final key in SecureKeys.all) {
      expect(await raw.read(key: key), 'legacy-fixture');
    }
  });

  test(
    'read failure is absent, write and deletion failures propagate without secret logs',
    () async {
      final store = PlatformSecureStore(brandId: '98k');
      backend.failingMethod = 'read';
      expect(await store.read(SecureKeys.auth), isNull);
      backend.failingMethod = 'write';
      await expectLater(
        store.write(SecureKeys.auth, 'fixture-secret-value'),
        throwsA(isA<PlatformException>()),
      );
      backend.failingMethod = 'delete';
      await expectLater(
        store.delete(SecureKeys.auth),
        throwsA(isA<PlatformException>()),
      );
      expect(logs, hasLength(2));
      expect(logs.join(), isNot(contains('fixture-secret')));
      expect(backend.values, isEmpty);
    },
  );

  test(
    'clear attempts every owned key after one denial and preserves the other brand',
    () async {
      final first = PlatformSecureStore(brandId: '98k');
      final second = PlatformSecureStore(brandId: 'mg');
      for (final key in SecureKeys.all) {
        await first.write(key, 'first-fixture');
        await second.write(key, 'second-fixture');
      }
      backend.failingKey = backend.calls.first.key;
      backend.failingMethod = 'delete';
      await expectLater(first.clear(), throwsA(isA<PlatformException>()));
      expect(
        backend.calls.where((call) => call.method == 'delete'),
        hasLength(SecureKeys.all.length),
      );
      backend.failingMethod = null;
      expect(await first.read(SecureKeys.auth), 'first-fixture');
      for (final key in SecureKeys.all.skip(1)) {
        expect(await first.read(key), isNull);
      }
      for (final key in SecureKeys.all) {
        expect(await second.read(key), 'second-fixture');
      }
    },
  );

  test('invalid brand namespaces fail before any native query', () {
    for (final brand in ['', '98K', '../mg', 'mg:xc.auth', 'a' * 17]) {
      expect(() => PlatformSecureStore(brandId: brand), throwsArgumentError);
    }
    expect(backend.calls, isEmpty);
  });
}
