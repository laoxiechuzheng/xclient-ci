import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import 'src/brand_config.dart';
import 'src/brand_edits.dart';
import 'src/mihomo_patch.dart';
import 'src/service_edits.dart';

const _usage =
    '''
Rewrites the native identifiers of this working tree for one brand build.

usage: dart tool/xclient/brand_apply.dart <brand_id> [options]

Reads <brands-dir>/<brand_id>/brand.json (and its icon overlay), then edits
the Android applicationId / label / launcher icons / URL scheme, the Windows
exe name / version info / Inno Setup AppId / install dir / data dir, the macOS
PRODUCT_NAME / bundle id / app icon / URL scheme, distribute_options.yaml, and
writes $brandDefinesFile for `dart setup.dart` (--dart-define-from-file).

Meant for CI and throwaway local builds: the edits are not to be committed.
Running it again, also for another brand, is safe.''';

/// Identifiers left alone, printed so a reviewer knows what still collides.
const _skipped = [
  'Kotlin package / Android namespace com.follow.clash (only applicationId changes; see research 01 §3.11)',
  'legacy helper fallback port 47890 (current Windows helpers publish a dynamic per-service registry port and readiness checks the executable path)',
  'default mixed-port 7890 (user setting in the Dart config)',
  'Dart packageName com.follow.clash is the native MethodChannel namespace, not the branded applicationId; repository metadata stays upstream',
  'Android TV launcher icons and banner (mipmap-television-*, ic_banner)',
  'tray icons under assets/images/tray (add them to the overlay to change)',
];

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'brands-dir',
      defaultsTo: 'brands',
      help: 'Directory holding <brand_id>/brand.json',
    )
    ..addOption(
      'root',
      defaultsTo: '.',
      help: 'Repository root to rewrite (a scratch copy for experiments)',
    )
    ..addOption(
      'version',
      valueHelp: '1.2.3',
      help: 'Also set pubspec.yaml to <version>+<build>',
    )
    ..addFlag(
      'check',
      negatable: false,
      help: 'Print the planned edits without writing anything',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (e) {
    _fail('${e.message}\n\n$_usage\n\n${parser.usage}');
  }
  if (results['help'] as bool || results.rest.length != 1) {
    stdout.writeln('$_usage\n\n${parser.usage}');
    exit(results['help'] as bool ? 0 : 64);
  }

  final brandId = results.rest.single;
  final root = p.normalize(p.absolute(results['root'] as String));
  final brandsDir = p.isAbsolute(results['brands-dir'] as String)
      ? results['brands-dir'] as String
      : p.join(root, results['brands-dir'] as String);
  final check = results['check'] as bool;
  final version = results['version'] as String?;

  try {
    final brand = BrandConfig.load(p.join(brandsDir, brandId));
    final plan = planBrandApply(brand, root: root, version: version);
    stdout.writeln(prepareMihomoPatch(root, checkOnly: check));
    stdout.writeln(
      '${check ? 'Planned' : 'Applying'} brand "${brand.brandId}" '
      '(${brand.displayName}) to $root',
    );
    for (final change in plan.changes) {
      stdout.writeln('  $change');
    }
    if (!check) {
      plan.write();
      stdout.writeln(
        'Wrote ${plan.changes.where((c) => c.changes).length} '
        'change(s).',
      );
    }
    stdout.writeln('Not rebranded (by design):');
    for (final item in _skipped) {
      stdout.writeln('  - $item');
    }
  } on BrandConfigException catch (e) {
    _fail(e.message);
  } on BrandEditException catch (e) {
    _fail(e.message);
  } on FormatException catch (e) {
    _fail(e.message);
  }
}

/// Every write `brand_apply` would make, computed before anything is written
/// so that a failed match leaves the tree untouched.
class BrandApplyPlan {
  final List<PlannedChange> changes;
  final void Function() write;

  const BrandApplyPlan(this.changes, this.write);
}

BrandApplyPlan planBrandApply(
  BrandConfig brand, {
  required String root,
  String? version,
}) {
  final effectiveVersion = version ?? brand.versionName;
  final changes = <PlannedChange>[];
  final writes = <void Function()>[];
  final original = <String, String>{};
  final transformed = <String, String>{};

  for (final edit in [
    ...brandTextEdits(brand, version: effectiveVersion),
    ...serviceTextEdits(brand),
  ]) {
    final file = File(p.join(root, edit.path));
    if (!file.existsSync()) {
      throw BrandEditException('${edit.path} does not exist under $root');
    }
    final initial = original.putIfAbsent(edit.path, file.readAsStringSync);
    final before = transformed[edit.path] ?? initial;
    final String after;
    try {
      after = edit.transform(before);
    } on BrandEditException catch (e) {
      throw BrandEditException('${edit.path}: ${e.message}');
    }
    final differs = after != before;
    transformed[edit.path] = after;
    changes.add(PlannedChange(edit.path, edit.description, changes: differs));
  }
  for (final MapEntry(:key, :value) in transformed.entries) {
    if (value != original[key]) {
      writes.add(() => File(p.join(root, key)).writeAsStringSync(value));
    }
  }

  for (final (source, destination) in overlayFiles(brand)) {
    final target = File(p.join(root, destination));
    final bytes = source.readAsBytesSync();
    final differs =
        !target.existsSync() || !_sameBytes(target.readAsBytesSync(), bytes);
    changes.add(PlannedChange(destination, 'icon overlay', changes: differs));
    for (final conflict in conflictingAndroidResources(root, destination)) {
      changes.add(
        PlannedChange(
          conflict,
          'same resource name as $destination',
          changes: true,
          delete: true,
        ),
      );
      writes.add(() => File(p.join(root, conflict)).deleteSync());
    }
    if (differs) {
      writes.add(() {
        target.parent.createSync(recursive: true);
        target.writeAsBytesSync(bytes);
      });
    }
  }

  final defines = File(p.join(root, brandDefinesFile));
  final definesMap = brand.toDefines(
    coreVersion: coreVersionOf(root),
    version: effectiveVersion,
  );
  final definesContent = encodeDefines(definesMap);
  final definesDiffer =
      !defines.existsSync() || defines.readAsStringSync() != definesContent;
  changes.add(
    PlannedChange(
      brandDefinesFile,
      'compile-time defines (${definesMap.length} keys)',
      changes: definesDiffer,
    ),
  );
  if (definesDiffer) {
    writes.add(() => defines.writeAsStringSync(definesContent));
  }

  return BrandApplyPlan(changes, () {
    for (final write in writes) {
      write();
    }
  });
}

/// The mihomo version build_config.yaml pins, without the leading `v`.
String? coreVersionOf(String root) {
  final file = File(p.join(root, 'build_config.yaml'));
  if (!file.existsSync()) return null;
  final match = RegExp(
    r'^core_version:\s*v?([0-9][^\s]*)',
    multiLine: true,
  ).firstMatch(file.readAsStringSync());
  return match?[1];
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Never _fail(String message) {
  stderr.writeln('brand_apply: $message');
  exit(1);
}
