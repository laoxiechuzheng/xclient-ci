import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'artifacts.dart';

/// The brand.json schema version this tool understands.
const brandSchemaVersion = 1;

/// URL schemes a brand must not claim: they belong to upstream FlClash or to
/// the web.
const reservedUrlSchemes = {
  'clash',
  'clashmeta',
  'flclash',
  'http',
  'https',
  'file',
};

final _brandIdPattern = RegExp(r'^[a-z0-9]{1,16}$');
final _asciiNamePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');
final _reverseDnsPattern = RegExp(
  r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
);
final _guidPattern = RegExp(
  r'^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$',
);
final _urlSchemePattern = RegExp(r'^[a-z][a-z0-9+.-]{1,31}$');
final _kidPattern = RegExp(r'^[A-Za-z0-9._-]{1,64}$');
final _domainPattern = RegExp(
  r'^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
);
final _plainTextPattern = RegExp(r'''^[^"\\<>&\x00-\x1f]+$''');
final _publisherPattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9 ._,()-]{0,63}$');

class BrandConfigException implements Exception {
  final String message;

  const BrandConfigException(this.message);

  @override
  String toString() => 'BrandConfigException: $message';
}

class ApiEndpoint {
  final String url;
  final int weight;

  const ApiEndpoint({required this.url, required this.weight});

  Map<String, Object> toJson() => {'url': url, 'weight': weight};
}

/// One brand's build-time identity, read from `brands/<id>/brand.json`.
///
/// Both [brand_apply.dart] (native identifiers) and the Dart client
/// (`String.fromEnvironment` of [toDefines]) consume this; the key list is
/// documented in tool/xclient/README.md.
class BrandConfig {
  final String brandId;
  final String displayName;
  final String uaProduct;
  final String appIdAndroid;
  final String bundleIdMacos;
  final String windowsAppName;
  final String macosProductName;
  final String windowsAppGuid;
  final String windowsCompany;
  final String publisher;
  final String? publisherUrl;
  final String urlScheme;
  final List<ApiEndpoint> builtinApiEndpoints;
  final List<String> bootstrapSources;
  final List<String> dohNames;
  final List<String> dohResolvers;
  final Map<String, String> ctrlPubKeys;
  final Map<String, String> relPubKeys;
  final Map<String, String> envPubKeys;
  final String obfKey;
  final String panelWebUrl;
  final String supportUrl;
  final String? versionName;
  final List<String> releaseUrlBases;
  final String iconsDir;

  /// The directory brand.json was read from, or null for an in-memory config.
  final String? directory;

  const BrandConfig({
    required this.brandId,
    required this.displayName,
    required this.uaProduct,
    required this.appIdAndroid,
    required this.bundleIdMacos,
    required this.windowsAppName,
    required this.macosProductName,
    required this.windowsAppGuid,
    required this.windowsCompany,
    required this.publisher,
    required this.publisherUrl,
    required this.urlScheme,
    required this.builtinApiEndpoints,
    required this.bootstrapSources,
    required this.dohNames,
    required this.dohResolvers,
    required this.ctrlPubKeys,
    required this.relPubKeys,
    required this.envPubKeys,
    required this.obfKey,
    required this.panelWebUrl,
    required this.supportUrl,
    required this.versionName,
    required this.releaseUrlBases,
    required this.iconsDir,
    this.directory,
  });

  /// Reads and validates `<brandDir>/brand.json`.
  factory BrandConfig.load(String brandDir) {
    final file = File(p.join(brandDir, 'brand.json'));
    if (!file.existsSync()) {
      throw BrandConfigException('${file.path} does not exist');
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException catch (e) {
      throw BrandConfigException('${file.path} is not valid JSON: $e');
    }
    if (json is! Map<String, Object?>) {
      throw BrandConfigException('${file.path} must hold a JSON object');
    }
    final config = BrandConfig.fromJson(json, directory: brandDir);
    final folder = p.basename(p.normalize(p.absolute(brandDir)));
    if (folder != config.brandId) {
      throw BrandConfigException(
        'brand_id "${config.brandId}" does not match its folder "$folder"',
      );
    }
    return config;
  }

  factory BrandConfig.fromJson(Map<String, Object?> json, {String? directory}) {
    final reader = _Reader(json);
    final schema = reader.integer('schema');
    if (schema != brandSchemaVersion) {
      throw BrandConfigException(
        'schema must be $brandSchemaVersion, got $schema',
      );
    }
    final brandId = reader.string('brand_id', pattern: _brandIdPattern);
    final windowsAppName = reader.string(
      'windows_app_name',
      pattern: _asciiNamePattern,
    );
    // It becomes the Dart appName: the autostart entry, WebDAV root and files.
    if (windowsAppName.toLowerCase() == 'flclash') {
      throw const BrandConfigException(
        'windows_app_name "FlClash" is upstream',
      );
    }
    final urlScheme = reader.string('url_scheme', pattern: _urlSchemePattern);
    if (reservedUrlSchemes.contains(urlScheme)) {
      throw BrandConfigException('url_scheme "$urlScheme" is reserved');
    }
    final config = BrandConfig(
      brandId: brandId,
      displayName: reader.string('display_name', pattern: _plainTextPattern),
      uaProduct:
          reader.optionalString('ua_product', pattern: _asciiNamePattern) ??
          '${brandId}Client',
      appIdAndroid: reader.string(
        'app_id_android',
        pattern: _reverseDnsPattern,
      ),
      bundleIdMacos: reader.string(
        'bundle_id_macos',
        pattern: _reverseDnsPattern,
      ),
      windowsAppName: windowsAppName,
      macosProductName:
          reader.optionalString(
            'macos_product_name',
            pattern: _asciiNamePattern,
          ) ??
          windowsAppName,
      windowsAppGuid: reader.string('windows_app_guid', pattern: _guidPattern),
      windowsCompany:
          reader.optionalString(
            'windows_company',
            pattern: _asciiNamePattern,
          ) ??
          'com.xclient',
      publisher: reader.string('publisher', pattern: _publisherPattern),
      publisherUrl: reader.optionalHttpsUrl('publisher_url'),
      urlScheme: urlScheme,
      builtinApiEndpoints: reader.endpoints('builtin_api_endpoints'),
      bootstrapSources: reader.httpsUrls('bootstrap_sources'),
      dohNames: reader.strings('doh_names', pattern: _domainPattern),
      dohResolvers: reader.httpsUrls('doh_resolvers', optional: true),
      ctrlPubKeys: reader.keys('ctrl_pub_keys', allowEmpty: false),
      relPubKeys: reader.keys('rel_pub_keys', allowEmpty: false),
      envPubKeys: reader.keys('env_pub_keys', allowEmpty: true),
      obfKey: reader.key32('obf_key'),
      panelWebUrl: reader.httpsUrl('panel_web_url'),
      supportUrl: reader.httpsUrl('support_url'),
      versionName: reader.optionalString(
        'version_name',
        pattern: RegExp(r'^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$'),
      ),
      releaseUrlBases: reader.httpsUrls('release_url_bases', optional: true),
      iconsDir:
          reader.optionalString(
            'icons_dir',
            pattern: RegExp(r'^[A-Za-z0-9_-]+$'),
          ) ??
          'overlay',
      directory: directory,
    );
    reader.rejectUnknown();
    if (config.versionName != null && !isValidVersion(config.versionName!)) {
      throw const BrandConfigException(
        'version_name is not a supported release version',
      );
    }
    return config;
  }

  /// The Windows data directory path_provider derives from Runner.rc.
  String get windowsDataDir => '$windowsCompany\\$brandId';

  String get windowsExecutable => '$windowsAppName.exe';

  /// Flat string defines for `--dart-define-from-file`, in the format
  /// `lib/xboard/brand/brand_config.dart` (`BrandConfig.fromDefines`) parses:
  /// lists are comma separated, endpoints are `url|weight`, key sets are
  /// `kid:b64u` pairs.
  Map<String, String> toDefines({String? coreVersion, String? version}) {
    final effectiveVersion = version ?? versionName;
    String keys(Map<String, String> map) => [
      for (final MapEntry(:key, :value) in map.entries) '$key:$value',
    ].join(',');
    return {
      'XC_BRAND_ID': brandId,
      'XC_DISPLAY_NAME': displayName,
      'XC_UA_PRODUCT': uaProduct,
      'XC_APP_ID_ANDROID': appIdAndroid,
      'XC_BUNDLE_ID_MACOS': bundleIdMacos,
      'XC_WINDOWS_APP_NAME': windowsAppName,
      'XC_URL_SCHEME': urlScheme,
      'XC_API_ENDPOINTS': [
        for (final endpoint in builtinApiEndpoints)
          '${endpoint.url}|${endpoint.weight}',
      ].join(','),
      'XC_BOOTSTRAP_SOURCES': bootstrapSources.join(','),
      'XC_DOH_NAMES': dohNames.join(','),
      if (dohResolvers.isNotEmpty) 'XC_DOH_RESOLVERS': dohResolvers.join(','),
      'XC_CTRL_PUBKEYS': keys(ctrlPubKeys),
      'XC_REL_PUBKEYS': keys(relPubKeys),
      'XC_ENV_PUBKEYS': keys(envPubKeys),
      'XC_OBF_KEY': obfKey,
      'XC_PANEL_WEB_URL': panelWebUrl,
      'XC_SUPPORT_URL': supportUrl,
      'XC_CORE_VERSION': ?coreVersion,
      if (effectiveVersion != null) ...{
        'XC_VERSION_NAME': effectiveVersion,
        'XC_BUILD_NUMBER': '${buildNumberFor(effectiveVersion)}',
      },
    };
  }
}

/// Decodes unpadded base64url (padding and standard base64 are accepted too).
List<int> decodeB64u(String value) {
  var normalized = value.trim().replaceAll('+', '-').replaceAll('/', '_');
  normalized = normalized.replaceAll('=', '');
  final remainder = normalized.length % 4;
  if (remainder == 1) {
    throw const FormatException('invalid base64url length');
  }
  if (remainder != 0) {
    normalized = normalized.padRight(normalized.length + 4 - remainder, '=');
  }
  return base64Url.decode(normalized);
}

/// Encodes as unpadded base64url (`b64u` in docs/DESIGN.md §1).
String encodeB64u(List<int> bytes) {
  return base64Url.encode(bytes).replaceAll('=', '');
}

class _Reader {
  final Map<String, Object?> json;
  final Set<String> _seen = {};

  _Reader(this.json);

  Object? _value(String key) {
    _seen.add(key);
    return json[key];
  }

  Never _fail(String key, String problem) {
    throw BrandConfigException('$key $problem');
  }

  int integer(String key) {
    final value = _value(key);
    if (value is! int) _fail(key, 'must be an integer');
    return value;
  }

  String string(String key, {RegExp? pattern}) {
    final value = optionalString(key, pattern: pattern);
    if (value == null) _fail(key, 'is required');
    return value;
  }

  String? optionalString(String key, {RegExp? pattern}) {
    final value = _value(key);
    if (value == null) return null;
    if (value is! String || value.isEmpty) {
      _fail(key, 'must be a non-empty string');
    }
    if (pattern != null && !pattern.hasMatch(value)) {
      _fail(key, 'has an invalid value "$value"');
    }
    return value;
  }

  String httpsUrl(String key) {
    final value = string(key);
    _checkHttps(key, value);
    return value;
  }

  String? optionalHttpsUrl(String key) {
    final value = optionalString(key);
    if (value != null) _checkHttps(key, value);
    return value;
  }

  void _checkHttps(String key, String value) {
    final uri = Uri.tryParse(value);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        RegExp(r'[\s,|]').hasMatch(value)) {
      _fail(key, 'must be an https:// URL without , | or spaces: "$value"');
    }
  }

  List<String> strings(String key, {RegExp? pattern, bool optional = false}) {
    final value = _value(key);
    if (value == null && optional) return const [];
    if (value is! List) _fail(key, 'must be a list');
    return [
      for (final (index, item) in value.indexed)
        if (item is String && (pattern == null || pattern.hasMatch(item)))
          item
        else
          _fail('$key[$index]', 'has an invalid value "$item"'),
    ];
  }

  List<String> httpsUrls(String key, {bool optional = false}) {
    final urls = strings(key, optional: optional);
    for (final (index, url) in urls.indexed) {
      _checkHttps('$key[$index]', url);
    }
    return urls;
  }

  List<ApiEndpoint> endpoints(String key) {
    final value = _value(key);
    if (value is! List || value.isEmpty) {
      _fail(key, 'must be a non-empty list');
    }
    return [
      for (final (index, item) in value.indexed)
        if (item is Map<String, Object?>)
          _endpoint('$key[$index]', item)
        else
          _fail('$key[$index]', 'must be an object {url, weight}'),
    ];
  }

  ApiEndpoint _endpoint(String key, Map<String, Object?> item) {
    final url = item['url'];
    final weight = item['weight'] ?? 100;
    if (url is! String) _fail('$key.url', 'is required');
    _checkHttps('$key.url', url);
    if (weight is! int || weight < 0) {
      _fail('$key.weight', 'must be a non-negative integer');
    }
    final unknown = item.keys.toSet().difference({'url', 'weight'});
    if (unknown.isNotEmpty) _fail(key, 'has unknown keys $unknown');
    return ApiEndpoint(url: url, weight: weight);
  }

  Map<String, String> keys(String key, {required bool allowEmpty}) {
    final value = _value(key);
    if (value is! Map<String, Object?>) {
      _fail(key, 'must be an object {kid: b64u public key}');
    }
    if (value.isEmpty && !allowEmpty) _fail(key, 'must not be empty');
    final result = <String, String>{};
    for (final MapEntry(key: kid, value: pub) in value.entries) {
      if (!_kidPattern.hasMatch(kid) || pub is! String || !_is32Bytes(pub)) {
        _fail('$key.$kid', 'must map a kid to a 32-byte b64u key');
      }
      result[kid] = pub;
    }
    return result;
  }

  String key32(String key) {
    final value = string(key);
    if (!_is32Bytes(value)) _fail(key, 'must be 32 bytes of b64u');
    return value;
  }

  bool _is32Bytes(String value) {
    try {
      return decodeB64u(value).length == 32;
    } on FormatException {
      return false;
    }
  }

  void rejectUnknown() {
    final unknown = json.keys
        .where((key) => !_seen.contains(key) && !key.startsWith('_'))
        .toList();
    if (unknown.isNotEmpty) {
      throw BrandConfigException('unknown keys: ${unknown.join(', ')}');
    }
  }
}
