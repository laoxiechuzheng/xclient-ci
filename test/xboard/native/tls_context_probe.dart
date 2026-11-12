import 'dart:async';
import 'dart:convert';
import 'dart:io';

class ProbeRefused implements Exception {
  const ProbeRefused(this.code);
  final String code;
}

void requireProbe(bool value, String code) {
  if (!value) throw ProbeRefused(code);
}

List<int> certificateDerFromPem(String pem) {
  final matches = RegExp(
    r'-----BEGIN CERTIFICATE-----([\s\S]*?)-----END CERTIFICATE-----',
  ).allMatches(pem).toList();
  requireProbe(matches.length == 1, 'one_server_certificate_required');
  final match = matches.single;
  requireProbe(
    pem.substring(0, match.start).trim().isEmpty &&
        pem.substring(match.end).trim().isEmpty,
    'certificate_pem_scope',
  );
  final der = base64.decode(match.group(1)!.replaceAll(RegExp(r'\s'), ''));
  requireProbe(der.isNotEmpty && der.first == 0x30, 'certificate_der_invalid');
  return der;
}

Map<String, bool> certificateObservation(
  X509Certificate certificate,
  List<int> expectedDer, {
  DateTime? now,
}) {
  final instant = now ?? DateTime.now();
  final der = certificate.der;
  final started = !instant.isBefore(certificate.startValidity);
  final unexpired = !instant.isAfter(certificate.endValidity);
  return {
    'der_matches':
        der.length == expectedDer.length &&
        List.generate(
          der.length,
          (index) => index,
        ).every((index) => der[index] == expectedDer[index]),
    'valid_from_reached': started,
    'valid_to_not_passed': unexpired,
    'valid_now': started && unexpired,
  };
}

Map<String, Object?> safeTlsError(Object error) {
  final String kind;
  final int? osCode;
  String? message;
  switch (error) {
    case TlsException():
      kind = error is HandshakeException
          ? 'handshake'
          : error is CertificateException
          ? 'certificate'
          : 'tls';
      osCode = error.osError?.errorCode;
      message = '${error.message} ${error.osError?.message ?? ''}';
    case SocketException():
      kind = 'socket';
      osCode = error.osError?.errorCode;
    case TimeoutException():
      kind = 'timeout';
      osCode = null;
    case FileSystemException():
      kind = 'fileSystem';
      osCode = error.osError?.errorCode;
    case FormatException():
      kind = 'format';
      osCode = null;
    case ProbeRefused():
      kind = 'probeRefused';
      osCode = null;
    default:
      kind = 'unknown';
      osCode = null;
  }
  final lower = message?.toLowerCase() ?? '';
  final reason = switch (lower) {
    _ when lower.contains('hostname') || lower.contains('host name') =>
      'hostname',
    _ when lower.contains('expired') => 'expired',
    _ when lower.contains('not yet valid') => 'notYetValid',
    _ when lower.contains('self signed') || lower.contains('self-signed') =>
      'selfSigned',
    _ when lower.contains('issuer') || lower.contains('unknown ca') => 'issuer',
    _
        when lower.contains('certificate_verify_failed') ||
            lower.contains('certificate verify failed') =>
      'certificateVerify',
    _ when lower.contains('protocol version') => 'protocolVersion',
    _ when lower.contains('cipher') => 'cipher',
    _ => 'unknown',
  };
  return {
    'exception_kind': kind,
    'os_error_code': osCode,
    'tls_reason': reason,
  };
}

Future<Map<String, Object?>> probeConnection(
  int port,
  List<int> expectedDer, {
  SecurityContext? context,
}) async {
  ConnectionTask<SecureSocket>? task;
  SecureSocket? socket;
  var cancelled = false;
  var badCertificates = 0;
  Map<String, bool>? badCertificate;
  Map<String, bool>? peerCertificate;
  try {
    final pending = SecureSocket.startConnect(
      'localhost',
      port,
      context: context,
      onBadCertificate: (certificate) {
        badCertificates++;
        badCertificate = certificateObservation(certificate, expectedDer);
        return false;
      },
      supportedProtocols: const ['http/1.1'],
    );
    unawaited(
      pending.then((late) {
        if (!cancelled) return;
        late.cancel();
        unawaited(
          late.socket.then<void>((value) => value.destroy(), onError: (_) {}),
        );
      }, onError: (_) {}),
    );
    task = await pending.timeout(const Duration(seconds: 4));
    final established = task.socket;
    unawaited(
      established.then<void>((late) {
        if (cancelled) late.destroy();
      }, onError: (_) {}),
    );
    socket = await established.timeout(const Duration(seconds: 4));
    final peer = socket.peerCertificate;
    if (peer != null) {
      peerCertificate = certificateObservation(peer, expectedDer);
    }
    socket.write(
      'GET /tls-probe HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n',
    );
    await socket.flush().timeout(const Duration(seconds: 2));
    final bytes = <int>[];
    await for (final chunk in socket.timeout(const Duration(seconds: 3))) {
      bytes.addAll(chunk);
      requireProbe(bytes.length <= 4096, 'response_limit');
    }
    final response = ascii.decode(bytes);
    requireProbe(
      response.startsWith('HTTP/1.0 200 ') &&
          response.endsWith('\r\n\r\ntls-probe-ok'),
      'http_response_invalid',
    );
    return {
      'connected': true,
      'http_ok': true,
      'bad_certificate_callbacks': badCertificates,
      'bad_certificate': ?badCertificate,
      'peer_certificate': ?peerCertificate,
    };
  } catch (error) {
    return {
      'connected': false,
      'http_ok': false,
      'bad_certificate_callbacks': badCertificates,
      'bad_certificate': ?badCertificate,
      'peer_certificate': ?peerCertificate,
      ...safeTlsError(error),
    };
  } finally {
    cancelled = true;
    task?.cancel();
    socket?.destroy();
  }
}

Future<Map<String, dynamic>> loadConfig(List<String> args) async {
  final env = Platform.environment;
  requireProbe(
    Platform.isMacOS &&
        env['GITHUB_ACTIONS'] == 'true' &&
        env['RUNNER_ENVIRONMENT'] == 'github-hosted' &&
        env['RUNNER_OS'] == 'macOS',
    'github_hosted_macos_required',
  );
  requireProbe(args.length == 2, 'fixed_arguments_required');
  final file = File(args[0]);
  requireProbe(
    await FileSystemEntity.type(file.path, followLinks: false) ==
        FileSystemEntityType.file,
    'regular_config_required',
  );
  final config = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final root = Directory(
    env['GITHUB_WORKSPACE'] ?? '',
  ).resolveSymbolicLinksSync();
  final output = Directory(
    config['output'] as String,
  ).resolveSymbolicLinksSync();
  final job = [
    env['GITHUB_RUN_ID'],
    env['GITHUB_RUN_ATTEMPT'],
    env['GITHUB_JOB'],
    env['GITHUB_SHA'],
  ].join(':');
  final nonce = config['nonce'];
  requireProbe(
    root ==
            Directory.fromUri(
              Platform.script.resolve('../../../'),
            ).resolveSymbolicLinksSync() &&
        output.startsWith('$root/out/') &&
        file.absolute.path == '$output/private/config.json' &&
        config['job'] == job &&
        nonce is String &&
        RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce) &&
        env['XC_NATIVE_TLS_PROBE_NONCE'] == nonce &&
        File('$output/.native-tls-owned').readAsStringSync() == nonce &&
        config['dart_executable'] == Platform.resolvedExecutable &&
        Platform.version.startsWith('3.13.5 '),
    'fixture_identity_mismatch',
  );
  final age =
      DateTime.now().millisecondsSinceEpoch - (config['prepared_ms'] as int);
  requireProbe(age >= 0 && age < 120000, 'fresh_fixture_required');
  requireProbe(
    args[1] == 'append' || args[1] == 'mozillaOnly',
    'fixed_mode_required',
  );
  for (final key in ['certificate', 'mozilla_ca', 'server_certificate']) {
    final input = File(config[key] as String);
    requireProbe(
      await FileSystemEntity.type(input.path, followLinks: false) ==
              FileSystemEntityType.file &&
          input.resolveSymbolicLinksSync() == input.absolute.path,
      'regular_certificate_required',
    );
  }
  requireProbe(
    config['certificate'] == '$output/private/ca.crt' &&
        config['server_certificate'] == '$output/private/server.crt',
    'fixture_certificate_scope',
  );
  final ports = config['ports'] as Map<String, dynamic>;
  requireProbe(
    ports.keys.toSet().containsAll([
          'fixture',
          'afterMozilla',
          'explicit',
          'mozillaOnly',
        ]) &&
        ports.length == 4 &&
        ports.values.every(
          (value) => value is int && value > 0 && value <= 65535,
        ) &&
        ports.values.toSet().length == 4,
    'fresh_ports_required',
  );
  return config;
}

Future<void> main(List<String> args) async {
  final checks = <String, Object?>{};
  var checkpoint = 'admission';
  var success = false;
  Map<String, Object?>? failure;
  try {
    final config = await loadConfig(args);
    final certificate = config['certificate'] as String;
    final mozilla = config['mozilla_ca'] as String;
    final ports = config['ports'] as Map<String, dynamic>;
    final expectedDer = certificateDerFromPem(
      await File(config['server_certificate'] as String).readAsString(),
    );
    if (args[1] == 'mozillaOnly') {
      checkpoint = 'mozillaOnlyImport';
      SecurityContext.defaultContext.setTrustedCertificates(mozilla);
      checkpoint = 'mozillaOnlyConnect';
      final check = await probeConnection(
        ports['mozillaOnly'] as int,
        expectedDer,
      );
      checks['mozillaOnly'] = check;
      success =
          check['connected'] == false &&
          check['exception_kind'] == 'handshake' &&
          check['bad_certificate_callbacks'] is int &&
          (check['bad_certificate_callbacks'] as int) > 0 &&
          (check['bad_certificate'] as Map?)?['der_matches'] == true &&
          (check['bad_certificate'] as Map?)?['valid_now'] == true;
    } else {
      checkpoint = 'fixtureImport';
      SecurityContext.defaultContext.setTrustedCertificates(certificate);
      checkpoint = 'fixtureConnect';
      checks['fixture'] = await probeConnection(
        ports['fixture'] as int,
        expectedDer,
      );
      checkpoint = 'mozillaImport';
      SecurityContext.defaultContext.setTrustedCertificates(mozilla);
      checkpoint = 'afterMozillaConnect';
      checks['afterMozilla'] = await probeConnection(
        ports['afterMozilla'] as int,
        expectedDer,
      );
      checkpoint = 'explicitImport';
      final context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificates(certificate);
      checkpoint = 'explicitConnect';
      checks['explicit'] = await probeConnection(
        ports['explicit'] as int,
        expectedDer,
        context: context,
      );
      success = checks.values.every(
        (value) =>
            (value as Map)['http_ok'] == true &&
            (value['peer_certificate'] as Map?)?['der_matches'] == true &&
            (value['peer_certificate'] as Map?)?['valid_now'] == true,
      );
    }
  } catch (error) {
    failure = safeTlsError(error);
  }
  stdout.writeln(
    jsonEncode({
      'success': success,
      'checkpoint': checkpoint,
      'checks': checks,
      'failure': ?failure,
    }),
  );
  exitCode = success ? 0 : 1;
}
