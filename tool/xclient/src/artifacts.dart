library;

final _versionPattern = RegExp(
  r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|pre|rc)(?:\.([1-9][0-9]*))?)?$',
);

const androidAbis = ['arm64-v8a', 'armeabi-v7a', 'x86_64'];

bool isValidVersion(String version) => _buildNumber(version) != null;

/// The monotonic pubspec/UA build precedes Flutter's per-ABI Android versionCode offset.
int buildNumberFor(String version) {
  final build = _buildNumber(version);
  if (build == null) {
    throw FormatException('Unsupported release version "$version"');
  }
  return build;
}

int? _buildNumber(String version) {
  final match = _versionPattern.firstMatch(version);
  if (match == null || match.end != version.length) return null;
  final major = int.tryParse(match[1]!);
  final minor = int.tryParse(match[2]!);
  final patch = int.tryParse(match[3]!);
  if (major == null ||
      minor == null ||
      patch == null ||
      major > 200 ||
      minor > 99 ||
      patch > 99) {
    return null;
  }
  final channel = match[4];
  final serial = match[5] == null ? null : int.tryParse(match[5]!);
  final int stage;
  if (channel == null) {
    stage = 999;
  } else if (channel == 'pre' && match[5] == null) {
    stage = 400;
  } else {
    if (serial == null || serial > (channel == 'rc' ? 398 : 199)) return null;
    stage = switch (channel) {
      'alpha' => serial,
      'beta' => 200 + serial,
      'pre' => 400 + serial,
      'rc' => 600 + serial,
      _ => throw StateError('Unexpected version channel'),
    };
  }
  return major * 10000000 + minor * 100000 + patch * 1000 + stage;
}

String androidApkName(String brand, String abi, String version) =>
    '$brand-android-$abi-v$version.apk';

String windowsSetupName(String brand, String version) =>
    '$brand-windows-x64-setup-v$version.exe';

String macosDmgName(String brand, String version) =>
    '$brand-macos-universal-v$version.dmg';

String macosZipName(String brand, String version) =>
    '$brand-macos-universal-v$version.zip';

String releaseDocName(String brand, String version) =>
    '$brand-release-v$version.json';

/// DMG packages serve first installs and are excluded from in-app update assets.
({String key, String? kind})? assetKeyFor(
  String brand,
  String version,
  String fileName,
) {
  for (final abi in androidAbis) {
    if (fileName == androidApkName(brand, abi, version)) {
      return (key: 'android-$abi', kind: null);
    }
  }
  if (fileName == windowsSetupName(brand, version)) {
    return (key: 'windows-x64', kind: null);
  }
  if (fileName == macosZipName(brand, version)) {
    return (key: 'macos-universal', kind: 'zip');
  }
  return null;
}

String assetUrl(String base, String version, String fileName) {
  final expanded = base
      .replaceAll('{version}', version)
      .replaceAll('{tag}', 'v$version');
  final uri = Uri.tryParse(expanded);
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) {
    throw FormatException('URL base must be https://, got "$base"');
  }
  final trimmed = expanded.endsWith('/')
      ? expanded.substring(0, expanded.length - 1)
      : expanded;
  return '$trimmed/${Uri.encodeComponent(fileName)}';
}
