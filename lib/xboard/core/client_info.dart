import 'package:device_info_plus/device_info_plus.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'ua.dart';

class ClientInfo {
  final XcPlatform platform;
  final String arch;
  final String appVersion;
  final String build;

  final String osVersion;

  /// Use the device model, never the user's computer name.
  final String deviceName;

  const ClientInfo({
    required this.platform,
    required this.arch,
    required this.appVersion,
    required this.build,
    required this.osVersion,
    required this.deviceName,
  });

  factory ClientInfo.fromPackageInfo(
    PackageInfo package, {
    required XcPlatform platform,
    required String arch,
    String osVersion = '',
    String deviceName = '',
    String canonicalVersion = const String.fromEnvironment('XC_VERSION_NAME'),
    String canonicalBuild = const String.fromEnvironment('XC_BUILD_NUMBER'),
  }) {
    final compiled = canonicalVersion.isNotEmpty || canonicalBuild.isNotEmpty;
    if (compiled) {
      final version = _canonicalVersion.firstMatch(canonicalVersion);
      final build = int.tryParse(canonicalBuild);
      final prerelease = version?.group(4)?.split('.') ?? const <String>[];
      if (version == null ||
          version.end != canonicalVersion.length ||
          [1, 2, 3].any((part) => int.tryParse(version.group(part)!) == null) ||
          prerelease.any(
            (part) =>
                part.length > 1 &&
                part.startsWith('0') &&
                RegExp(r'^[0-9]+$').hasMatch(part),
          ) ||
          build == null ||
          build <= 0 ||
          build.toString() != canonicalBuild ||
          build > 2147483647 - 4000) {
        throw const FormatException('Invalid compiled client identity');
      }
    }
    return ClientInfo(
      platform: platform,
      arch: arch,
      appVersion: compiled ? canonicalVersion : package.version,
      build: compiled ? canonicalBuild : package.buildNumber,
      osVersion: osVersion,
      deviceName: deviceName.isEmpty ? platform.name : deviceName,
    );
  }

  static final _canonicalVersion = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$',
  );

  UaParts uaParts({
    required String brandId,
    required String coreVersion,
    String? product,
  }) => UaParts(
    product: product,
    brandId: brandId,
    appVersion: appVersion,
    build: build,
    platform: platform,
    osVersion: osVersion,
    arch: arch,
    coreVersion: coreVersion,
  );

  static Future<ClientInfo> detect() async {
    final package = await PackageInfo.fromPlatform();
    final platform = currentPlatform();
    final plugin = DeviceInfoPlugin();
    var osVersion = '';
    var deviceName = '';
    try {
      switch (platform) {
        case XcPlatform.android:
          final info = await plugin.androidInfo;
          osVersion = info.version.release;
          deviceName = '${info.manufacturer} ${info.model}'.trim();
        case XcPlatform.macos:
          final info = await plugin.macOsInfo;
          osVersion =
              '${info.majorVersion}.${info.minorVersion}.${info.patchVersion}';
          deviceName = info.model;
        case XcPlatform.windows:
          final info = await plugin.windowsInfo;
          osVersion = info.displayVersion;
          deviceName = 'Windows ${info.displayVersion}'.trim();
      }
    } catch (_) {}
    return ClientInfo.fromPackageInfo(
      package,
      platform: platform,
      arch: currentArch(),
      osVersion: osVersion,
      deviceName: deviceName,
    );
  }
}
