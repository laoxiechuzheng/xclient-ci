import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../../../tool/xclient/src/brand_config.dart';
import '../../../tool/xclient/src/brand_edits.dart';
import '../../../tool/xclient/src/release_doc.dart';

void main() {
  final versions = [
    '1.2.3-alpha.1',
    '1.2.3-alpha.199',
    '1.2.3-beta.1',
    '1.2.3-beta.199',
    '1.2.3-pre',
    '1.2.3-pre.1',
    '1.2.3-pre.199',
    '1.2.3-rc.1',
    '1.2.3-rc.398',
    '1.2.3',
    '1.2.4-alpha.1',
    '1.3.0-alpha.1',
    '2.0.0-alpha.1',
  ];
  final invalid = [
    '1.2',
    'v1.2.3',
    '01.2.3',
    '1.02.3',
    '1.2.03',
    '1.2.3+4',
    '1.2.3-beta',
    '1.2.3-alpha.0',
    '1.2.3-alpha.200',
    '1.2.3-beta.200',
    '1.2.3-pre.200',
    '1.2.3-rc.399',
    '1.2.3-beta.01',
    '201.0.0',
    '1.100.0',
    '1.0.100',
    '1.2.3-preview.1',
    '1.2.3-',
    '-1.0.0',
    '1.2.3\n',
  ];
  test(
    'every supported release stage has a unique increasing Android build',
    () {
      final builds = versions.map(buildNumberFor).toList();
      expect(builds.toSet().length, builds.length);
      for (var index = 1; index < builds.length; index++) {
        expect(
          builds[index],
          greaterThan(builds[index - 1]),
          reason: versions[index],
        );
      }
      expect(buildNumberFor('1.2.3'), 10203999);
      expect(buildNumberFor('200.99.99') + 4000, lessThanOrEqualTo(2100000000));
    },
  );
  test('isValidVersion and buildNumberFor reject the same invalid ranges', () {
    for (final version in [...versions, '0.0.0-alpha.1', '200.99.99']) {
      expect(isValidVersion(version), isTrue, reason: version);
    }
    for (final version in invalid) {
      expect(isValidVersion(version), isFalse, reason: version);
      expect(
        () => buildNumberFor(version),
        throwsFormatException,
        reason: version,
      );
    }
  });
  test(
    'brand pubspec and signed release facts share each version build',
    () async {
      final dir = await Directory.systemTemp.createTemp('xc-release-build-');
      try {
        final brand = BrandConfig.load('brands/example');
        for (final version in ['1.2.3-pre', '1.2.3-rc.1', '1.2.3']) {
          final edit = brandTextEdits(
            brand,
            version: version,
          ).singleWhere((edit) => edit.path == 'pubspec.yaml');
          final pubspec = edit.transform('name: example\nversion: 0.0.0+1\n');
          await File(
            '${dir.path}/${androidApkName('example', 'arm64-v8a', version)}',
          ).writeAsBytes([1]);
          final release = await buildReleasePayload(
            brand: 'example',
            version: version,
            assetsDir: dir.path,
            urlBases: ['https://downloads.example/releases'],
          );
          expect(pubspec, contains('version: $version+${release['build']}\n'));
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'CI tag parser uses the same accepted versions and build numbers',
    () async {
      final workflow =
          loadYaml(
                File(
                  '.github/workflows/xclient-release.yaml',
                ).readAsStringSync(),
              )
              as YamlMap;
      final prepare = (workflow['jobs'] as YamlMap)['prepare'] as YamlMap;
      final steps = prepare['steps'] as YamlList;
      final step = steps.cast<YamlMap>().singleWhere(
        (step) => step['id'] == 'version',
      );
      expect(step['shell'], 'python');
      final script = step['run'] as String;
      final dir = await Directory.systemTemp.createTemp('xc-tag-test-');
      try {
        for (final version in [
          ...versions,
          ...invalid,
          '0.0.0-alpha.1',
          '200.99.99',
        ]) {
          final output = File('${dir.path}/outputs');
          await output.writeAsString('');
          final result = await Process.run(
            Platform.isWindows ? 'python' : 'python3',
            ['-c', script],
            environment: {'TAG': 'v$version', 'GITHUB_OUTPUT': output.path},
          );
          expect(
            result.exitCode == 0,
            isValidVersion(version),
            reason: version,
          );
          if (result.exitCode == 0) {
            expect(
              await output.readAsLines(),
              contains('build=${buildNumberFor(version)}'),
              reason: version,
            );
          }
        }
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
