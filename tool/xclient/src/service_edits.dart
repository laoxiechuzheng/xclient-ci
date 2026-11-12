import 'package:yaml/yaml.dart';

import 'brand_config.dart';
import 'brand_edits.dart';

final _coreSymbol = RegExp(r'(?:FlClashCore|XClient[a-z0-9]{1,16}Core)');
final _helperSymbol = RegExp(
  r'(?:FlClashHelperService|XClient[a-z0-9]{1,16}HelperService)',
);

String _replaceSymbol(String text, RegExp pattern, String replacement) {
  if (!pattern.hasMatch(text)) {
    throw BrandEditException('Expected native identity ${pattern.pattern}');
  }
  return text.replaceAll(pattern, replacement);
}

List<TextEdit> serviceTextEdits(BrandConfig brand) {
  final core = 'XClient${brand.brandId}Core';
  final helper = 'XClient${brand.brandId}HelperService';
  final mutex = 'XClient-${brand.windowsAppGuid}';
  TextEdit symbols(String path, {bool hasCore = true, bool hasHelper = true}) =>
      TextEdit(path, 'isolated core/helper identity for ${brand.brandId}', (
        content,
      ) {
        var result = content;
        if (hasCore) result = _replaceSymbol(result, _coreSymbol, core);
        if (hasHelper) result = _replaceSymbol(result, _helperSymbol, helper);
        return result;
      });
  return [
    TextEdit(
      'lib/common/constant.dart',
      'brand app name, helper service and core pipe',
      (content) {
        var result = _replaceSymbol(content, _coreSymbol, core);
        result = _replaceSymbol(result, _helperSymbol, helper);
        return replaceRequired(
          result,
          RegExp(r"const appName = '[^']*';"),
          (_) => "const appName = '${brand.windowsAppName}';",
          what: 'Dart appName',
          expectedCount: 1,
        );
      },
    ),
    symbols('lib/common/path.dart', hasHelper: false),
    symbols('build_config.yaml'),
    TextEdit('build_config.yaml', 'managed native probe policy', (content) {
      final config = loadYaml(content);
      final tags = config is YamlMap ? config['tags'] : null;
      if (tags is! String) {
        throw const BrandEditException('native Core tags must be a string');
      }
      if (tags.split(RegExp(r'[\s,]+')).contains('xclient')) return content;
      return replaceRequired(
        content,
        RegExp(r'^tags:.*$', multiLine: true),
        (_) => 'tags: ${yamlQuote('$tags,xclient')}',
        what: 'native Core build tags',
        expectedCount: 1,
      );
    }),
    symbols('plugins/setup/setup_hooks/lib/src/options.dart'),
    symbols('services/helper/build.rs', hasHelper: false),
    symbols('services/helper/src/service/windows.rs', hasCore: false),
    symbols('services/helper/src/service/peer.rs', hasCore: false),
    symbols('services/helper/src/service/hub.rs'),
    symbols('windows/CMakeLists.txt'),
    symbols('macos/Runner.xcodeproj/project.pbxproj', hasHelper: false),
    TextEdit(
      'windows/runner/main.cpp',
      'installer lifetime mutex $mutex',
      (content) => replaceRequired(
        content,
        RegExp(r'constexpr wchar_t kXClientInstallerMutexName\[\] = L"[^"]*";'),
        (_) => 'constexpr wchar_t kXClientInstallerMutexName[] = L"$mutex";',
        what: 'runner installer mutex',
        expectedCount: 1,
      ),
    ),
    TextEdit(
      'windows/packaging/exe/inno_setup.iss',
      'isolated installer processes and AppMutex',
      (content) {
        var result = _replaceSymbol(content, _coreSymbol, core);
        result = _replaceSymbol(result, _helperSymbol, helper);
        final existing = RegExp(r'^AppMutex=.*$', multiLine: true);
        if (existing.hasMatch(result)) {
          return replaceRequired(
            result,
            existing,
            (_) => 'AppMutex=$mutex',
            what: 'Inno AppMutex',
            expectedCount: 1,
          );
        }
        return replaceRequired(
          result,
          RegExp(r'^\[Setup\]', multiLine: true),
          (_) => '[Setup]\nAppMutex=$mutex',
          what: 'Inno Setup section',
          expectedCount: 1,
        );
      },
    ),
  ];
}
