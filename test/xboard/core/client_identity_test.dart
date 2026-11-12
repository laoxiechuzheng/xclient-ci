import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:fl_clash/xboard/update/version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const compiledVersion = String.fromEnvironment('XC_VERSION_NAME');
  const compiledBuild = String.fromEnvironment('XC_BUILD_NUMBER');

  void metadata(String version, String build) {
    PackageInfo.setMockInitialValues(
      appName: 'Test',
      packageName: 'com.xclient.example',
      version: version,
      buildNumber: build,
      buildSignature: '',
    );
  }

  test(
    'detect uses compiled identity or preserves the macOS metadata fallback',
    () async {
      metadata('1.0.0.1', '10000401');
      final info = await ClientInfo.detect();
      expect(
        info.appVersion,
        compiledVersion.isEmpty ? '1.0.0.1' : compiledVersion,
      );
      expect(info.build, compiledBuild.isEmpty ? '10000401' : compiledBuild);
      if (compiledVersion.isNotEmpty) {
        expect(AppVersion.fromParts(info.appVersion, info.build), isNotNull);
      }
    },
  );

  test(
    'detect uses compiled build or preserves the Android metadata fallback',
    () async {
      metadata('1.0.0-pre.1', '10002401');
      final info = await ClientInfo.detect();
      expect(
        info.appVersion,
        compiledVersion.isEmpty ? '1.0.0-pre.1' : compiledVersion,
      );
      expect(info.build, compiledBuild.isEmpty ? '10002401' : compiledBuild);
    },
  );

  PackageInfo package(String version, String build) => PackageInfo(
    appName: 'Test',
    packageName: 'com.xclient.example',
    version: version,
    buildNumber: build,
  );

  for (final (platform, osVersion, osBuild) in [
    (XcPlatform.macos, '1.0.0.1', '10000401'),
    (XcPlatform.android, '1.0.0-pre.1', '10002401'),
    (XcPlatform.windows, '1.0.0.1', '10000401'),
  ]) {
    test('canonical identity handles observed $platform OS metadata', () {
      final native = package(osVersion, osBuild);
      final info = ClientInfo.fromPackageInfo(
        native,
        platform: platform,
        arch: 'arm64-v8a',
        canonicalVersion: '1.0.0-pre.1',
        canonicalBuild: '10000401',
      );
      expect(info.appVersion, '1.0.0-pre.1');
      expect(info.build, '10000401');
      expect(AppVersion.fromParts(info.appVersion, info.build), isNotNull);
      final ua = buildUserAgent(
        info.uaParts(brandId: 'example', coreVersion: '1.19.33'),
      );
      expect(ua, contains('exampleClient/1.0.0-pre.1'));
      expect(ua, contains('b10000401'));
      expect(native.version, osVersion);
      expect(native.buildNumber, osBuild);
    });
  }

  test(
    'no explicit identity preserves ordinary PackageInfo values without guessing',
    () {
      final info = ClientInfo.fromPackageInfo(
        package('1.0.0.1', '10002401'),
        platform: XcPlatform.macos,
        arch: 'arm64',
        canonicalVersion: '',
        canonicalBuild: '',
      );
      expect(info.appVersion, '1.0.0.1');
      expect(info.build, '10002401');
      expect(info.deviceName, 'macos');
    },
  );

  for (final (version, build) in [
    ('', '10000401'),
    ('1.0.0-pre.1', ''),
    ('1.0.0.1', '10000401'),
    ('v1.0.0', '10000401'),
    ('1.0', '10000401'),
    ('01.0.0', '10000401'),
    ('1.0.0-pre..1', '10000401'),
    ('1.0.0-01', '10000401'),
    ('1.0.0+10000401', '10000401'),
    ('1.0.0\n', '10000401'),
    ('999999999999999999999999999.0.0', '10000401'),
    ('1.0.0', '0'),
    ('1.0.0', '-1'),
    ('1.0.0', '01'),
    ('1.0.0', '1.5'),
    ('1.0.0', '1e3'),
    ('1.0.0', '1\n'),
    ('1.0.0', '2147479648'),
  ]) {
    test(
      'partial or invalid compiled identity is refused ($version / $build)',
      () {
        expect(
          () => ClientInfo.fromPackageInfo(
            package('1.0.0', '1'),
            platform: XcPlatform.android,
            arch: 'arm64-v8a',
            canonicalVersion: version,
            canonicalBuild: build,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'safe error',
              'Invalid compiled client identity',
            ),
          ),
        );
      },
    );
  }
}
