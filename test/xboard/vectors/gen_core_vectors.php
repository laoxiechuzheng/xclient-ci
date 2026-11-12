<?php
// Generates test/xboard/vectors/envelope_v1_core.json: fixed-input vectors
// for DESIGN §4.1 (subscription envelope), §5.1 (bootstrap, plain and
// obfuscated, DoH TXT), §7.1 (policy) and §7.2 (release), plus the standard
// vectors of RFC 8439, draft-irtf-cfrg-xchacha, RFC 8032, RFC 5869 and
// RFC 7748 computed with libsodium and checked against their published
// values. Every key here is a public test key derived from a fixed label.
//
//   php test/xboard/vectors/gen_core_vectors.php
//
// Requires ext-sodium (PHP >= 7.2).

declare(strict_types=1);

if (!extension_loaded('sodium')) {
    fwrite(STDERR, "ext-sodium is required\n");
    exit(1);
}

function b64u(string $bytes): string
{
    return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
}

function seed(string $label): string
{
    return hash('sha256', 'xclient-test/' . $label, true);
}

function jenc($value): string
{
    return json_encode($value, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE);
}

function check(string $name, string $actualHex, string $expectedHex): void
{
    $expected = strtolower(preg_replace('/[^0-9a-fA-F]/', '', $expectedHex));
    if ($actualHex !== $expected) {
        fwrite(STDERR, "standard vector mismatch: $name\n  got  $actualHex\n  want $expected\n");
        exit(1);
    }
}

function signDoc(string $prefix, string $payloadB64, string $kid, string $sk): array
{
    return [
        'v' => 1,
        'kid' => $kid,
        'payload' => $payloadB64,
        'sig' => b64u(sodium_crypto_sign_detached($prefix . $payloadB64, $sk)),
    ];
}

function keypair(string $label): array
{
    $kp = sodium_crypto_sign_seed_keypair(seed($label));
    return [sodium_crypto_sign_secretkey($kp), sodium_crypto_sign_publickey($kp)];
}

$brand = 'demo';
$now = 1793600100;

// ---------------------------------------------------------------- keys
[$envSk, $envPk] = keypair('env-1');
[$ctrlSk, $ctrlPk] = keypair('ctrl-1');
[$ctrl2Sk, $ctrl2Pk] = keypair('ctrl-2');
[$rogueSk, $roguePk] = keypair('rogue');
[$relSk, $relPk] = keypair('rel-1');
$obfKey = seed('obf');

$deviceSk = seed('device-sk');
$devicePk = sodium_crypto_scalarmult_base($deviceSk);
$deviceId = '1b4e28ba-2fa1-41d2-883f-0016d3cca427';
$reqNonce = b64u(substr(seed('req-nonce'), 0, 16));

// ---------------------------------------------------------------- envelope
function seal(array $plain, string $devicePk, string $deviceId, string $reqNonce, string $envSk, string $label, int $iat): array
{
    $ephSk = seed("eph/$label");
    $epk = sodium_crypto_scalarmult_base($ephSk);
    $shared = sodium_crypto_scalarmult($ephSk, $devicePk);
    if (hash_equals(str_repeat("\0", 32), $shared)) {
        throw new RuntimeException('zero shared secret');
    }
    $salt = seed("salt/$label");
    $nonce = substr(seed("nonce/$label"), 0, SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
    $info = "xclient/v1/sub\0" . $epk . $devicePk . $deviceId;
    $key = hash_hkdf('sha256', $shared, 32, $info, $salt);
    $h = b64u(jenc([
        'v' => 1,
        'alg' => 'X25519-HKDF-SHA256-XCHACHA20POLY1305',
        'kid' => 'env-1',
        'epk' => b64u($epk),
        'salt' => b64u($salt),
        'nonce' => b64u($nonce),
        'device_id' => $deviceId,
        'req_nonce' => $reqNonce,
        'iat' => $iat,
        'exp' => $iat + 600,
        'ctype' => 'application/json; xclient-sub',
        'boot_seq' => 7,
        'policy_seq' => 3,
    ]));
    $ct = b64u(sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(jenc($plain), $h, $nonce, $key));
    $sig = b64u(sodium_crypto_sign_detached("xclient-env-v1.$h.$ct", $envSk));
    return ['h' => $h, 'ct' => $ct, 'sig' => $sig];
}

$yaml = <<<YAML
mixed-port: 7890
proxies:
  - {name: "🇯🇵 Tokyo 01", type: ss, server: 192.0.2.10, port: 443, cipher: aes-128-gcm, password: "test"}
  - {name: "🇯🇵 Osaka 02", type: ss, server: 192.0.2.11, port: 443, cipher: aes-128-gcm, password: "test"}
proxy-groups:
  - {name: Auto, type: url-test, proxies: ["🇯🇵 Tokyo 01", "🇯🇵 Osaka 02"], url: "http://www.gstatic.com/generate_204", interval: 300}
  - {name: Select, type: select, proxies: [Auto, "🇯🇵 Tokyo 01", "🇯🇵 Osaka 02"]}
rules:
  - DOMAIN,api.example.com,DIRECT
  - MATCH,Select

YAML;

$plainOk = [
    'status' => 200,
    'headers' => [
        'subscription-userinfo' => 'upload=1024; download=2048; total=10737418240; expire=1794000000',
        'profile-update-interval' => '24',
        'content-disposition' => "attachment;filename*=UTF-8''Example",
    ],
    'body_b64' => b64u($yaml),
];
$plainBlocked = ['status' => 403, 'headers' => new stdClass(), 'body_b64' => ''];

$envOk = seal($plainOk, $devicePk, $deviceId, $reqNonce, $envSk, 'ok', $now - 10);
$envBlocked = seal($plainBlocked, $devicePk, $deviceId, $reqNonce, $envSk, 'blocked', $now - 10);
$envOld = seal($plainOk, $devicePk, $deviceId, $reqNonce, $envSk, 'old', $now - 900);
$envRogue = seal($plainOk, $devicePk, $deviceId, $reqNonce, $rogueSk, 'rogue', $now - 10);

// ---------------------------------------------------------------- bootstrap
function bootPayload(string $brand, int $seq, int $issued, int $expires, bool $mini = false): string
{
    $p = [
        'schema' => 1,
        'brand' => $brand,
        'seq' => $seq,
        'issued_at' => $issued,
        'expires_at' => $expires,
        'api' => [
            ['url' => 'https://api-a.example.com', 'weight' => 100],
            ['url' => 'https://api-b.example.net', 'weight' => 50],
        ],
    ];
    if (!$mini) {
        $p += [
            'sources' => ['https://oss.example.com/boot-demo.json', 'https://cdn.example.org/boot-demo.json'],
            'env_keys' => [['kid' => 'env-2', 'pub' => b64u(keypair('env-2')[1]), 'not_after' => 1890000000]],
            'pins' => ['api-a.example.com' => ['mode' => 'report', 'spki' => ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=']]],
            'poll' => ['fg' => 60, 'bg' => 900],
            'obf' => true,
        ];
    }
    return b64u(jenc($p));
}

function obfuscate(string $payloadB64, string $key, string $label): string
{
    $nonce = substr(seed("obf-nonce/$label"), 0, 24);
    $c = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt($payloadB64, '', $nonce, $key);
    return b64u(jenc(['n' => b64u($nonce), 'c' => b64u($c)]));
}

$bootP = bootPayload($brand, 1730000100, $now - 3600, $now + 86400 * 30);
$boot = signDoc('xclient-boot-v1.', $bootP, 'ctrl-1', $ctrlSk);
$bootObf = $boot;
$bootObf['payload'] = obfuscate($bootP, $obfKey, 'boot');

$bootNewerP = bootPayload($brand, 1730000200, $now - 60, $now + 86400 * 30);
$bootNewer = signDoc('xclient-boot-v1.', $bootNewerP, 'ctrl-2', $ctrl2Sk);

$bootOlder = signDoc('xclient-boot-v1.', bootPayload($brand, 1730000000, $now - 7200, $now + 86400), 'ctrl-1', $ctrlSk);
$bootExpired = signDoc('xclient-boot-v1.', bootPayload($brand, 1730000300, $now - 86400 * 40, $now - 60), 'ctrl-1', $ctrlSk);
$bootOtherBrand = signDoc('xclient-boot-v1.', bootPayload('other', 1730000400, $now, $now + 86400), 'ctrl-1', $ctrlSk);
$bootRogue = signDoc('xclient-boot-v1.', bootPayload($brand, 1730000500, $now, $now + 86400), 'ctrl-1', $rogueSk);
$bootMini = signDoc('xclient-boot-v1.', bootPayload($brand, 1730000250, $now - 60, $now + 86400 * 7, true), 'ctrl-1', $ctrlSk);
$dohTxt = 'xc1:' . b64u(jenc($bootMini));

// ---------------------------------------------------------------- policy, release
$policyP = b64u(jenc([
    'brand' => $brand, 'seq' => 12, 'latest' => '1.2.0', 'min_supported' => '1.1.0', 'force' => false,
    'notes' => 'notes', 'release_urls' => ['https://cdn.example.org/demo-release-v1.2.0.json'],
    'notice' => ['id' => 'n1', 'title' => 'Hello', 'body' => 'World', 'level' => 'info'],
]));
$policy = signDoc('xclient-policy-v1.', $policyP, 'ctrl-1', $ctrlSk);
$policyAsBoot = signDoc('xclient-boot-v1.', $policyP, 'ctrl-1', $ctrlSk);

$relP = b64u(jenc([
    'brand' => $brand, 'version' => '1.2.0', 'build' => 120, 'published_at' => $now,
    'assets' => [
        'android-arm64-v8a' => ['urls' => ['https://cdn.example.org/demo-android-arm64-v8a-v1.2.0.apk'], 'sha256' => str_repeat('ab', 32), 'size' => 123],
        'macos-universal' => ['urls' => ['https://cdn.example.org/demo-macos-universal-v1.2.0.zip'], 'sha256' => str_repeat('cd', 32), 'size' => 456, 'kind' => 'zip'],
    ],
]));
$release = signDoc('xclient-rel-v1.', $relP, 'rel-1', $relSk);

// ---------------------------------------------------------------- standard vectors
$sunscreen = "Ladies and Gentlemen of the class of '99: If I could offer you only one tip for the future, sunscreen would be it.";
$key80 = hex2bin('808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f');
$aad = hex2bin('50515253c0c1c2c3c4c5c6c7');

$rfc8439Nonce = hex2bin('070000004041424344454647');
$rfc8439 = sodium_crypto_aead_chacha20poly1305_ietf_encrypt($sunscreen, $aad, $rfc8439Nonce, $key80);
check('rfc8439 2.8.2', bin2hex($rfc8439),
    'd31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d63dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b3692ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc3ff4def08e4b7a9de576d26586cec64b6116'
    . '1ae10b594f09e26a7e902ecbd0600691');

$xNonce = hex2bin('404142434445464748494a4b4c4d4e4f5051525354555657');
$xchacha = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt($sunscreen, $aad, $xNonce, $key80);
check('xchacha A.3.1', bin2hex($xchacha),
    'bd6d179d3e83d43b9576579493c0e939572a1700252bfaccbed2902c21396cbb731c7f1b0b4aa6440bf3a82f4eda7e39ae64c6708c54c216cb96b72e1213b4522f8c9ba40db5d945b11b69b982c1bb9e3f3fac2bc369488f76b2383565d3fff921f9664c97637da9768812f615c68b13b52e'
    . 'c0875924c1c7987947deafd8780acf49');

$edKp = sodium_crypto_sign_seed_keypair(hex2bin('9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60'));
check('rfc8032 test1 pk', bin2hex(sodium_crypto_sign_publickey($edKp)),
    'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a');
$edSig = sodium_crypto_sign_detached('', sodium_crypto_sign_secretkey($edKp));
check('rfc8032 test1 sig', bin2hex($edSig),
    'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b');

$hkdf = hash_hkdf('sha256', str_repeat("\x0b", 22), 42, hex2bin('f0f1f2f3f4f5f6f7f8f9'), hex2bin('000102030405060708090a0b0c'));
check('rfc5869 case1', bin2hex($hkdf),
    '3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865');

$alice = hex2bin('77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a');
$bobPk = hex2bin('de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f');
check('rfc7748 alice pk', bin2hex(sodium_crypto_scalarmult_base($alice)),
    '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a');
check('rfc7748 shared', bin2hex(sodium_crypto_scalarmult($alice, $bobPk)),
    '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742');

// ---------------------------------------------------------------- output
$out = [
    'comment' => 'Generated by gen_core_vectors.php; public test keys only.',
    'now' => $now,
    'brand' => $brand,
    'keys' => [
        'env' => ['env-1' => b64u($envPk)],
        'ctrl' => ['ctrl-1' => b64u($ctrlPk), 'ctrl-2' => b64u($ctrl2Pk)],
        'rel' => ['rel-1' => b64u($relPk)],
        'obf' => b64u($obfKey),
    ],
    'device' => ['id' => $deviceId, 'sk' => b64u($deviceSk), 'pk' => b64u($devicePk)],
    'envelope' => [
        'req_nonce' => $reqNonce,
        'ok' => $envOk,
        'ok_plain' => $plainOk,
        'blocked' => $envBlocked,
        'old' => $envOld,
        'rogue' => $envRogue,
    ],
    'bootstrap' => [
        'plain' => $boot,
        'obfuscated' => $bootObf,
        'newer_backup_kid' => $bootNewer,
        'older' => $bootOlder,
        'expired' => $bootExpired,
        'other_brand' => $bootOtherBrand,
        'rogue' => $bootRogue,
        'mini' => $bootMini,
        'doh_txt' => $dohTxt,
    ],
    'policy' => ['doc' => $policy, 'as_boot' => $policyAsBoot],
    'release' => $release,
    'standard' => [
        'sunscreen' => $sunscreen,
        'key' => bin2hex($key80),
        'aad' => bin2hex($aad),
        'rfc8439' => ['nonce' => bin2hex($rfc8439Nonce), 'sealed' => bin2hex($rfc8439)],
        'xchacha' => ['nonce' => bin2hex($xNonce), 'sealed' => bin2hex($xchacha)],
        'ed25519' => ['pk' => bin2hex(sodium_crypto_sign_publickey($edKp)), 'msg' => '', 'sig' => bin2hex($edSig)],
        'hkdf' => ['ikm' => str_repeat('0b', 22), 'salt' => '000102030405060708090a0b0c', 'info' => 'f0f1f2f3f4f5f6f7f8f9', 'okm' => bin2hex($hkdf)],
        'x25519' => ['alice_sk' => bin2hex($alice), 'bob_pk' => bin2hex($bobPk), 'shared' => '4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742'],
    ],
];

$path = __DIR__ . '/envelope_v1_core.json';
$encoded = json_encode($out, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) . "\n";
if (in_array('--check', $argv ?? [], true)) {
    if (!is_file($path) || file_get_contents($path) !== $encoded) {
        fwrite(STDERR, "core vectors differ from the committed fixture\n");
        exit(1);
    }
    echo "core vectors match\n";
} else {
    file_put_contents($path, $encoded);
    echo "wrote $path\n";
}
