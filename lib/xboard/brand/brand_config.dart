import 'dart:typed_data';

import '../core/crypto/b64u.dart';
import '../core/crypto/signed_doc.dart';

class ApiEndpointSpec {
  final String url;
  final int weight;

  const ApiEndpointSpec(this.url, {this.weight = 100});

  @override
  bool operator ==(Object other) =>
      other is ApiEndpointSpec && other.url == url && other.weight == weight;

  @override
  int get hashCode => Object.hash(url, weight);

  @override
  String toString() => 'ApiEndpointSpec($url, $weight)';
}

const defaultDohResolvers = [
  'https://dns.alidns.com/dns-query',
  'https://doh.pub/dns-query',
  'https://1.1.1.1/dns-query',
  'https://dns.google/dns-query',
];

/// Defines use comma-separated lists and `kid:b64u` key sets.
class BrandConfig {
  final String brandId;
  final String displayName;
  final List<ApiEndpointSpec> builtinApiEndpoints;
  final List<String> bootstrapSources;

  /// TXT lookup uses `_xc.<name>`.
  final List<String> dohNames;
  final List<String> dohResolvers;
  final Map<String, String> ctrlPubKeys;
  final Map<String, String> relPubKeys;
  final Map<String, String> envPubKeys;

  /// Base64url bootstrap obfuscation key; empty when unset.
  final String obfKey;
  final String panelWebUrl;
  final String supportUrl;

  final String coreVersion;

  final String uaProduct;

  const BrandConfig({
    required this.brandId,
    required this.displayName,
    this.builtinApiEndpoints = const [],
    this.bootstrapSources = const [],
    this.dohNames = const [],
    this.dohResolvers = defaultDohResolvers,
    this.ctrlPubKeys = const {},
    this.relPubKeys = const {},
    this.envPubKeys = const {},
    this.obfKey = '',
    this.panelWebUrl = '',
    this.supportUrl = '',
    this.coreVersion = '1.19.33',
    String? uaProduct,
  }) : uaProduct = uaProduct ?? '${brandId}Client';

  static const _brandId = String.fromEnvironment('XC_BRAND_ID');
  static const _uaProduct = String.fromEnvironment('XC_UA_PRODUCT');
  static const _displayName = String.fromEnvironment('XC_DISPLAY_NAME');
  static const _apiEndpoints = String.fromEnvironment('XC_API_ENDPOINTS');
  static const _sources = String.fromEnvironment('XC_BOOTSTRAP_SOURCES');
  static const _dohNames = String.fromEnvironment('XC_DOH_NAMES');
  static const _dohResolvers = String.fromEnvironment('XC_DOH_RESOLVERS');
  static const _ctrlKeys = String.fromEnvironment('XC_CTRL_PUBKEYS');
  static const _relKeys = String.fromEnvironment('XC_REL_PUBKEYS');
  static const _envKeys = String.fromEnvironment('XC_ENV_PUBKEYS');
  static const _obfKey = String.fromEnvironment('XC_OBF_KEY');
  static const _panelWebUrl = String.fromEnvironment('XC_PANEL_WEB_URL');
  static const _supportUrl = String.fromEnvironment('XC_SUPPORT_URL');
  static const _coreVersion = String.fromEnvironment(
    'XC_CORE_VERSION',
    defaultValue: '1.19.33',
  );

  static const isBranded = _brandId != '';

  factory BrandConfig.fromEnvironment() {
    return BrandConfig.fromDefines(const {
      'XC_BRAND_ID': _brandId,
      'XC_DISPLAY_NAME': _displayName,
      'XC_API_ENDPOINTS': _apiEndpoints,
      'XC_BOOTSTRAP_SOURCES': _sources,
      'XC_DOH_NAMES': _dohNames,
      'XC_DOH_RESOLVERS': _dohResolvers,
      'XC_CTRL_PUBKEYS': _ctrlKeys,
      'XC_REL_PUBKEYS': _relKeys,
      'XC_ENV_PUBKEYS': _envKeys,
      'XC_OBF_KEY': _obfKey,
      'XC_PANEL_WEB_URL': _panelWebUrl,
      'XC_SUPPORT_URL': _supportUrl,
      'XC_CORE_VERSION': _coreVersion,
      'XC_UA_PRODUCT': _uaProduct,
    });
  }

  factory BrandConfig.fromDefines(Map<String, String> defines) {
    String value(String key) => (defines[key] ?? '').trim();
    final brandId = value('XC_BRAND_ID');
    final resolvers = splitList(value('XC_DOH_RESOLVERS'));
    final core = value('XC_CORE_VERSION');
    final product = value('XC_UA_PRODUCT');
    return BrandConfig(
      brandId: brandId.isEmpty ? 'dev' : brandId,
      uaProduct: product.isEmpty ? null : product,
      displayName: value('XC_DISPLAY_NAME').isEmpty
          ? 'XClient'
          : value('XC_DISPLAY_NAME'),
      builtinApiEndpoints: parseEndpoints(value('XC_API_ENDPOINTS')),
      bootstrapSources: [
        for (final url in splitList(value('XC_BOOTSTRAP_SOURCES')))
          if (isHttpsUrl(url)) url,
      ],
      dohNames: splitList(value('XC_DOH_NAMES')),
      dohResolvers: resolvers.isEmpty
          ? defaultDohResolvers
          : [
              for (final url in resolvers)
                if (isHttpsUrl(url)) url,
            ],
      ctrlPubKeys: parseKeyMap(value('XC_CTRL_PUBKEYS')),
      relPubKeys: parseKeyMap(value('XC_REL_PUBKEYS')),
      envPubKeys: parseKeyMap(value('XC_ENV_PUBKEYS')),
      obfKey: value('XC_OBF_KEY'),
      panelWebUrl: value('XC_PANEL_WEB_URL'),
      supportUrl: value('XC_SUPPORT_URL'),
      coreVersion: core.isEmpty ? '1.19.33' : core.replaceFirst('v', ''),
    );
  }

  static List<String> splitList(String value) => [
    for (final item in value.split(RegExp(r'[,\s]+')))
      if (item.trim().isNotEmpty) item.trim(),
  ];

  static List<ApiEndpointSpec> parseEndpoints(String value) {
    final result = <ApiEndpointSpec>[];
    for (final item in splitList(value)) {
      final bar = item.lastIndexOf('|');
      final url = normalizeBaseUrl(bar == -1 ? item : item.substring(0, bar));
      final weight = bar == -1 ? 100 : int.tryParse(item.substring(bar + 1));
      if (url == null || weight == null || weight <= 0) continue;
      result.add(ApiEndpointSpec(url, weight: weight));
    }
    return result;
  }

  static Map<String, String> parseKeyMap(String value) {
    final result = <String, String>{};
    for (final item in splitList(value)) {
      final colon = item.indexOf(':');
      if (colon <= 0) continue;
      result[item.substring(0, colon)] = item.substring(colon + 1);
    }
    return result;
  }

  TrustedKeys get ctrlKeys => TrustedKeys.fromB64u(ctrlPubKeys);

  TrustedKeys get relKeys => TrustedKeys.fromB64u(relPubKeys);

  TrustedKeys get envKeys => TrustedKeys.fromB64u(envPubKeys);

  Uint8List? get obfKeyBytes {
    if (obfKey.isEmpty) return null;
    try {
      final bytes = b64uDecode(obfKey);
      return bytes.length == 32 ? bytes : null;
    } on FormatException {
      return null;
    }
  }
}

bool isHttpsUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
}

String? normalizeBaseUrl(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return null;
  if (uri.hasQuery || uri.hasFragment || uri.userInfo.isNotEmpty) return null;
  var text = uri.toString();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}
