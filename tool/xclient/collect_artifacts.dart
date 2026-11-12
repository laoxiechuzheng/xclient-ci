import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'src/artifacts.dart';

const _usage = '''
Copies one platform's build outputs to the release names of docs/DESIGN.md §0.

usage: dart tool/xclient/collect_artifacts.dart --brand <id> --version <x.y.z>
         --platform <android|windows|macos> --from <dir> --to <dir>
         [--android-abi <arm64-v8a|armeabi-v7a|x86_64>]

  android  every *.apk under --from, by ABI -> <brand>-android-<abi>-v<ver>.apk
           --android-abi requires only the selected ABI's APKs
  windows  the one *setup*.exe under --from  -> <brand>-windows-x64-setup-v<ver>.exe
  macos    the one *.dmg and *.zip           -> <brand>-macos-universal-v<ver>.{dmg,zip}''';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('brand', mandatory: true)
    ..addOption('version', mandatory: true)
    ..addOption(
      'platform',
      mandatory: true,
      allowed: ['android', 'windows', 'macos'],
    )
    ..addOption('android-abi', allowed: androidAbis)
    ..addOption('from', mandatory: true)
    ..addOption('to', mandatory: true);
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on ArgParserException catch (e) {
    stderr.writeln('collect_artifacts: ${e.message}\n\n$_usage');
    exit(64);
  }
  try {
    final copied = collectArtifacts(
      brand: results['brand'] as String,
      version: results['version'] as String,
      platform: results['platform'] as String,
      from: results['from'] as String,
      to: results['to'] as String,
      androidAbi: results['android-abi'] as String?,
    );
    for (final path in copied) {
      stdout.writeln(path);
    }
  } on ArtifactException catch (e) {
    stderr.writeln('collect_artifacts: ${e.message}');
    exit(1);
  }
}

class ArtifactException implements Exception {
  final String message;

  const ArtifactException(this.message);

  @override
  String toString() => 'ArtifactException: $message';
}

/// The release name for a build output [fileName], or null when the file is
/// not a deliverable of [platform].
String? releaseNameFor({
  required String platform,
  required String brand,
  required String version,
  required String fileName,
}) {
  final lower = fileName.toLowerCase();
  switch (platform) {
    case 'android':
      if (!lower.endsWith('.apk')) return null;
      for (final abi in androidAbis) {
        if (lower.contains(abi)) return androidApkName(brand, abi, version);
      }
      return null;
    case 'windows':
      if (!lower.endsWith('.exe') || !lower.contains('setup')) return null;
      return windowsSetupName(brand, version);
    case 'macos':
      if (lower.endsWith('.dmg')) return macosDmgName(brand, version);
      if (lower.endsWith('.zip')) return macosZipName(brand, version);
      return null;
  }
  throw ArtifactException('unknown platform "$platform"');
}

List<String> collectArtifacts({
  required String brand,
  required String version,
  required String platform,
  required String from,
  required String to,
  String? androidAbi,
}) {
  if (androidAbi != null) {
    if (platform != 'android') {
      throw const ArtifactException('--android-abi is only valid for android');
    }
    if (!androidAbis.contains(androidAbi)) {
      throw ArtifactException('invalid Android ABI "$androidAbi"');
    }
  }
  if (!isValidVersion(version)) {
    throw ArtifactException('invalid version "$version"');
  }
  final source = Directory(from);
  if (!source.existsSync()) throw ArtifactException('$from does not exist');
  final targets = <String, File>{};
  final files = source.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final file in files) {
    final fileName = p.basename(file.path);
    final name = releaseNameFor(
      platform: platform,
      brand: brand,
      version: version,
      fileName: fileName,
    );
    final lower = fileName.toLowerCase();
    if (androidAbi != null &&
        lower.endsWith('.apk') &&
        (name != androidApkName(brand, androidAbi, version) ||
            androidAbis.any(
              (abi) => abi != androidAbi && lower.contains(abi),
            ))) {
      throw ArtifactException('${file.path} is not selected ABI $androidAbi');
    }
    if (name == null) continue;
    final previous = targets[name];
    if (previous != null) {
      throw ArtifactException(
        '${previous.path} and ${file.path} both map to $name',
      );
    }
    targets[name] = file;
  }
  final required = switch (platform) {
    'android' => [androidApkName(brand, androidAbi ?? 'arm64-v8a', version)],
    'windows' => [windowsSetupName(brand, version)],
    _ => [macosDmgName(brand, version), macosZipName(brand, version)],
  };
  final missing = required.where((name) => !targets.containsKey(name));
  if (missing.isNotEmpty) {
    throw ArtifactException(
      'no build output for ${missing.join(', ')} '
      'under $from',
    );
  }
  Directory(to).createSync(recursive: true);
  return [
    for (final MapEntry(key: name, value: file) in targets.entries)
      file.copySync(p.join(to, name)).path,
  ];
}
