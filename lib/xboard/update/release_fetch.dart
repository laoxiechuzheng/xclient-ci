import 'dart:async';
import 'dart:convert';

import '../core/crypto/crypto_exception.dart';
import '../core/crypto/signed_doc.dart';
import '../core/log.dart';
import '../core/sync/update_docs.dart';
import '../core/ua.dart';
import 'update_exception.dart';
import 'update_http.dart';
import 'version.dart';

const _maxReleaseDocBytes = 512 * 1024;

/// Tries URL fallbacks, verifying the offline key, brand and policy's exact latest version.
/// Verification refusals remain releaseInvalid when no source verifies.
Future<ReleaseManifest> fetchReleaseManifest({
  required List<String> urls,
  required UpdateHttp http,
  required TrustedKeys relKeys,
  required String brandId,
  required String expectedVersion,
  Duration timeout = const Duration(seconds: 20),
}) async {
  if (urls.isEmpty) {
    throw const XcUpdateException(XcUpdateException.noReleaseUrls);
  }
  XcUpdateException? refused;
  for (final url in urls) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.scheme != 'https') continue;
    final Object? json;
    try {
      json = jsonDecode(await _readSmall(http, uri).timeout(timeout));
    } catch (error) {
      xcLog(
        'release doc fetch failed (${uri.host}): ${error.runtimeType}',
        warn: true,
      );
      continue;
    }
    if (json is! Map<String, dynamic>) {
      refused = const XcUpdateException(
        XcUpdateException.releaseInvalid,
        'not an object',
      );
      continue;
    }
    try {
      final manifest = await verifyReleaseDoc(
        json,
        relKeys: relKeys,
        brandId: brandId,
        expectedVersion: expectedVersion,
      );
      final expected = AppVersion.tryParse(expectedVersion);
      final actual = AppVersion.tryParse(manifest.version);
      if (expected == null ||
          actual == null ||
          actual.compareSemver(expected) != 0 ||
          (expected.build != null &&
              expected.build != (actual.build ?? manifest.build))) {
        throw const XcCryptoException(XcCryptoException.binding, 'version');
      }
      return manifest;
    } on XcCryptoException catch (error) {
      xcLog('release doc refused (${uri.host}): ${error.code}', warn: true);
      refused = XcUpdateException(XcUpdateException.releaseInvalid, error.code);
    }
  }
  throw refused ?? const XcUpdateException(XcUpdateException.releaseFetch);
}

Future<String> _readSmall(UpdateHttp http, Uri uri) async {
  final response = await http.get(uri);
  if (response.statusCode != 200) {
    response.cancel();
    throw XcUpdateException(
      XcUpdateException.releaseFetch,
      'HTTP ${response.statusCode}',
    );
  }
  final bytes = <int>[];
  await for (final chunk in response.body) {
    bytes.addAll(chunk);
    if (bytes.length > _maxReleaseDocBytes) {
      response.cancel();
      throw const XcUpdateException(XcUpdateException.releaseFetch, 'too big');
    }
  }
  return utf8.decode(bytes);
}

List<String> assetKeysFor(XcPlatform platform, String arch) =>
    switch (platform) {
      XcPlatform.android => ['android-$arch'],
      // Windows on Arm runs the x64 build under emulation.
      XcPlatform.windows => const ['windows-x64'],
      XcPlatform.macos => const ['macos-universal'],
    };

({String key, ReleaseAsset asset}) selectAsset(
  ReleaseManifest manifest,
  XcPlatform platform,
  String arch,
) {
  for (final key in assetKeysFor(platform, arch)) {
    final asset = manifest.assets[key];
    if (asset != null &&
        asset.urls.isNotEmpty &&
        asset.size > 0 &&
        RegExp(r'^[0-9a-f]{64}$').hasMatch(asset.sha256)) {
      return (key: key, asset: asset);
    }
  }
  throw XcUpdateException(XcUpdateException.noAsset, '${platform.name}/$arch');
}

/// Rejects downgrades and reinstall loops by comparing semver, then build.
void ensureNewer(ReleaseManifest manifest, AppVersion current) {
  final release = AppVersion.tryParse(
    manifest.version,
    build: manifest.build > 0 ? manifest.build : null,
  );
  if (release == null || release.compareTo(current) <= 0) {
    throw XcUpdateException(XcUpdateException.notNewer, manifest.version);
  }
}
