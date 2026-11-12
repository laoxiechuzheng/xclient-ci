import 'package:fl_clash/common/yaml.dart';
import 'package:fl_clash/xboard/core/sync/config_rewrite.dart';
import 'package:flutter_test/flutter_test.dart';

const _input = '''
mixed-port: 7890
base: &base
  type: url-test
  url: http://www.gstatic.com/generate_204
proxies:
  - {name: "🇯🇵 东京 01", type: ss, server: 192.0.2.10, port: 443, cipher: aes-128-gcm, password: "p"}
proxy-groups:
  - {name: Auto, type: url-test, proxies: ["🇯🇵 东京 01"], url: "http://www.gstatic.com/generate_204", interval: 300}
  - {name: Fallback, type: fallback, proxies: ["🇯🇵 东京 01"], interval: "3600", lazy: false}
  - {name: Balance, type: load-balance, proxies: ["🇯🇵 东京 01"]}
  - {name: Select, type: select, proxies: [Auto, Fallback, Balance]}
  - <<: *base
    name: Merged
    proxies: ["🇯🇵 东京 01"]
rules:
  - DOMAIN,api.example.com,DIRECT
  - MATCH,Select
''';

void main() {
  test('tested groups become lazy with interval >= 1800', () {
    final out =
        loadPlainYaml(
              ConfigRewrite.apply(
                _input,
                directHosts: {
                  'api.example.com',
                  'api-b.example.net',
                  '192.0.2.1',
                  '2001:db8::1',
                },
              ),
            )
            as Map<String, Object?>;
    final groups = {
      for (final g in (out['proxy-groups'] as List).cast<Map>()) g['name']: g,
    };
    expect(groups['Auto']!['lazy'], true);
    expect(groups['Auto']!['interval'], 1800);
    expect(groups['Fallback']!['lazy'], true);
    expect(groups['Fallback']!['interval'], 3600);
    expect(groups['Balance']!['lazy'], true);
    expect(groups['Balance']!['interval'], 1800);
    expect(groups['Select']!.containsKey('lazy'), isFalse);
    expect(groups['Merged']!['type'], 'url-test');
    expect(groups['Merged']!['lazy'], true);
    expect(groups['Merged']!['interval'], 1800);
    expect((out['proxies'] as List).single['name'], '🇯🇵 东京 01');
    expect(out['mixed-port'], 7890);
  });

  test('DIRECT rules for API hosts come first, without duplicates', () {
    final out =
        loadPlainYaml(
              ConfigRewrite.apply(
                _input,
                directHosts: {
                  'api.example.com',
                  'api-b.example.net',
                  '192.0.2.1',
                  '2001:db8::1',
                },
              ),
            )
            as Map<String, Object?>;
    expect(out['rules'], [
      'IP-CIDR,192.0.2.1/32,DIRECT,no-resolve',
      'IP-CIDR6,2001:db8::1/128,DIRECT,no-resolve',
      'DOMAIN,api-b.example.net,DIRECT',
      'DOMAIN,api.example.com,DIRECT',
      'MATCH,Select',
    ]);
  });

  test('a config without rules gets them', () {
    final out =
        loadPlainYaml(
              ConfigRewrite.apply(
                'proxies: []\n',
                directHosts: {'a.example.com'},
              ),
            )
            as Map<String, Object?>;
    expect(out['rules'], ['DOMAIN,a.example.com,DIRECT']);
  });

  test('not a mapping is refused', () {
    expect(() => ConfigRewrite.apply('- a\n- b\n'), throwsFormatException);
    expect(() => ConfigRewrite.apply('a: [\n'), throwsFormatException);
  });

  test('directRule', () {
    expect(
      ConfigRewrite.directRule('[::1]'),
      'IP-CIDR6,::1/128,DIRECT,no-resolve',
    );
    expect(
      ConfigRewrite.directRule('API.Example.com'),
      'DOMAIN,api.example.com,DIRECT',
    );
    expect(ConfigRewrite.directRule(''), isNull);
  });
}
