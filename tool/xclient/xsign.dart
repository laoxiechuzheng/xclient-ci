import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'src/brand_config.dart';
import 'src/release_doc.dart';

const _usage = '''
Offline Ed25519 keys and signed documents for XClient (docs/DESIGN.md §5.1,
§7.1, §7.2).

usage:
  dart tool/xclient/xsign.dart keygen <kid> --out <seed-file>
      Creates a key pair, writes the 32-byte seed (b64u) to a new file that
      only the owner can read, and prints {"kid","pub"} for brand.json.
  dart tool/xclient/xsign.dart pub <seed-file>
      Prints the public key of an existing seed.
  dart tool/xclient/xsign.dart sign-release <brand> <version> <assets-dir> <urls-base>... [--kid rel-1] [--out file]
      Signs the release facts of <assets-dir>/<brand>-*-v<version>.* with the
      seed in \$XCLIENT_REL_SEED and writes <brand>-release-v<version>.json
      into <assets-dir> (or --out). A URL base may hold {version} or {tag}.
  dart tool/xclient/xsign.dart sign <boot|policy|rel> <payload.json> --kid <kid> [--seed-env VAR] [--out file]
      Signs any payload; the seed comes from \$VAR (default XCLIENT_REL_SEED).
  dart tool/xclient/xsign.dart verify <doc.json> <pub|kid=pub|brand.json> [--type rel]
      Verifies a document and prints its payload. Exits 1 when it fails.

Seeds are read from files or environment variables only, never from the
command line, and are never printed.''';

Future<void> main(List<String> arguments) async {
  exitCode = await runXsign(arguments, environment: Platform.environment);
}

/// Runs one xsign command; returns the process exit code.
Future<int> runXsign(
  List<String> arguments, {
  required Map<String, String> environment,
  StringSink? out,
  StringSink? err,
  DateTime? now,
}) async {
  final output = out ?? stdout;
  final errors = err ?? stderr;
  final parser = ArgParser()
    ..addOption('out', abbr: 'o')
    ..addOption('kid')
    ..addOption('seed-env', defaultsTo: 'XCLIENT_REL_SEED')
    ..addOption('type', defaultsTo: 'rel', allowed: ['boot', 'policy', 'rel'])
    ..addOption('build', help: 'Override the build number')
    ..addFlag('help', abbr: 'h', negatable: false);
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    errors.writeln('xsign: ${e.message}');
    return 64;
  }
  final rest = results.rest;
  if (results['help'] as bool || rest.isEmpty) {
    output.writeln(_usage);
    return results['help'] as bool ? 0 : 64;
  }
  try {
    switch (rest.first) {
      case 'keygen':
        return await _keygen(rest, results, output, errors);
      case 'pub':
        return await _pub(rest, output, errors);
      case 'sign-release':
        return await _signRelease(rest, results, environment, output, now);
      case 'sign':
        return await _sign(rest, results, environment, output);
      case 'verify':
        return await _verify(rest, results, output, errors);
      default:
        errors.writeln('xsign: unknown command "${rest.first}"\n\n$_usage');
        return 64;
    }
  } on SignedDocException catch (e) {
    errors.writeln('xsign: ${e.message}');
    return 1;
  } on FormatException catch (e) {
    errors.writeln('xsign: ${e.message}');
    return 1;
  } on FileSystemException catch (e) {
    errors.writeln('xsign: ${e.message}: ${e.path}');
    return 1;
  }
}

Future<int> _keygen(
  List<String> rest,
  ArgResults results,
  StringSink output,
  StringSink errors,
) async {
  final outPath = results['out'] as String?;
  if (rest.length != 2 || outPath == null) {
    errors.writeln('xsign: usage: keygen <kid> --out <seed-file>');
    return 64;
  }
  final kid = rest[1];
  if (!RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(kid)) {
    errors.writeln('xsign: kid must match [A-Za-z0-9._-]{1,64}');
    return 64;
  }
  final random = Random.secure();
  final seed = List<int>.generate(32, (_) => random.nextInt(256));
  await writeSecretFile(outPath, '${encodeB64u(seed)}\n');
  final pub = await publicKeyOf(seed);
  output.writeln(jsonEncode({'kid': kid, 'pub': pub}));
  errors.writeln(
    'xsign: seed written to $outPath. Keep it offline; store it as a CI '
    'secret only for the job that signs.',
  );
  return 0;
}

/// Creates [path] exclusively (never overwrites a seed) and, on POSIX hosts,
/// restricts it to the owner (0600) before writing.
Future<void> writeSecretFile(String path, String content) async {
  final file = File(path);
  if (file.existsSync()) {
    throw FileSystemException('refusing to overwrite an existing file', path);
  }
  file.parent.createSync(recursive: true);
  file.createSync(exclusive: true);
  if (!Platform.isWindows) {
    final chmod = await Process.run('chmod', ['600', path]);
    if (chmod.exitCode != 0) {
      file.deleteSync();
      throw FileSystemException('chmod 600 failed: ${chmod.stderr}', path);
    }
  }
  file.writeAsStringSync(content, flush: true);
}

Future<int> _pub(
  List<String> rest,
  StringSink output,
  StringSink errors,
) async {
  if (rest.length != 2) {
    errors.writeln('xsign: usage: pub <seed-file>');
    return 64;
  }
  final seed = parseSeed(File(rest[1]).readAsStringSync());
  output.writeln(await publicKeyOf(seed));
  return 0;
}

List<int> _seedFromEnv(Map<String, String> environment, String name) {
  final value = environment[name];
  if (value == null || value.trim().isEmpty) {
    throw SignedDocException('\$$name is not set');
  }
  return parseSeed(value);
}

Future<int> _signRelease(
  List<String> rest,
  ArgResults results,
  Map<String, String> environment,
  StringSink output,
  DateTime? now,
) async {
  if (rest.length < 5) {
    throw const FormatException(
      'usage: sign-release <brand> <version> <assets-dir> <urls-base>...',
    );
  }
  final brand = rest[1];
  final version = rest[2];
  final assetsDir = rest[3];
  final bases = rest.sublist(4);
  final buildText = results['build'] as String?;
  final payload = await buildReleasePayload(
    brand: brand,
    version: version,
    assetsDir: assetsDir,
    urlBases: bases,
    build: buildText == null ? null : int.parse(buildText),
    publishedAt: now,
  );
  final doc = await signDoc(
    type: SignedDocType.rel,
    kid: (results['kid'] as String?) ?? 'rel-1',
    seed: _seedFromEnv(environment, results['seed-env'] as String),
    payload: payload,
  );
  final outPath =
      (results['out'] as String?) ??
      p.join(assetsDir, releaseDocName(brand, version));
  File(outPath).writeAsStringSync('${jsonEncode(doc)}\n');
  final assets = (payload['assets'] as Map).keys.join(', ');
  output.writeln('signed $outPath ($assets)');
  return 0;
}

Future<int> _sign(
  List<String> rest,
  ArgResults results,
  Map<String, String> environment,
  StringSink output,
) async {
  final kid = results['kid'] as String?;
  if (rest.length != 3 || kid == null) {
    throw const FormatException(
      'usage: sign <boot|policy|rel> <payload.json> --kid <kid>',
    );
  }
  final type = SignedDocType.parse(rest[1]);
  final payload = jsonDecode(File(rest[2]).readAsStringSync());
  if (payload is! Map<String, Object?>) {
    throw const FormatException('the payload must be a JSON object');
  }
  final doc = await signDoc(
    type: type,
    kid: kid,
    seed: _seedFromEnv(environment, results['seed-env'] as String),
    payload: payload,
  );
  final text = '${jsonEncode(doc)}\n';
  final outPath = results['out'] as String?;
  if (outPath == null) {
    output.write(text);
  } else {
    File(outPath).writeAsStringSync(text);
    output.writeln('signed $outPath');
  }
  return 0;
}

Future<int> _verify(
  List<String> rest,
  ArgResults results,
  StringSink output,
  StringSink errors,
) async {
  if (rest.length != 3) {
    throw const FormatException(
      'usage: verify <doc.json> <pub|kid=pub|brand.json>',
    );
  }
  final type = SignedDocType.parse(results['type'] as String);
  final doc = jsonDecode(File(rest[1]).readAsStringSync());
  if (doc is! Map<String, Object?>) {
    throw const FormatException('the document must be a JSON object');
  }
  final keys = _trustedKeys(rest[2], type, doc);
  try {
    final payload = await verifyDoc(type: type, doc: doc, trustedKeys: keys);
    output.writeln(const JsonEncoder.withIndent('  ').convert(payload));
    return 0;
  } on SignedDocException catch (e) {
    errors.writeln('xsign: verification failed: ${e.message}');
    return 1;
  }
}

/// Accepts a bare public key (trusted for the document's own kid),
/// `kid=pub`, or a brand.json whose ctrl/rel keys apply to [type].
Map<String, String> _trustedKeys(
  String spec,
  SignedDocType type,
  Map<String, Object?> doc,
) {
  if (spec.endsWith('.json') && File(spec).existsSync()) {
    final brand = BrandConfig.load(p.dirname(spec));
    return type == SignedDocType.rel ? brand.relPubKeys : brand.ctrlPubKeys;
  }
  // b64u never holds '=', and padded base64 only ends with it.
  final separator = spec.indexOf('=');
  if (separator > 0 && !spec.endsWith('=')) {
    return {spec.substring(0, separator): spec.substring(separator + 1)};
  }
  final kid = doc['kid'];
  return {if (kid is String) kid: spec};
}
