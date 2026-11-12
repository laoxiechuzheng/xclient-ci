import 'dart:io';

import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/common/yaml_writer.dart';

/// Disables core-wide probe sweeps and keeps panel traffic DIRECT under TUN.
abstract final class ConfigRewrite {
  static const minGroupInterval = 1800;
  static const testedGroupTypes = {'url-test', 'fallback', 'load-balance'};

  static String apply(String yaml, {Set<String> directHosts = const {}}) {
    final Object? parsed;
    try {
      parsed = loadPlainYaml(yaml);
    } on Exception catch (e) {
      throw FormatException('config: not yaml ($e)');
    }
    if (parsed is! Map<String, Object?>) {
      throw const FormatException('config: not a mapping');
    }
    return writeYaml(rewrite(parsed, directHosts: directHosts));
  }

  static Map<String, Object?> rewrite(
    Map<String, Object?> config, {
    Set<String> directHosts = const {},
  }) {
    final result = Map<String, Object?>.of(config);
    final groups = result['proxy-groups'];
    if (groups is List) {
      result['proxy-groups'] = [for (final group in groups) _group(group)];
    }
    final rules = result['rules'];
    final existing = [
      if (rules is List)
        for (final rule in rules) rule,
    ];
    final present = {
      for (final rule in existing)
        if (rule is String) rule.replaceAll(' ', ''),
    };
    final hosts = directHosts.toList()..sort();
    result['rules'] = [
      for (final host in hosts)
        if (directRule(host) case final rule?)
          if (!present.contains(rule.replaceAll(' ', ''))) rule,
      ...existing,
    ];
    return result;
  }

  static Object? _group(Object? group) {
    if (group is! Map) return group;
    final type = '${group['type']}'.toLowerCase();
    if (!testedGroupTypes.contains(type)) return group;
    final next = Map<String, Object?>.of(group.cast<String, Object?>());
    final interval = switch (next['interval']) {
      final num v => v.toInt(),
      final String v => int.tryParse(v.trim()) ?? 0,
      _ => 0,
    };
    next['lazy'] = true;
    next['interval'] = interval < minGroupInterval
        ? minGroupInterval
        : interval;
    return next;
  }

  static String? directRule(String host) {
    var value = host.trim().toLowerCase();
    if (value.startsWith('[') && value.endsWith(']')) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isEmpty || value.contains(',')) return null;
    final ip = InternetAddress.tryParse(value);
    if (ip == null) return 'DOMAIN,$value,DIRECT';
    return ip.type == InternetAddressType.IPv6
        ? 'IP-CIDR6,${ip.address}/128,DIRECT,no-resolve'
        : 'IP-CIDR,${ip.address}/32,DIRECT,no-resolve';
  }
}
