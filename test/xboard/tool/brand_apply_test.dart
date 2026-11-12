import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/xboard/brand/brand_config.dart' as client;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../setup.dart' as setup;
import '../../../tool/xclient/brand_apply.dart';
import '../../../tool/xclient/src/brand_config.dart';
import '../../../tool/xclient/src/brand_edits.dart';

const _exampleDir = 'brands/example';

/// The repository files brand_apply reads, copied so a test can rewrite them.
const _treeEntries = [
  'android/app/build.gradle.kts',
  'android/common/src/main/res/values/strings.xml',
  'android/app/src/debug/AndroidManifest.xml',
  'android/app/src/main/AndroidManifest.xml',
  'android/app/src/main/res',
  'windows/CMakeLists.txt',
  'windows/runner/Runner.rc',
  'windows/runner/main.cpp',
  'windows/runner/resources',
  'windows/packaging/exe/make_config.yaml',
  'windows/packaging/exe/inno_setup.iss',
  'macos/Runner/Configs/AppInfo.xcconfig',
  'macos/Runner.xcodeproj/project.pbxproj',
  'macos/Runner/Info.plist',
  'macos/Runner/Assets.xcassets/AppIcon.appiconset',
  'macos/packaging/dmg/make_config.yaml',
  'distribute_options.yaml',
  'build_config.yaml',
  'lib/common/constant.dart',
  'lib/common/path.dart',
  'plugins/setup/setup_hooks/lib/src/options.dart',
  'services/helper/build.rs',
  'services/helper/src/service/windows.rs',
  'services/helper/src/service/peer.rs',
  'services/helper/src/service/hub.rs',
  'pubspec.yaml',
  'assets/images/icon.png',
];

void _copy(String from, String to) {
  final type = FileSystemEntity.typeSync(from);
  if (type == FileSystemEntityType.directory) {
    for (final entity in Directory(from).listSync(recursive: true)) {
      if (entity is! File) continue;
      final target = File(p.join(to, p.relative(entity.path, from: from)));
      target.parent.createSync(recursive: true);
      entity.copySync(target.path);
    }
  } else {
    File(to).parent.createSync(recursive: true);
    File(from).copySync(to);
  }
}

Map<String, Object?> _exampleJson() =>
    jsonDecode(File(p.join(_exampleDir, 'brand.json')).readAsStringSync())
        as Map<String, Object?>;

void main() {
  group('brand.json', () {
    test('the example brand is valid', () {
      final brand = BrandConfig.load(_exampleDir);
      expect(brand.brandId, 'example');
      expect(brand.windowsDataDir, r'com.xclient\example');
      expect(brand.relPubKeys, isNotEmpty);
      expect(brand.ctrlPubKeys, isNotEmpty);
    });

    test('defines round-trip through the client BrandConfig', () {
      final brand = BrandConfig.load(_exampleDir);
      final defines = brand.toDefines(coreVersion: '1.19.33');
      for (final value in defines.values) {
        expect(value, isA<String>());
      }
      final parsed = client.BrandConfig.fromDefines(defines);
      expect(parsed.brandId, brand.brandId);
      expect(parsed.displayName, brand.displayName);
      expect(parsed.builtinApiEndpoints, [
        for (final endpoint in brand.builtinApiEndpoints)
          client.ApiEndpointSpec(endpoint.url, weight: endpoint.weight),
      ]);
      expect(parsed.bootstrapSources, brand.bootstrapSources);
      expect(parsed.dohNames, brand.dohNames);
      expect(parsed.ctrlPubKeys, brand.ctrlPubKeys);
      expect(parsed.relPubKeys, brand.relPubKeys);
      expect(parsed.envPubKeys, brand.envPubKeys);
      expect(parsed.obfKeyBytes, hasLength(32));
      expect(parsed.panelWebUrl, brand.panelWebUrl);
      expect(parsed.supportUrl, brand.supportUrl);
      expect(parsed.coreVersion, '1.19.33');
    });

    final invalid = <String, Map<String, Object?>>{
      'an http endpoint': {
        'builtin_api_endpoints': [
          {'url': 'http://api.example.com', 'weight': 1},
        ],
      },
      'a comma inside a URL': {
        'bootstrap_sources': ['https://a.example.com/x,y'],
      },
      'a reserved URL scheme': {'url_scheme': 'clash'},
      'a lower-case GUID': {
        'windows_app_guid': 'f80d284d-d28e-4be5-902d-97972ab748c7',
      },
      'a short public key': {
        'rel_pub_keys': {'rel-1': 'AAAA'},
      },
      'no release keys': {'rel_pub_keys': <String, Object?>{}},
      'an unknown key': {'brand_name': 'x'},
      'a non-ASCII Windows name': {'windows_app_name': '加速器'},
      'a quote in the publisher': {'publisher': 'A "B"'},
      'schema 2': {'schema': 2},
    };
    for (final MapEntry(key: what, value: change) in invalid.entries) {
      test('rejects $what', () {
        expect(
          () => BrandConfig.fromJson({..._exampleJson(), ...change}),
          throwsA(isA<BrandConfigException>()),
        );
      });
    }

    test('rejects a brand_id that differs from its folder', () {
      final temp = Directory.systemTemp.createTempSync('brand_test_');
      addTearDown(() => temp.deleteSync(recursive: true));
      final dir = Directory(p.join(temp.path, 'other'))..createSync();
      File(
        p.join(dir.path, 'brand.json'),
      ).writeAsStringSync(jsonEncode(_exampleJson()));
      expect(
        () => BrandConfig.load(dir.path),
        throwsA(isA<BrandConfigException>()),
      );
    });
  });

  group('brand_apply', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('brand_apply_test_');
      for (final entry in _treeEntries) {
        _copy(entry, p.join(root.path, entry));
      }
    });

    tearDown(() {
      root.deleteSync(recursive: true);
    });

    String read(String path) =>
        File(p.join(root.path, path)).readAsStringSync();

    test(
      'explicit version overrides brand default in pubspec and compiled identity',
      () {
        final brand = BrandConfig.fromJson({
          ..._exampleJson(),
          'version_name': '2.0.0',
        });
        planBrandApply(brand, root: root.path, version: '1.0.0-pre.1').write();
        final defines = jsonDecode(read(brandDefinesFile)) as Map;
        expect(read('pubspec.yaml'), contains('version: 1.0.0-pre.1+10000401'));
        expect(defines['XC_VERSION_NAME'], '1.0.0-pre.1');
        expect(defines['XC_BUILD_NUMBER'], '10000401');
      },
    );

    test(
      'brand default version keeps native and compiled identity in sync',
      () {
        final brand = BrandConfig.fromJson({
          ..._exampleJson(),
          'version_name': '1.0.0-pre.1',
        });
        planBrandApply(brand, root: root.path).write();
        final defines = jsonDecode(read(brandDefinesFile)) as Map;
        expect(read('pubspec.yaml'), contains('version: 1.0.0-pre.1+10000401'));
        expect(defines['XC_VERSION_NAME'], '1.0.0-pre.1');
        expect(defines['XC_BUILD_NUMBER'], '10000401');
        expect(
          planBrandApply(
            brand,
            root: root.path,
          ).changes.where((change) => change.changes),
          isEmpty,
        );
      },
    );

    test(
      'without any version the pubspec and absent identity pair stay compatible',
      () {
        final before = read('pubspec.yaml');
        planBrandApply(BrandConfig.load(_exampleDir), root: root.path).write();
        final defines = jsonDecode(read(brandDefinesFile)) as Map;
        expect(read('pubspec.yaml'), before);
        expect(defines.containsKey('XC_VERSION_NAME'), isFalse);
        expect(defines.containsKey('XC_BUILD_NUMBER'), isFalse);
      },
    );

    test('planning writes nothing', () {
      final before = read('android/app/build.gradle.kts');
      final plan = planBrandApply(
        BrandConfig.load(_exampleDir),
        root: root.path,
      );
      expect(plan.changes.where((c) => c.changes), isNotEmpty);
      expect(read('android/app/build.gradle.kts'), before);
      expect(File(p.join(root.path, brandDefinesFile)).existsSync(), isFalse);
    });

    test('rewrites the native identifiers and is idempotent', () {
      final brand = BrandConfig.load(_exampleDir);
      planBrandApply(brand, root: root.path, version: '1.2.3').write();

      expect(
        read('android/app/build.gradle.kts'),
        allOf(
          contains('applicationId = "com.xclient.example"'),
          contains('namespace = "com.follow.clash"'),
        ),
      );
      expect(
        read('android/common/src/main/res/values/strings.xml'),
        contains('<string name="app_name">Example 加速器</string>'),
      );
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('<data android:scheme="xcexample" />'));
      expect(manifest, isNot(contains('android:scheme="clash"')));
      expect(
        read('windows/CMakeLists.txt'),
        contains('set(BINARY_NAME "ExampleClient")'),
      );
      expect(
        read('windows/runner/Runner.rc'),
        allOf(
          contains('VALUE "CompanyName", "com.xclient"'),
          contains('VALUE "ProductName", "example"'),
        ),
      );
      final makeConfig = read('windows/packaging/exe/make_config.yaml');
      expect(
        makeConfig,
        contains('app_id: "F80D284D-D28E-4BE5-902D-97972AB748C7"'),
      );
      expect(
        makeConfig,
        contains(r'install_dir_name: "{autopf}\\ExampleClient"'),
      );
      expect(makeConfig, contains('publisher_name: "XClient"'));
      final iss = read('windows/packaging/exe/inno_setup.iss');
      expect(iss, contains(r"{userappdata}\com.xclient\example'"));
      expect(iss, isNot(contains('com.follow')));
      expect(iss, contains("Schemes := ['xcexample', 'clash'"));
      expect(
        read('macos/Runner/Configs/AppInfo.xcconfig'),
        allOf(
          contains('PRODUCT_NAME = ExampleClient\n'),
          contains('PRODUCT_BUNDLE_IDENTIFIER = com.xclient.example\n'),
        ),
      );
      expect(
        read('macos/Runner.xcodeproj/project.pbxproj'),
        allOf(
          contains('INFOPLIST_KEY_CFBundleDisplayName = "Example 加速器";'),
          contains('PRODUCT_BUNDLE_IDENTIFIER = com.xclient.example.debug;'),
          isNot(contains('CFBundleDisplayName = FlClash')),
        ),
      );
      expect(
        read('macos/Runner/Info.plist'),
        allOf(
          contains('<string>xcexample</string>'),
          isNot(contains('<string>clash</string>')),
        ),
      );
      expect(
        read('macos/packaging/dmg/make_config.yaml'),
        contains('path: ExampleClient.app'),
      );
      expect(
        read('distribute_options.yaml'),
        contains('app_name: "ExampleClient"'),
      );
      expect(read('pubspec.yaml'), contains('\nversion: 1.2.3+10203999\n'));

      // Overlay icons replace the webp launcher icons instead of clashing.
      const res = 'android/app/src/main/res/mipmap-hdpi';
      expect(
        File(p.join(root.path, res, 'ic_launcher.png')).existsSync(),
        isTrue,
      );
      expect(
        File(p.join(root.path, res, 'ic_launcher.webp')).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(root.path, 'windows/runner/resources/app_icon.ico'),
        ).readAsBytesSync(),
        File(
          p.join(_exampleDir, 'overlay/windows/runner/resources/app_icon.ico'),
        ).readAsBytesSync(),
      );

      final defines = jsonDecode(read(brandDefinesFile)) as Map;
      expect(defines['XC_BRAND_ID'], 'example');
      expect(defines['XC_CORE_VERSION'], '1.19.33');
      expect(
        setup.readBrandDefines(root.path),
        brand.toDefines(coreVersion: '1.19.33', version: '1.2.3'),
      );
      expect(read('build_config.yaml'), contains('with_gvisor,xclient'));

      final again = planBrandApply(brand, root: root.path, version: '1.2.3');
      expect(again.changes.where((c) => c.changes).map((c) => c.path), isEmpty);
    });

    test('managed probe tag preserves other native build tags', () {
      final config = File(p.join(root.path, 'build_config.yaml'));
      config.writeAsStringSync(
        config.readAsStringSync().replaceFirst(
          'tags: with_gvisor',
          'tags: "with_gvisor,custom_tag"',
        ),
      );
      final brand = BrandConfig.load(_exampleDir);
      planBrandApply(brand, root: root.path).write();
      expect(
        read('build_config.yaml'),
        contains('with_gvisor,custom_tag,xclient'),
      );
      final before = read('build_config.yaml');
      planBrandApply(brand, root: root.path).write();
      expect(read('build_config.yaml'), before);
    });

    test('a second brand rebrands an already branded tree', () {
      planBrandApply(BrandConfig.load(_exampleDir), root: root.path).write();
      final other = Directory(p.join(root.path, 'brands', 'demo2'))
        ..createSync(recursive: true);
      File(p.join(other.path, 'brand.json')).writeAsStringSync(
        jsonEncode({
          ..._exampleJson(),
          'brand_id': 'demo2',
          'display_name': 'Demo Two',
          'app_id_android': 'com.xclient.demo2',
          'bundle_id_macos': 'com.xclient.demo2',
          'windows_app_name': 'DemoTwo',
          'windows_app_guid': '11111111-2222-3333-4444-555555555555',
          'url_scheme': 'xcdemo2',
        }),
      );
      planBrandApply(BrandConfig.load(other.path), root: root.path).write();
      expect(
        read('android/app/build.gradle.kts'),
        contains('applicationId = "com.xclient.demo2"'),
      );
      expect(
        read('windows/packaging/exe/inno_setup.iss'),
        contains(r"{localappdata}\com.xclient\demo2'"),
      );
      expect(
        read('macos/Runner/Info.plist'),
        contains('<string>xcdemo2</string>'),
      );
      expect(read('macos/Runner/Info.plist'), isNot(contains('xcexample')));
    });

    test('fails before writing when an upstream file changed shape', () {
      final gradle = File(p.join(root.path, 'android/app/build.gradle.kts'));
      gradle.writeAsStringSync(
        gradle.readAsStringSync().replaceAll('applicationId', 'appId'),
      );
      final xcconfig = read('macos/Runner/Configs/AppInfo.xcconfig');
      expect(
        () => planBrandApply(BrandConfig.load(_exampleDir), root: root.path),
        throwsA(isA<BrandEditException>()),
      );
      expect(read('macos/Runner/Configs/AppInfo.xcconfig'), xcconfig);
    });
  });

  group('escaping', () {
    test('Android strings escape apostrophes and leading @', () {
      expect(androidStringEscape("Bob's"), r"Bob\'s");
      expect(androidStringEscape('@home'), r'\@home');
    });

    test('pbxQuote escapes quotes', () {
      expect(pbxQuote('a"b'), r'"a\"b"');
    });
  });

  group('setup.dart', () {
    test('APP_ENV wins over brand defines', () {
      expect(
        setup.createBuildEnvironment(
          'stable',
          brandDefines: {'APP_ENV': 'x', 'XC_BRAND_ID': 'example'},
        ),
        {'XC_BRAND_ID': 'example', 'APP_ENV': 'stable'},
      );
    });
  });
}
