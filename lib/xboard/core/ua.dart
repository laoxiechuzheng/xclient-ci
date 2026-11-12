import 'dart:ffi' show Abi;
import 'dart:io';

enum XcPlatform { android, windows, macos }

/// Avoid Xboard protocol flags and browser-preview markers.
const forbiddenUaSubstrings = [
  'verge',
  'flclash',
  'clashmetaforandroid',
  'nekobox',
  'surge',
  'surfboard',
  'stash',
  'sing-box',
  'singbox',
  'hiddify',
  'sfm',
  'shadowsocks',
  'shadowrocket',
  'quantumult',
  'loon',
  'general',
  'v2rayn',
  'passwall',
  'ssrplus',
  'sagernet',
  'mozilla',
  'chrome',
  'safari',
  'edge',
  'okhttp',
  'dart',
];

class UaParts {
  final String brandId;
  final String appVersion;
  final String build;
  final XcPlatform platform;

  final String osVersion;
  final String arch;
  final String coreVersion;

  final String? product;

  const UaParts({
    required this.brandId,
    required this.appVersion,
    required this.build,
    required this.platform,
    required this.osVersion,
    required this.arch,
    required this.coreVersion,
    this.product,
  });
}

String _clean(String value, RegExp allowed, String fallback) {
  final cleaned = value.replaceAll(allowed, '');
  return cleaned.isEmpty ? fallback : cleaned;
}

final _notVersion = RegExp(r'[^0-9.]');
final _notAppVersion = RegExp(r'[^A-Za-z0-9.\-]');
final _notToken = RegExp(r'[^A-Za-z0-9_.\-]');

String _osSegment(XcPlatform platform, String osVersion) {
  switch (platform) {
    case XcPlatform.android:
      final release = _clean(osVersion, _notVersion, '0');
      return 'Android $release; Mobile';
    case XcPlatform.windows:
      return 'Windows NT 10.0; Win64; x64';
    case XcPlatform.macos:
      final parts = _clean(osVersion, _notVersion, '0').split('.');
      final major = parts.isNotEmpty && parts[0].isNotEmpty ? parts[0] : '0';
      final minor = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : '0';
      return 'Macintosh; Mac OS X ${major}_$minor';
  }
}

String buildUserAgent(UaParts parts) {
  final product = _clean(
    parts.product ?? '${parts.brandId}Client',
    RegExp('[^A-Za-z0-9._-]'),
    'XClient',
  );
  final version = _clean(
    parts.appVersion.split('+').first,
    _notAppVersion,
    '0',
  );
  final build = _clean(parts.build, RegExp('[^0-9]'), '0');
  final arch = _clean(parts.arch, _notToken, 'unknown');
  final core = _clean(
    parts.coreVersion.replaceFirst('v', ''),
    _notVersion,
    '0',
  );
  return '$product/$version '
      '(${_osSegment(parts.platform, parts.osVersion)}; $arch; b$build) '
      'mihomo/$core Clash.Meta';
}

/// Binary ABI, rather than every architecture the device supports.
String currentArch([Abi? abi]) {
  return switch (abi ?? Abi.current()) {
    Abi.androidArm64 => 'arm64-v8a',
    Abi.androidArm => 'armeabi-v7a',
    Abi.androidX64 => 'x86_64',
    Abi.androidIA32 => 'x86',
    Abi.windowsX64 => 'x64',
    Abi.windowsArm64 => 'arm64',
    Abi.windowsIA32 => 'x86',
    Abi.macosArm64 => 'arm64',
    Abi.macosX64 => 'x86_64',
    _ => 'unknown',
  };
}

XcPlatform currentPlatform() {
  if (Platform.isAndroid) return XcPlatform.android;
  if (Platform.isMacOS) return XcPlatform.macos;
  return XcPlatform.windows;
}

List<String> forbiddenSubstringsIn(String ua) {
  final lower = ua.toLowerCase();
  return [
    for (final word in forbiddenUaSubstrings)
      if (lower.contains(word)) word,
  ];
}
