import 'dart:async';
import 'dart:convert';

import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'update_qa_contract.dart';
import 'update_store_observer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<Map<String, Object?>> events;
  late List<String> names;
  late UpdateQaStoreDiagnostics diagnostics;
  late UpdateQaObservedStorage observed;

  setUp(() {
    events = [];
    names = [];
    diagnostics = UpdateQaStoreDiagnostics(
      stage: '2',
      write: (name, event) async {
        names.add(name);
        events.add(event);
      },
    );
    observed = UpdateQaObservedStorage(diagnostics);
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'observed storage forwards the original selected options and data',
    () async {
      final calls = <Map<String, Object?>>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add({'method': call.method, 'arguments': call.arguments});
        return call.method == 'read' ? 'SYNTHETIC_VALUE' : null;
      });
      const options = MacOsOptions(
        accountName: 'SYNTHETIC_SERVICE',
        accessibility: KeychainAccessibility.first_unlock,
        usesDataProtectionKeychain: false,
      );
      const windows = WindowsOptions(useBackwardCompatibility: true);
      Future<void> exercise(FlutterSecureStorage storage) async {
        await diagnostics.run(
          UpdateQaStoreOperation.crossRead,
          () => storage.read(
            key: 'SYNTHETIC_KEY',
            mOptions: options,
            wOptions: windows,
          ),
        );
        await diagnostics.run(
          UpdateQaStoreOperation.replacementWrite,
          () => storage.write(
            key: 'SYNTHETIC_KEY',
            value: 'SYNTHETIC_VALUE',
            mOptions: options,
            wOptions: windows,
          ),
        );
        await diagnostics.run(
          UpdateQaStoreOperation.cleanupDelete,
          () => storage.delete(
            key: 'SYNTHETIC_KEY',
            mOptions: options,
            wOptions: windows,
          ),
        );
      }

      for (final platform in [TargetPlatform.macOS, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = platform;
        calls.clear();
        await exercise(const FlutterSecureStorage());
        final baseline = List<Map<String, Object?>>.of(calls);
        calls.clear();
        await exercise(observed);
        expect(calls, baseline);
      }
      final encoded = jsonEncode(events);
      for (final secret in [
        'SYNTHETIC_SERVICE',
        'SYNTHETIC_KEY',
        'SYNTHETIC_VALUE',
      ]) {
        expect(encoded, isNot(contains(secret)));
      }
      expect(names.toSet().length, names.length);
    },
  );

  test(
    'native failure is observed before the production read wrapper swallows it',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
          code: 'Unexpected security result code',
          message: 'SENSITIVE_NATIVE_MESSAGE',
          details: -25308,
        );
      });
      final store = PlatformSecureStore(brandId: 'qa', storage: observed);
      expect(
        await diagnostics.run(
          UpdateQaStoreOperation.crossRead,
          () => store.read('SENSITIVE_KEY'),
        ),
        isNull,
      );
      final native = events.singleWhere(
        (event) => event['event'] == 'nativeReturn',
      );
      expect(native['exception_kind'], 'platform');
      expect(native['plugin_code'], 'securityStatus');
      expect(native['os_status'], -25308);
      expect(native['outcome'], 'error');
      expect(jsonEncode(events), isNot(contains('SENSITIVE')));
    },
  );

  test(
    'late native completion keeps its original operation after a timeout',
    () async {
      final pending = Completer<String?>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        return call.method == 'read' ? pending.future : null;
      });
      await expectLater(
        diagnostics.run(
          UpdateQaStoreOperation.crossRead,
          () => observed
              .read(key: 'SYNTHETIC_KEY')
              .timeout(const Duration(milliseconds: 1)),
        ),
        throwsA(isA<TimeoutException>()),
      );
      await diagnostics.run(
        UpdateQaStoreOperation.cleanupDelete,
        () => observed.delete(key: 'SYNTHETIC_KEY'),
      );
      pending.complete('SENSITIVE_LATE_VALUE');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
      final late = events.singleWhere(
        (event) => event['event'] == 'nativeReturn' && event['id'] == 1,
      );
      expect(late['operation'], 'crossRead');
      expect(late['late'], isTrue);
      expect(late['outcome'], 'success');
      final end = events.singleWhere(
        (event) => event['event'] == 'end' && event['id'] == 1,
      );
      expect(end['outcome'], 'timeout');
      expect(
        events
            .where((event) => event['id'] == 2)
            .every((event) => event['operation'] == 'cleanupDelete'),
        isTrue,
      );
      expect(jsonEncode(events), isNot(contains('SENSITIVE')));
      expect(names.toSet().length, names.length);
    },
  );

  test('only a signed 32-bit integer detail is recorded as OSStatus', () {
    for (final detail in <Object?>[
      'SENSITIVE_DETAIL',
      {'SENSITIVE_DETAIL': -25308},
      true,
      1 << 40,
      null,
    ]) {
      final result = updateQaStoreError(
        PlatformException(
          code: 'SENSITIVE_CODE',
          message: 'SENSITIVE_MESSAGE',
          details: detail,
        ),
      );
      expect(result['os_status'], isNull);
      expect(result['plugin_code'], 'unknown');
      expect(jsonEncode(result), isNot(contains('SENSITIVE')));
    }
  });

  test(
    'diagnostic write failure never replaces the original native error',
    () async {
      final error = PlatformException(
        code: 'Unexpected security result code',
        message: 'SENSITIVE_NATIVE_MESSAGE',
        details: -25308,
      );
      final failing = UpdateQaStoreDiagnostics(
        stage: '2',
        write: (name, event) async {
          if (event['event'] != 'begin') {
            throw StateError('SENSITIVE_DIAGNOSTIC_FAILURE');
          }
        },
      );
      await expectLater(
        failing.run(
          UpdateQaStoreOperation.crossRead,
          () => failing.native<String?>(
            UpdateQaStoreMethod.read,
            () => Future.error(error),
          ),
        ),
        throwsA(same(error)),
      );
    },
  );

  test('unowned native call is refused before touching the channel', () async {
    var calls = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls++;
      return null;
    });
    await expectLater(
      observed.read(key: 'SYNTHETIC_KEY'),
      throwsA(isA<UpdateQaRefused>()),
    );
    expect(calls, 0);
    expect(events, isEmpty);
  });
}
