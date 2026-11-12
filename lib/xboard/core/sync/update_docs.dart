import '../crypto/crypto_exception.dart';
import '../crypto/signed_doc.dart';

/// Compares dotted versions (`1.2.0`, `1.2`, `v1.2.0+5` → build ignored).
int compareSemver(String a, String b) {
  List<int> parts(String v) => [
    for (final part
        in v.trim().replaceFirst(RegExp('^v'), '').split('+').first.split('.'))
      int.tryParse(RegExp(r'^\d+').stringMatch(part) ?? '') ?? 0,
  ];
  final x = parts(a);
  final y = parts(b);
  for (var i = 0; i < 3; i++) {
    final left = i < x.length ? x[i] : 0;
    final right = i < y.length ? y[i] : 0;
    if (left != right) return left.compareTo(right);
  }
  return 0;
}

int _int(Object? value) => switch (value) {
  final num v => v.toInt(),
  final String v => int.tryParse(v) ?? 0,
  _ => 0,
};

class XcNotice {
  final String id;
  final String title;
  final String body;

  /// `info` / `warning` / `critical` as the panel sets it.
  final String level;

  const XcNotice({
    required this.id,
    required this.title,
    required this.body,
    this.level = 'info',
  });

  static XcNotice? fromJson(Object? json) {
    if (json is! Map) return null;
    final title = json['title'];
    final body = json['body'];
    if (title is! String && body is! String) return null;
    return XcNotice(
      id: '${json['id'] ?? ''}',
      title: title is String ? title : '',
      body: body is String ? body : '',
      level: json['level'] is String ? json['level'] as String : 'info',
    );
  }
}

/// The signed update policy of DESIGN §7.1.
class XcPolicy {
  final String brand;
  final int seq;
  final String latest;
  final String minSupported;
  final bool force;
  final String notes;
  final List<String> releaseUrls;
  final XcNotice? notice;

  const XcPolicy({
    required this.brand,
    required this.seq,
    required this.latest,
    required this.minSupported,
    this.force = false,
    this.notes = '',
    this.releaseUrls = const [],
    this.notice,
  });

  /// A newer version exists (show the normal notice when not [mustUpdate]).
  bool hasUpdate(String current) =>
      latest.isNotEmpty && compareSemver(latest, current) > 0;

  /// The forced path: `force` with a newer version, or below min_supported.
  bool mustUpdate(String current) =>
      (force && hasUpdate(current)) ||
      (minSupported.isNotEmpty && compareSemver(current, minSupported) < 0);

  static XcPolicy fromPayload(Map<String, dynamic> json, String brandId) {
    if (json['brand'] != brandId) {
      throw const XcCryptoException(XcCryptoException.brand);
    }
    final urls = json['release_urls'];
    return XcPolicy(
      brand: brandId,
      seq: _int(json['seq']),
      latest: '${json['latest'] ?? ''}',
      minSupported: '${json['min_supported'] ?? ''}',
      force: json['force'] == true,
      notes: json['notes'] is String ? json['notes'] as String : '',
      releaseUrls: [
        if (urls is List)
          for (final url in urls)
            if (url is String && url.startsWith('https://')) url,
      ],
      notice: XcNotice.fromJson(json['notice']),
    );
  }
}

Future<XcPolicy> verifyPolicyDoc(
  Map<String, dynamic> doc, {
  required TrustedKeys ctrlKeys,
  required String brandId,
}) async {
  final verified = await verifySignedDoc(
    doc,
    prefix: SignedDocKind.policy,
    keys: ctrlKeys,
  );
  return XcPolicy.fromPayload(verified.payload, brandId);
}

class ReleaseAsset {
  final List<String> urls;
  final String sha256;
  final int size;
  final String? kind;

  const ReleaseAsset({
    required this.urls,
    required this.sha256,
    required this.size,
    this.kind,
  });
}

/// The CI-signed release facts of DESIGN §7.2. Asset keys:
/// `android-arm64-v8a`, `android-armeabi-v7a`, `android-x86_64`,
/// `windows-x64`, `macos-universal`.
class ReleaseManifest {
  final String brand;
  final String version;
  final int build;
  final int publishedAt;
  final Map<String, ReleaseAsset> assets;

  const ReleaseManifest({
    required this.brand,
    required this.version,
    required this.build,
    required this.publishedAt,
    required this.assets,
  });
}

/// Verifies a release document with the built-in rel keys and checks it is
/// for [brandId] (and [expectedVersion] when the policy names one).
Future<ReleaseManifest> verifyReleaseDoc(
  Map<String, dynamic> doc, {
  required TrustedKeys relKeys,
  required String brandId,
  String? expectedVersion,
}) async {
  final verified = await verifySignedDoc(
    doc,
    prefix: SignedDocKind.release,
    keys: relKeys,
  );
  final json = verified.payload;
  if (json['brand'] != brandId) {
    throw const XcCryptoException(XcCryptoException.brand);
  }
  final version = '${json['version'] ?? ''}';
  if (expectedVersion != null && compareSemver(version, expectedVersion) != 0) {
    throw const XcCryptoException(XcCryptoException.binding, 'version');
  }
  final assets = <String, ReleaseAsset>{};
  final raw = json['assets'];
  if (raw is Map) {
    for (final MapEntry(:key, :value) in raw.entries) {
      if (value is! Map) continue;
      final urls = value['urls'];
      final sha = value['sha256'];
      if (sha is! String || urls is! List) continue;
      assets['$key'] = ReleaseAsset(
        urls: [
          for (final url in urls)
            if (url is String && url.startsWith('https://')) url,
        ],
        sha256: sha.toLowerCase(),
        size: _int(value['size']),
        kind: value['kind'] is String ? value['kind'] as String : null,
      );
    }
  }
  return ReleaseManifest(
    brand: brandId,
    version: version,
    build: _int(json['build']),
    publishedAt: _int(json['published_at']),
    assets: assets,
  );
}
