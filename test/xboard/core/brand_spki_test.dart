import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/net/spki.dart';
import 'package:flutter_test/flutter_test.dart';

/// A throwaway self-signed P-256 certificate for `api.example.com`; its SPKI
/// pin was computed with `openssl x509 -pubkey | openssl pkey -pubin
/// -outform DER | openssl dgst -sha256 -binary | base64`.
const _certB64 =
    'MIIBijCCAS+gAwIBAgIUAXnsmVPmlZaPRxuD/SO0SEG2ipIwCgYIKoZIzj0EAwIwGjEYMBYG'
    'A1UEAwwPYXBpLmV4YW1wbGUuY29tMB4XDTI2MTEwMjA3MzQ1NloXDTM2MTAzMDA3MzQ1Nlow'
    'GjEYMBYGA1UEAwwPYXBpLmV4YW1wbGUuY29tMFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE'
    'BoK+PmDPbjLkhRlU+tqmP0ShHskxJnIOmA1bgWl1HWja0onWutY6pLJh93aH1D/Sqs0yYTeL'
    'OLOpLrx3iRI1TKNTMFEwHQYDVR0OBBYEFOrc7NA9V15T4SWBH1EyCvQg0do+MB8GA1UdIwQY'
    'MBaAFOrc7NA9V15T4SWBH1EyCvQg0do+MA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwID'
    'SQAwRgIhAKBa5r8LKohc+jLNhHz/Du6MmCXXJlrLOpBNSTz+xPtJAiEA2DNbMkjH2oSwbYzj'
    'D9TW5hBaeL+NEfU+jQpFU5E9dM8=';
const _certPin = 'bolxcFDmhp1KQ4RLX2kqGfosKXIrNnu6s+r6J9OhNBw=';

void main() {
  group('SPKI', () {
    test('pin of a certificate matches openssl', () async {
      final der = Uint8List.fromList(base64.decode(_certB64));
      expect(await spkiSha256Base64(der), _certPin);
      expect(extractSpki(der).first, 0x30);
    });

    test('garbage is refused', () {
      expect(
        () => extractSpki(Uint8List.fromList([0x30, 0x82])),
        throwsFormatException,
      );
      expect(
        () => extractSpki(Uint8List.fromList([0x02, 0x01, 0x00])),
        throwsFormatException,
      );
    });

    test('pin policy from the bootstrap', () {
      final policy = PinPolicy.fromJson({
        'API.example.com': {
          'mode': 'enforce',
          'spki': [_certPin],
        },
        'b.example.com': {'mode': 'off', 'spki': []},
        'c.example.com': {
          'mode': 'report',
          'spki': ['x'],
        },
      });
      expect(policy.forHost('api.example.com')!.mode, PinMode.enforce);
      expect(policy.forHost('api.example.com')!.spki, {_certPin});
      expect(policy.forHost('b.example.com'), isNull);
      expect(policy.forHost('c.example.com')!.mode, PinMode.report);
      expect(policy.forHost('d.example.com'), isNull);
      expect(PinPolicy.fromJson(null).isEmpty, isTrue);
    });
  });

  group('BrandConfig.fromDefines', () {
    test('parses the define schema', () {
      final brand = BrandConfig.fromDefines({
        'XC_BRAND_ID': '98k',
        'XC_DISPLAY_NAME': 'Demo 加速器',
        'XC_API_ENDPOINTS':
            'https://api.example.com|100,https://api2.example.net/panel/|40,http://plain.example.com,https://bad|x',
        'XC_BOOTSTRAP_SOURCES':
            'https://oss.example.com/b.json, http://insecure.example.com/b.json',
        'XC_DOH_NAMES': 'example.com',
        'XC_CTRL_PUBKEYS':
            'ctrl-1:Ha1GrxnY20Ptq0cigMKDViPMPh-PUX9IS7fufLUPi30,ctrl-2:aC52eIcXLy7rv1qV4PbwX5CMjwFd2BiAT_gZ5C8INaQ',
        'XC_REL_PUBKEYS': 'rel-1:WsesMPLpTn0jw_t4FkYXL_4K75jfYHhNWTtSmq22Cf8',
        'XC_ENV_PUBKEYS': '',
        'XC_OBF_KEY': 'MJOE4us23WRs18soUCcvgiGrO3OTKs81PuvVAXis-mA',
        'XC_PANEL_WEB_URL': 'https://www.example.com',
        'XC_SUPPORT_URL': 'https://www.example.com/#/ticket',
        'XC_CORE_VERSION': 'v1.19.33',
      });
      expect(brand.brandId, '98k');
      expect(brand.uaProduct, '98kClient');
      expect(brand.builtinApiEndpoints, const [
        ApiEndpointSpec('https://api.example.com'),
        ApiEndpointSpec('https://api2.example.net/panel', weight: 40),
      ]);
      expect(brand.bootstrapSources, ['https://oss.example.com/b.json']);
      expect(brand.dohResolvers, defaultDohResolvers);
      expect(brand.ctrlKeys.kids.toSet(), {'ctrl-1', 'ctrl-2'});
      expect(brand.relKeys.kids.single, 'rel-1');
      expect(brand.envKeys.isEmpty, isTrue);
      expect(brand.obfKeyBytes!.length, 32);
      expect(brand.coreVersion, '1.19.33');
    });

    test('an unbranded build still has safe defaults', () {
      final brand = BrandConfig.fromDefines(const {});
      expect(brand.brandId, 'dev');
      expect(brand.builtinApiEndpoints, isEmpty);
      expect(brand.obfKeyBytes, isNull);
      expect(
        BrandConfig.fromDefines(const {'XC_UA_PRODUCT': 'abcClient'}).uaProduct,
        'abcClient',
      );
    });
  });
}
