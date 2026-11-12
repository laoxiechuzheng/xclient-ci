import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/xclient/brand_apply.dart';
import '../../../tool/xclient/src/brand_config.dart';
import '../../../tool/xclient/src/brand_edits.dart';

const servicePaths = [
  'lib/common/constant.dart',
  'lib/common/path.dart',
  'build_config.yaml',
  'plugins/setup/setup_hooks/lib/src/options.dart',
  'services/helper/build.rs',
  'services/helper/src/service/windows.rs',
  'services/helper/src/service/peer.rs',
  'services/helper/src/service/hub.rs',
];

BrandConfig brandWith(String id, String guid) {
  final json =
      jsonDecode(File('brands/example/brand.json').readAsStringSync())
          as Map<String, Object?>;
  return BrandConfig.fromJson({
    ...json,
    'brand_id': id,
    'windows_app_name': '${id}Client',
    'windows_app_guid': guid,
  });
}

void main() {
  late Directory root;
  final brand = BrandConfig.load('brands/example');
  setUp(() async {
    root = await Directory.systemTemp.createTemp('xc-services-test-');
    final paths = {
      ...brandTextEdits(brand).map((edit) => edit.path),
      ...servicePaths,
    };
    for (final path in paths) {
      final target = File(p.join(root.path, path));
      await target.parent.create(recursive: true);
      await File(path).copy(target.path);
    }
  });
  tearDown(() => root.delete(recursive: true));
  String read(String path) => File(p.join(root.path, path)).readAsStringSync();

  test('native service, pipe, binaries and packaging agree for each brand', () {
    planBrandApply(brand, root: root.path).write();
    final constants = read('lib/common/constant.dart');
    expect(
      constants,
      contains("const appHelperService = 'XClientexampleHelperService'"),
    );
    expect(constants, contains(r'pipe\\XClientexampleCore_'));
    expect(constants, contains('const helperPort = 47890'));
    expect(constants, contains(r'Services\\$appHelperService\\Runtime'));
    expect(
      read('services/helper/src/service/peer.rs'),
      contains(r'Services\XClientexampleHelperService\Runtime'),
    );
    expect(
      read('services/helper/src/service/windows.rs'),
      contains('const SERVICE_NAME: &str = "XClientexampleHelperService"'),
    );
    expect(
      read('services/helper/src/service/hub.rs'),
      contains(r'pipe\XClientexampleCore_'),
    );
    expect(
      read('lib/common/path.dart'),
      contains(r'XClientexampleCore$executableExtension'),
    );
    expect(
      read('build_config.yaml'),
      contains('core_name: XClientexampleCore'),
    );
    expect(
      read('build_config.yaml'),
      contains('helper_name: XClientexampleHelperService'),
    );
    expect(
      read('plugins/setup/setup_hooks/lib/src/options.dart'),
      contains("coreName: 'XClientexampleCore'"),
    );
    expect(
      read('services/helper/build.rs'),
      contains('XClientexampleCore.exe'),
    );
    expect(read('windows/CMakeLists.txt'), contains('XClientexampleCore.exe'));
    expect(
      read('windows/CMakeLists.txt'),
      contains('XClientexampleHelperService.exe'),
    );
    expect(
      read('macos/Runner.xcodeproj/project.pbxproj'),
      contains('XClientexampleCore'),
    );
    final inno = read('windows/packaging/exe/inno_setup.iss');
    expect(inno, contains('XClientexampleCore.exe'));
    expect(inno, contains('XClientexampleHelperService.exe'));
    expect(inno, isNot(contains('FlClashCore.exe')));
    expect(inno, isNot(contains('FlClashHelperService.exe')));
    expect(inno, contains('AppMutex=XClient-${brand.windowsAppGuid}'));
    final runner = read('windows/runner/main.cpp');
    expect(runner, contains('L"XClient-${brand.windowsAppGuid}"'));
    expect(runner, contains('window.Create(L"${brand.windowsAppName}"'));
    expect(runner, contains('const InstallerMutex installer_mutex;'));
  });

  test('rebranding removes previous services and mutex and is idempotent', () {
    final a = brandWith('brand1', '11111111-1111-1111-1111-111111111111');
    final b = brandWith('brand2', '22222222-2222-2222-2222-222222222222');
    planBrandApply(a, root: root.path).write();
    planBrandApply(b, root: root.path).write();
    for (final path in [
      ...servicePaths,
      'windows/CMakeLists.txt',
      'windows/packaging/exe/inno_setup.iss',
      'windows/runner/main.cpp',
      'macos/Runner.xcodeproj/project.pbxproj',
    ]) {
      expect(read(path), isNot(contains('XClientbrand1')), reason: path);
      expect(read(path), isNot(contains(a.windowsAppGuid)), reason: path);
    }
    expect(
      read('services/helper/src/service/peer.rs'),
      contains('XClientbrand2HelperService'),
    );
    expect(
      read('windows/runner/main.cpp'),
      contains('XClient-${b.windowsAppGuid}'),
    );
    expect(
      planBrandApply(
        b,
        root: root.path,
      ).changes.where((change) => change.changes),
      isEmpty,
    );
  });
}
