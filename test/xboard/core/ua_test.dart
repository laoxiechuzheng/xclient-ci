import 'dart:ffi' show Abi;

import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';

/// Xboard protocol flags; omitted site-specific openclash flags cannot match.
const _protocolFlags = <String, List<String>>{
  'Clash': ['clash'],
  'ClashMeta': [
    'meta',
    'verge',
    'flclash',
    'nekobox',
    'clashmetaforandroid',
    '98k/clashmi',
    '98k/mac',
    '98k/clashmac',
    'yzy/clashmi',
    'yzy/mac',
    'yzy/clashmac',
    'mg/clashmi',
    'mg/mac',
    'mg/clashmac',
  ],
  'General': [
    'general',
    'v2rayn',
    'v2rayng',
    'passwall',
    'ssrplus',
    'sagernet',
  ],
  'Loon': ['loon'],
  'QuantumultX': ['quantumult%20x', 'quantumult-x'],
  'Shadowrocket': ['shadowrocket'],
  'Shadowsocks': ['shadowsocks'],
  'SingBox': ['sing-box', 'hiddify', 'sfm'],
  'Stash': ['stash'],
  'Surfboard': ['surfboard'],
  'Surge': ['surge'],
};

const _gatedClientNames = {
  'nekobox',
  'clashmetaforandroid',
  'nekoray',
  'verge',
  'clashx meta',
  'flclash',
};

final _allFlags = [for (final flags in _protocolFlags.values) ...flags];

({String flag, String? name, String? version}) getClientInfo(
  String userAgent, {
  String? flagParam,
}) {
  final flag = (flagParam ?? userAgent).toLowerCase();
  String? name;
  String? version;
  final first = RegExp(
    r'([a-zA-Z0-9\-_]+)[\/\s]+(v?[0-9]+(?:\.[0-9]+){0,2})',
  ).firstMatch(flag);
  if (first != null) {
    final potential = first.group(1)!.toLowerCase();
    version = first.group(2)!.replaceFirst(RegExp('^v'), '');
    if (_allFlags.contains(potential)) name = potential;
  }
  if (name == null) {
    // Match the stable collect()->sortByDesc(strlen) ordering.
    final sorted = _allFlags.indexed.toList()
      ..sort((a, b) {
        final byLength = b.$2.length.compareTo(a.$2.length);
        return byLength != 0 ? byLength : a.$1.compareTo(b.$1);
      });
    for (final (_, candidate) in sorted) {
      if (flag.contains(candidate)) {
        name = candidate;
        if (version == null) {
          final match = RegExp(
            '${RegExp.escape(candidate)}[\\/\\s]+(v?[0-9]+(?:\\.[0-9]+){0,2})',
            caseSensitive: false,
          ).firstMatch(flag);
          if (match != null) {
            version = match.group(1)!.replaceFirst(RegExp('^v'), '');
          }
        }
        break;
      }
    }
  }
  if (version == null) {
    final match = RegExp(r'\/v?(\d+(?:\.\d+){0,2})').firstMatch(flag);
    if (match != null) version = match.group(1);
  }
  return (flag: flag, name: name, version: version);
}

String? matchProtocolClassName(String flag) {
  final lower = flag.toLowerCase();
  for (final entry in _protocolFlags.entries.toList().reversed) {
    if (entry.value.any((f) => lower.contains(f.toLowerCase()))) {
      return entry.key;
    }
  }
  return null;
}

void main() {
  const brands = ['98k', 'mg', 'yzy'];
  const arches = {
    XcPlatform.android: ['arm64-v8a', 'armeabi-v7a', 'x86_64'],
    XcPlatform.windows: ['x64', 'arm64'],
    XcPlatform.macos: ['arm64', 'x86_64', 'universal'],
  };
  const osVersions = {
    XcPlatform.android: '14',
    XcPlatform.windows: '',
    XcPlatform.macos: '15.1.0',
  };

  test('example from DESIGN §2', () {
    final ua = buildUserAgent(
      const UaParts(
        brandId: '98k',
        appVersion: '1.0.0+100',
        build: '100',
        platform: XcPlatform.android,
        osVersion: '14',
        arch: 'arm64-v8a',
        coreVersion: 'v1.19.33',
      ),
    );
    expect(
      ua,
      '98kClient/1.0.0 (Android 14; Mobile; arm64-v8a; b100) '
      'mihomo/1.19.33 Clash.Meta',
    );
  });

  test(
    'app prerelease identity survives while header controls and metadata are removed',
    () {
      String ua(String version) => buildUserAgent(
        UaParts(
          brandId: 'example',
          appVersion: version,
          build: '10000401',
          platform: XcPlatform.android,
          osVersion: '14',
          arch: 'arm64-v8a',
          coreVersion: 'v1.19.33',
        ),
      );
      expect(
        ua('1.0.0-pre.1+10000401'),
        startsWith('exampleClient/1.0.0-pre.1 ('),
      );
      for (final unsafe in [
        '1.0.0-pre.1\r\nInjected: value',
        '1.0.0-pre.1 /()\t',
      ]) {
        final actual = ua(unsafe);
        final versionToken = actual.split('/')[1].split(' ').first;
        expect(versionToken, matches(RegExp(r'^[A-Za-z0-9.\-]+$')));
        expect(actual, isNot(contains('\r')));
        expect(actual, isNot(contains('\n')));
        expect(actual, contains('mihomo/1.19.33 Clash.Meta'));
        expect(forbiddenSubstringsIn(actual), isEmpty);
      }
    },
  );

  test('os segments', () {
    String ua(XcPlatform platform, String os) => buildUserAgent(
      UaParts(
        brandId: 'mg',
        appVersion: '1.0.0',
        build: '1',
        platform: platform,
        osVersion: os,
        arch: 'x64',
        coreVersion: '1.19.33',
      ),
    );
    expect(
      ua(XcPlatform.windows, ''),
      contains('(Windows NT 10.0; Win64; x64;'),
    );
    expect(
      ua(XcPlatform.macos, '15.1.2'),
      contains('(Macintosh; Mac OS X 15_1;'),
    );
    expect(ua(XcPlatform.macos, 'weird'), contains('Mac OS X 0_0'));
    expect(
      ua(XcPlatform.android, '8.1.0'),
      contains('(Android 8.1.0; Mobile;'),
    );
  });

  for (final brand in brands) {
    for (final MapEntry(key: platform, value: archList) in arches.entries) {
      for (final arch in archList) {
        test('$brand × ${platform.name} × $arch', () {
          final ua = buildUserAgent(
            UaParts(
              brandId: brand,
              appVersion: '1.0.0',
              build: '100',
              platform: platform,
              osVersion: osVersions[platform]!,
              arch: arch,
              coreVersion: '1.19.33',
            ),
          );
          expect(ua.startsWith('${brand}Client/1.0.0 ('), isTrue);
          expect(forbiddenSubstringsIn(ua), isEmpty, reason: ua);
          expect(matchProtocolClassName(ua), 'ClashMeta', reason: ua);
          final info = getClientInfo(ua);
          // Longest flag wins: Clash.Meta yields clash, with no version gate.
          expect(info.name, 'clash', reason: ua);
          expect(_gatedClientNames.contains(info.name), isFalse);
          expect(info.version, '1.0.0');
          final forced = getClientInfo(ua, flagParam: 'meta');
          expect(forced.name, 'meta');
          expect(matchProtocolClassName(forced.flag), 'ClashMeta');
        });
      }
    }
  }

  test('port matches known Xboard results', () {
    expect(
      getClientInfo('ClashMetaForAndroid/2.10.1').name,
      'clashmetaforandroid',
    );
    expect(
      getClientInfo('FlClash/v0.8.92 clash-verge Platform/android').name,
      'flclash',
    );
    expect(matchProtocolClassName('sing-box 1.9'), 'SingBox');
    expect(matchProtocolClassName('clash.meta'), 'ClashMeta');
    expect(matchProtocolClassName('clash'), 'Clash');
  });

  test('forbidden list catches what it should', () {
    expect(forbiddenSubstringsIn('Mozilla/5.0 Chrome'), ['mozilla', 'chrome']);
    expect(forbiddenSubstringsIn('Dart/3.13 (dart:io)'), ['dart']);
  });

  const abiLabels = {
    Abi.androidArm64: 'arm64-v8a',
    Abi.androidArm: 'armeabi-v7a',
    Abi.androidX64: 'x86_64',
    Abi.androidIA32: 'x86',
    Abi.windowsX64: 'x64',
    Abi.windowsArm64: 'arm64',
    Abi.windowsIA32: 'x86',
    Abi.macosArm64: 'arm64',
    Abi.macosX64: 'x86_64',
  };
  for (final entry in abiLabels.entries) {
    test('architecture label for ${entry.key}', () {
      expect(currentArch(entry.key), entry.value);
    });
  }
  for (final abi in Abi.values.where((abi) => !abiLabels.containsKey(abi))) {
    test('unsupported architecture $abi remains unknown', () {
      expect(currentArch(abi), 'unknown');
    });
  }
  test('host architecture follows the supported ABI mapping', () {
    expect(currentArch(), abiLabels[Abi.current()] ?? 'unknown');
  });
}
