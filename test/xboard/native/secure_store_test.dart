import 'package:flutter/widgets.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'secure_store_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const nonce = '0123456789abcdef0123456789abcdef';
  const client = ClientInfo(
    platform: XcPlatform.macos,
    arch: 'arm64',
    appVersion: '1.0.0-pre.1',
    build: '10000401',
    osVersion: '',
    deviceName: '',
  );
  late Map<String, String> values;
  late List<String> deletes;
  late int writes;
  String? failure;
  var failed = false;
  setUp(() {
    values = {};
    deletes = [];
    writes = 0;
    failure = null;
    failed = false;
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async {
            final args = Map<String, Object?>.from(call.arguments as Map);
            final key =
                '${(args['options'] as Map)['accountName']}|${args['key']}';
            if (call.method == 'delete') deletes.add(key);
            if (call.method == failure && !failed) {
              failed = true;
              throw PlatformException(
                code: 'denied',
                message: 'sensitive-synthetic-detail',
              );
            }
            switch (call.method) {
              case 'read':
                return values[key];
              case 'write':
                writes++;
                values[key] = args['value'] as String;
                return null;
              case 'delete':
                values.remove(key);
                return null;
              default:
                throw StateError('unexpected method');
            }
          },
        );
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          null,
        );
  });
  Future<NativeStoreQaResult> exercise({ClientInfo identity = client}) =>
      runNativeStoreQa(
        nonce: nonce,
        storeFor: (brand) => PlatformSecureStore(brandId: brand),
        detect: () async => identity,
        version: '1.0.0-pre.1',
        build: '10000401',
      );
  test(
    'synthetic native-store sequence proves replacement namespace and cleanup',
    () async {
      final result = await exercise();
      expect(result.success, isTrue);
      expect(writes, greaterThanOrEqualTo(4));
      expect(deletes.map((key) => key.split('|').first).toSet(), hasLength(3));
      expect(values, isEmpty);
    },
  );
  for (final method in ['read', 'write', 'delete']) {
    test('$method failure cannot pass and exposes no native message', () async {
      failure = method;
      final result = await exercise();
      expect(result.success, isFalse);
      expect(result.errors, isNotEmpty);
      expect(result.errors.join(), isNot(contains('sensitive')));
      if (method != 'read') {
        expect(
          deletes.map((key) => key.split('|').first).toSet(),
          hasLength(3),
        );
      }
    });
  }
  test(
    'OS-normalized identity cannot masquerade as compiled identity',
    () async {
      final result = await exercise(
        identity: const ClientInfo(
          platform: XcPlatform.macos,
          arch: 'arm64',
          appVersion: '1.0.0.1',
          build: '10000401',
          osVersion: '',
          deviceName: '',
        ),
      );
      expect(result.success, isFalse);
      expect(writes, 0);
    },
  );
  testWidgets('QA view paints a safe receipt without any synthetic values', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = ValueNotifier(await exercise());
    debugDefaultTargetPlatformOverride = null;
    addTearDown(state.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      NativeStoreQaView(state: state, boundaryKey: boundary),
    );
    await tester.pumpAndSettle();
    expect(find.text('All native checks passed'), findsOneWidget);
    expect(find.textContaining('synthetic-'), findsNothing);
    final failed = NativeStoreQaResult()..errors.add('native_storage_error');
    state.value = failed;
    await tester.pumpAndSettle();
    expect(find.text('native_storage_error'), findsOneWidget);
    expect(find.text('All native checks passed'), findsNothing);
  });
}
