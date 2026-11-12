import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'brand_config.dart';
import 'artifacts.dart';

const brandDefinesFile = 'xclient_defines.json';

const overlayAllowedPrefixes = [
  'android/app/src/main/res/',
  'windows/runner/resources/',
  'macos/Runner/Assets.xcassets/AppIcon.appiconset/',
  'assets/images/',
];

const _androidResourceExtensions = {'.png', '.webp', '.jpg', '.xml'};

class BrandEditException implements Exception {
  final String message;

  const BrandEditException(this.message);

  @override
  String toString() => 'BrandEditException: $message';
}

class TextEdit {
  final String path;
  final String description;
  final String Function(String content) transform;

  const TextEdit(this.path, this.description, this.transform);
}

class PlannedChange {
  final String path;
  final String description;
  final bool changes;
  final bool delete;

  const PlannedChange(
    this.path,
    this.description, {
    required this.changes,
    this.delete = false,
  });

  @override
  String toString() {
    final action = delete
        ? 'del '
        : changes
        ? 'edit'
        : 'same';
    return '$action  $path  ($description)';
  }
}

/// A missing match fails branding instead of silently retaining upstream identifiers.
String replaceRequired(
  String content,
  RegExp pattern,
  String Function(Match match) replace, {
  required String what,
  int? expectedCount,
}) {
  final matches = pattern.allMatches(content).length;
  if (matches == 0) {
    throw BrandEditException('no match for $what (${pattern.pattern})');
  }
  if (expectedCount != null && matches != expectedCount) {
    throw BrandEditException(
      'expected $expectedCount match(es) for $what, found $matches',
    );
  }
  return content.replaceAllMapped(pattern, replace);
}

String xmlEscape(String value) => const HtmlEscape(
  HtmlEscapeMode.attribute,
).convert(value).replaceAll('&#39;', '&apos;');

/// Android string resources also treat `'`, `"`, `@` and `?` specially.
String androidStringEscape(String value) {
  var escaped = xmlEscape(value)
      .replaceAll('&apos;', "'")
      .replaceAll("'", r"\'")
      .replaceAll('&quot;', r'\"');
  if (escaped.startsWith('@') || escaped.startsWith('?')) {
    escaped = '\\$escaped';
  }
  return escaped;
}

String pbxQuote(String value) {
  final escaped = value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
  return '"$escaped"';
}

String yamlQuote(String value) => jsonEncode(value);

/// An explicit version also writes the monotonic pubspec build number.
List<TextEdit> brandTextEdits(BrandConfig brand, {String? version}) {
  final display = brand.displayName;
  final exe = brand.windowsExecutable;
  return [
    TextEdit(
      'android/app/build.gradle.kts',
      'applicationId -> ${brand.appIdAndroid} (namespace and Kotlin package '
          'stay com.follow.clash)',
      (c) => replaceRequired(
        c,
        RegExp(r'applicationId = "[^"]*"'),
        (_) => 'applicationId = "${brand.appIdAndroid}"',
        what: 'applicationId',
        expectedCount: 1,
      ),
    ),
    TextEdit(
      'android/common/src/main/res/values/strings.xml',
      'app_name / service_channel_name -> $display',
      (c) {
        var out = replaceRequired(
          c,
          RegExp(r'<string name="app_name">[^<]*</string>'),
          (_) =>
              '<string name="app_name">${androidStringEscape(display)}</string>',
          what: 'app_name',
          expectedCount: 1,
        );
        out = replaceRequired(
          out,
          RegExp(r'<string name="service_channel_name">[^<]*</string>'),
          (_) =>
              '<string name="service_channel_name">'
              '${androidStringEscape('$display Service')}</string>',
          what: 'service_channel_name',
          expectedCount: 1,
        );
        return out;
      },
    ),
    TextEdit(
      'android/app/src/debug/AndroidManifest.xml',
      'debug label -> $display Debug',
      (c) => replaceRequired(
        c,
        RegExp(r'android:label="[^"]*"'),
        (_) => 'android:label="${xmlEscape('$display Debug')}"',
        what: 'debug android:label',
      ),
    ),
    TextEdit(
      'android/app/src/main/AndroidManifest.xml',
      'URL schemes clash/clashmeta/flclash -> ${brand.urlScheme}',
      (c) => replaceRequired(
        c,
        RegExp(
          r'([ \t]*)<data android:scheme="[^"]*" />(\s*<data android:scheme="[^"]*" />)*',
        ),
        (m) => '${m[1]}<data android:scheme="${brand.urlScheme}" />',
        what: 'android:scheme block',
        expectedCount: 1,
      ),
    ),
    TextEdit(
      'windows/CMakeLists.txt',
      'BINARY_NAME -> ${brand.windowsAppName}',
      (c) => replaceRequired(
        c,
        RegExp(r'set\(BINARY_NAME "[^"]*"\)'),
        (_) => 'set(BINARY_NAME "${brand.windowsAppName}")',
        what: 'BINARY_NAME',
        expectedCount: 1,
      ),
    ),
    TextEdit(
      'windows/runner/Runner.rc',
      'version info; CompanyName/ProductName -> data dir '
          '%APPDATA%\\${brand.windowsDataDir}',
      (c) {
        final values = {
          'CompanyName': brand.windowsCompany,
          'FileDescription': brand.windowsAppName,
          'InternalName': brand.windowsAppName,
          'LegalCopyright': 'Copyright (C) ${brand.publisher}',
          'OriginalFilename': exe,
          'ProductName': brand.brandId,
        };
        var out = c;
        for (final MapEntry(:key, :value) in values.entries) {
          out = replaceRequired(
            out,
            RegExp('VALUE "$key", "[^"]*"'),
            (_) => 'VALUE "$key", "$value"',
            what: 'Runner.rc $key',
            expectedCount: 1,
          );
        }
        return out;
      },
    ),
    TextEdit(
      'windows/runner/main.cpp',
      'initial window title -> ${brand.windowsAppName}',
      (c) => replaceRequired(
        c,
        RegExp(r'window\.Create\(L"[^"]*"'),
        (_) => 'window.Create(L"${brand.windowsAppName}"',
        what: 'window.Create title',
        expectedCount: 1,
      ),
    ),
    TextEdit(
      'windows/packaging/exe/make_config.yaml',
      'Inno Setup app_id ${brand.windowsAppGuid}, names, publisher, '
          'install dir',
      (c) => _setYamlKeys(c, {
        'app_id': brand.windowsAppGuid,
        'app_name': brand.windowsAppName,
        'publisher': brand.publisher,
        'publisher_name': brand.publisher,
        if (brand.publisherUrl != null) 'publisher_url': brand.publisherUrl!,
        'display_name': display,
        'executable_name': exe,
        'output_base_file_name': exe,
        'install_dir_name': '{autopf}\\${brand.windowsAppName}',
      }),
    ),
    TextEdit(
      'windows/packaging/exe/inno_setup.iss',
      'user data dir -> ${brand.windowsDataDir}; URL schemes',
      (c) {
        var out = replaceRequired(
          c,
          RegExp(r"\{(userappdata|localappdata)\}\\[^\\']+\\[^\\']+'"),
          (m) => "{${m[1]}}\\${brand.windowsDataDir}'",
          what: 'iss DelTree data dir',
          expectedCount: 2,
        );
        out = replaceRequired(
          out,
          RegExp(
            r"RemoveDir\(ExpandConstant\('\{(userappdata|localappdata)\}\\[^\\']+'\)\)",
          ),
          (m) =>
              "RemoveDir(ExpandConstant('{${m[1]}}\\${brand.windowsCompany}'))",
          what: 'iss RemoveDir company dir',
          expectedCount: 2,
        );
        // Retain upstream schemes so uninstall also cleans registrations from older builds.
        out = replaceRequired(
          out,
          RegExp(r'Schemes := \[[^\]]*\];'),
          (_) =>
              "Schemes := ['${brand.urlScheme}', 'clash', 'clashmeta', "
              "'flclash'];",
          what: 'iss Schemes',
          expectedCount: 1,
        );
        return out;
      },
    ),
    TextEdit(
      'macos/Runner/Configs/AppInfo.xcconfig',
      'PRODUCT_NAME ${brand.macosProductName}, PRODUCT_BUNDLE_IDENTIFIER '
          '${brand.bundleIdMacos}',
      (c) {
        final values = {
          'PRODUCT_NAME': brand.macosProductName,
          'PRODUCT_BUNDLE_IDENTIFIER': brand.bundleIdMacos,
          'PRODUCT_COPYRIGHT': 'Copyright © ${brand.publisher}',
        };
        var out = c;
        for (final MapEntry(:key, :value) in values.entries) {
          out = replaceRequired(
            out,
            RegExp('^$key = .*\$', multiLine: true),
            (_) => '$key = $value',
            what: 'AppInfo.xcconfig $key',
            expectedCount: 1,
          );
        }
        return out;
      },
    ),
    TextEdit(
      'macos/Runner.xcodeproj/project.pbxproj',
      'CFBundleDisplayName -> $display; debug bundle id',
      (c) {
        var out = replaceRequired(
          c,
          RegExp(r'INFOPLIST_KEY_CFBundleDisplayName = [^;]*;'),
          (_) => 'INFOPLIST_KEY_CFBundleDisplayName = ${pbxQuote(display)};',
          what: 'INFOPLIST_KEY_CFBundleDisplayName',
        );
        out = replaceRequired(
          out,
          RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = [^;]*\.debug;'),
          (_) => 'PRODUCT_BUNDLE_IDENTIFIER = ${brand.bundleIdMacos}.debug;',
          what: 'debug PRODUCT_BUNDLE_IDENTIFIER',
          expectedCount: 1,
        );
        return out;
      },
    ),
    TextEdit(
      'macos/Runner/Info.plist',
      'CFBundleURLSchemes -> ${brand.urlScheme}; usage strings',
      (c) {
        var out = replaceRequired(
          c,
          RegExp(
            r'(<key>CFBundleURLSchemes</key>\s*<array>)(\s*)[\s\S]*?(\s*</array>)',
          ),
          (m) => '${m[1]}${m[2]}<string>${brand.urlScheme}</string>${m[3]}',
          what: 'CFBundleURLSchemes',
          expectedCount: 1,
        );
        out = replaceRequired(
          out,
          RegExp(
            r'(<key>NSLocationWhenInUseUsageDescription</key>\s*<string>)[^<]*(</string>)',
          ),
          (m) =>
              '${m[1]}${xmlEscape(display)} needs location access to detect '
              'WiFi network name for connectivity features.${m[2]}',
          what: 'NSLocationWhenInUseUsageDescription',
          expectedCount: 1,
        );
        return out;
      },
    ),
    TextEdit(
      'macos/packaging/dmg/make_config.yaml',
      'dmg title and .app name',
      (c) {
        var out = _setYamlKeys(c, {'title': display});
        out = replaceRequired(
          out,
          RegExp(r'path: [^\n]*\.app'),
          (_) => 'path: ${brand.macosProductName}.app',
          what: 'dmg .app path',
          expectedCount: 1,
        );
        return out;
      },
    ),
    TextEdit(
      'distribute_options.yaml',
      'app_name -> ${brand.windowsAppName} (artifact base name)',
      (c) => _setYamlKeys(c, {'app_name': brand.windowsAppName}),
    ),
    if (version != null)
      TextEdit(
        'pubspec.yaml',
        'version -> $version+${buildNumberFor(version)}',
        (c) => replaceRequired(
          c,
          RegExp(r'^version: .*$', multiLine: true),
          (_) => 'version: $version+${buildNumberFor(version)}',
          what: 'pubspec version',
          expectedCount: 1,
        ),
      ),
  ];
}

String _setYamlKeys(String content, Map<String, String> values) {
  var out = content;
  for (final MapEntry(:key, :value) in values.entries) {
    final line = '$key: ${yamlQuote(value)}';
    final pattern = RegExp('^$key:[^\\n]*\$', multiLine: true);
    if (pattern.hasMatch(out)) {
      out = out.replaceFirst(pattern, line);
    } else {
      out = '${out.endsWith('\n') || out.isEmpty ? out : '$out\n'}$line\n';
    }
  }
  return out;
}

/// Overlay destinations outside overlayAllowedPrefixes are rejected.
List<(File, String)> overlayFiles(BrandConfig brand) {
  final dir = brand.directory;
  if (dir == null) return const [];
  final overlay = Directory(p.join(dir, brand.iconsDir));
  if (!overlay.existsSync()) return const [];
  final result = <(File, String)>[];
  final entities = overlay.listSync(recursive: true, followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    if (entity is Link) {
      throw BrandEditException(
        'overlay must not contain links: ${entity.path}',
      );
    }
    if (entity is! File) continue;
    final relative = p
        .relative(entity.path, from: overlay.path)
        .replaceAll(r'\', '/');
    if (relative.split('/').contains('..') ||
        !overlayAllowedPrefixes.any(relative.startsWith)) {
      throw BrandEditException(
        'overlay file $relative is outside ${overlayAllowedPrefixes.join(', ')}',
      );
    }
    result.add((entity, relative));
  }
  return result;
}

/// Remove same-base Android resources with different extensions to avoid resource collisions.
List<String> conflictingAndroidResources(String root, String destination) {
  const resPrefix = 'android/app/src/main/res/';
  if (!destination.startsWith(resPrefix)) return const [];
  final extension = p.extension(destination);
  if (!_androidResourceExtensions.contains(extension)) return const [];
  final dir = Directory(p.join(root, p.dirname(destination)));
  if (!dir.existsSync()) return const [];
  final base = p.basenameWithoutExtension(destination);
  return [
    for (final entity in dir.listSync())
      if (entity is File &&
          p.basenameWithoutExtension(entity.path) == base &&
          p.extension(entity.path) != extension &&
          _androidResourceExtensions.contains(p.extension(entity.path)))
        p.relative(entity.path, from: root).replaceAll(r'\', '/'),
  ]..sort();
}

String encodeDefines(Map<String, String> defines) {
  return '${const JsonEncoder.withIndent('  ').convert(defines)}\n';
}
