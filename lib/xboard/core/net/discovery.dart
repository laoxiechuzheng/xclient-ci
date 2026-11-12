import 'dart:io';

import '../../brand/brand_config.dart';
import '../crypto/crypto_exception.dart';

class DiscoveryApiPool {
  final String id;
  final bool enabled;
  final List<ApiEndpointSpec> endpoints;

  const DiscoveryApiPool(this.id, this.enabled, this.endpoints);
}

class DiscoveryOssPool {
  final String id;
  final bool enabled;
  final List<String> urls;

  const DiscoveryOssPool(this.id, this.enabled, this.urls);
}

class DiscoverySnapshot {
  final List<DiscoveryApiPool> apiPools;
  final List<DiscoveryOssPool> ossPools;
  final List<String> dohNames;
  final List<String> dohResolvers;

  const DiscoverySnapshot({
    required this.apiPools,
    required this.ossPools,
    required this.dohNames,
    required this.dohResolvers,
  });

  List<ApiEndpointSpec> get api {
    final seen = <String>{};
    return [
      for (final pool in apiPools)
        if (pool.enabled)
          for (final endpoint in pool.endpoints)
            if (seen.add(endpoint.url)) endpoint,
    ];
  }

  List<String> get sources => {
    for (final pool in ossPools)
      if (pool.enabled) ...pool.urls,
  }.toList();

  static DiscoverySnapshot parse(Object? value) {
    if (value is! Map || value['version'] is! int || value['version'] != 1) {
      _invalid();
    }
    final apiPools = <DiscoveryApiPool>[];
    final apiIds = <String>{};
    for (final raw in _list(value['api_pools'], 32)) {
      final pool = _pool(raw, apiIds);
      final endpoints = <ApiEndpointSpec>[];
      for (final item in _list(pool['endpoints'], 32)) {
        if (item is! Map) _invalid();
        final weight = item['weight'];
        if (weight is! int || weight < 1 || weight > 1000) _invalid();
        endpoints.add(
          ApiEndpointSpec(_url(item['url'], api: true), weight: weight),
        );
      }
      apiPools.add(
        DiscoveryApiPool(
          pool['id'] as String,
          pool['enabled'] as bool,
          List.unmodifiable(endpoints),
        ),
      );
    }
    final ossPools = <DiscoveryOssPool>[];
    final ossIds = <String>{};
    for (final raw in _list(value['oss_pools'], 32)) {
      final pool = _pool(raw, ossIds);
      final urls = [for (final url in _list(pool['urls'], 32)) _url(url)];
      ossPools.add(
        DiscoveryOssPool(
          pool['id'] as String,
          pool['enabled'] as bool,
          List.unmodifiable(urls),
        ),
      );
    }
    final doh = value['doh'];
    if (doh is! Map) _invalid();
    return DiscoverySnapshot(
      apiPools: List.unmodifiable(apiPools),
      ossPools: List.unmodifiable(ossPools),
      dohNames: List.unmodifiable([
        for (final name in _list(doh['names'], 32)) _name(name),
      ]),
      dohResolvers: List.unmodifiable([
        for (final url in _list(doh['resolvers'], 16)) _url(url),
      ]),
    );
  }

  static Never _invalid() =>
      throw const XcCryptoException(XcCryptoException.badFormat, 'discovery');

  static List _list(Object? value, int limit) {
    if (value is! List || value.length > limit) _invalid();
    return value;
  }

  static Map _pool(Object? value, Set<String> ids) {
    if (value is! Map) _invalid();
    final id = value['id'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(id) ||
        !ids.add(id) ||
        value['enabled'] is! bool) {
      _invalid();
    }
    return value;
  }

  static String _url(Object? value, {bool api = false}) {
    if (value is! String ||
        RegExp(
          r'[\s\x00-\x1f\x7f\u0085\uFEFF]',
          unicode: true,
        ).hasMatch(value)) {
      _invalid();
    }
    final Uri? uri;
    try {
      uri = Uri.tryParse(value);
    } on FormatException {
      _invalid();
    }
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !_host(uri.host) ||
        uri.port < 0 ||
        uri.port > 65535 ||
        RegExp(r'^https://[^/?#]*@', caseSensitive: false).hasMatch(value) ||
        uri.authority.contains('@') ||
        uri.hasFragment ||
        (api && uri.hasQuery)) {
      _invalid();
    }
    return api ? value.replaceFirst(RegExp(r'/+$'), '') : value;
  }

  static bool _host(String host) {
    if (InternetAddress.tryParse(host) != null) return true;
    final label = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
    return host.length <= 253 &&
        host.split('.').every((part) => label.hasMatch(part));
  }

  static String _name(Object? value) {
    if (value is! String) _invalid();
    var name = value.toLowerCase();
    if (name.endsWith('.')) name = name.substring(0, name.length - 1);
    final plain = name.startsWith('_xc.') ? name.substring(4) : name;
    final label = RegExp(r'^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$');
    if (plain.isEmpty ||
        (name.startsWith('_xc.') ? name.length : name.length + 4) > 253 ||
        plain.split('.').any((part) => !label.hasMatch(part))) {
      _invalid();
    }
    return name;
  }
}
