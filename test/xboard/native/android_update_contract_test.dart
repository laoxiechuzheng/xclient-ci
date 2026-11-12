import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'android_update_contract.dart';

AndroidUpdateQaContract fixture({
  String fixtureId = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String source = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  String run = '123',
  String attempt = '1',
  String stage = '1',
  String? sha,
  int? size,
}) => AndroidUpdateQaContract(
  fixtureId: fixtureId,
  sourceSha: source,
  runId: run,
  runAttempt: attempt,
  stage: stage,
  v2Sha256: sha ?? (stage == '1' ? 'c' * 64 : ''),
  v2Bytes: size ?? (stage == '1' ? 1024 : 0),
);

Matcher refused(AndroidUpdateQaFailure reason) => throwsA(
  isA<AndroidUpdateQaRefused>().having((e) => e.reason, 'reason', reason),
);

Map<String, Object?> lease(
  AndroidUpdateQaContract c, {
  AndroidUpdateQaAction action = AndroidUpdateQaAction.prepare,
}) => {
  'schema': 1,
  'fixture_id': c.fixtureId,
  'source_sha': c.sourceSha,
  'run_id': c.runId,
  'run_attempt': c.runAttempt,
  'stage': c.stage,
  'pid': 42,
  'action': action.name,
};

void admit(
  AndroidUpdateQaContract c, {
  bool safe = true,
  bool android = true,
  String brand = 'example',
  String package = 'com.xclient.example',
  String? version,
  String? build,
  String? canonicalVersion,
  String? canonicalBuild,
}) => c.validateNative(
  safeMode: safe,
  isAndroid: android,
  brandId: brand,
  packageName: package,
  nativeVersion: version ?? c.version,
  nativeBuild: build ?? '${c.buildNumber}',
  canonicalVersion: canonicalVersion ?? c.version,
  canonicalBuild: canonicalBuild ?? '${c.buildNumber}',
);

final started = DateTime.utc(2026, 11, 4);

void validateLease(
  AndroidUpdateQaContract c,
  Map<String, Object?> value, {
  AndroidUpdateQaAction action = AndroidUpdateQaAction.prepare,
  DateTime? modified,
  DateTime? now,
}) => c.validateLease(
  value,
  pid: 42,
  action: action,
  started: started,
  modified: modified ?? started.add(const Duration(seconds: 1)),
  now: now ?? started.add(const Duration(seconds: 10)),
);

void main() {
  test('both stages have exact versions and an isolated checked namespace', () {
    for (final stage in ['1', '2']) {
      final c = fixture(stage: stage);
      expect(c.validateConfiguration, returnsNormally);
      expect(c.namespace, 'qaaaaaaaaaaaa');
      expect(c.scopeName, 'xclient-update-qa-${c.fixtureId}');
      expect(c.version, '1.0.0-pre.$stage');
      expect(c.buildNumber, 10000400 + int.parse(stage));
    }
  });

  test('invalid compiled identities fail before any namespace or path use', () {
    final invalid = [
      fixture(fixtureId: '../PRIVATE'),
      fixture(fixtureId: 'A' * 32),
      fixture(fixtureId: 'a' * 32 + '\n'),
      fixture(source: 'b' * 39),
      fixture(source: 'b' * 40 + '\r'),
      fixture(run: '0'),
      fixture(run: '001'),
      fixture(run: '123\n'),
      fixture(attempt: '-1'),
      fixture(attempt: '1\n'),
      fixture(stage: '3'),
      fixture(stage: '01'),
      fixture(sha: ''),
      fixture(sha: 'not-a-digest'),
      fixture(size: 0),
      fixture(size: 512 * 1024 * 1024 + 1),
      fixture(stage: '2', sha: 'c' * 64),
      fixture(stage: '2', size: 1),
    ];
    for (final c in invalid) {
      expect(
        c.validateConfiguration,
        refused(AndroidUpdateQaFailure.configuration),
      );
      expect(() => c.scopeName, refused(AndroidUpdateQaFailure.configuration));
    }
  });

  test(
    'only SAFE Android and the exact native and canonical pair are admitted',
    () {
      expect(() => admit(fixture()), returnsNormally);
      expect(() => admit(fixture(stage: '2')), returnsNormally);
      final bad = <void Function()>[
        () => admit(fixture(), safe: false),
        () => admit(fixture(), android: false),
        () => admit(fixture(), brand: '98k'),
        () => admit(fixture(), package: 'com.xclient.example.dev'),
        () => admit(fixture(), version: '1.0.0'),
        () => admit(fixture(), build: '10004401'),
        () => admit(fixture(), canonicalVersion: '1.0.0-pre.2'),
        () => admit(fixture(), canonicalBuild: '10000402'),
      ];
      for (final attempt in bad) {
        expect(attempt, refused(AndroidUpdateQaFailure.nativeIdentity));
      }
    },
  );

  test('both prepare leases and only a V1 install lease are admitted', () {
    for (final stage in ['1', '2']) {
      final c = fixture(stage: stage);
      expect(() => validateLease(c, lease(c)), returnsNormally);
    }
    final c = fixture();
    expect(
      () => validateLease(
        c,
        lease(c, action: AndroidUpdateQaAction.install),
        action: AndroidUpdateQaAction.install,
      ),
      returnsNormally,
    );
    final two = fixture(stage: '2');
    expect(
      () => validateLease(
        two,
        lease(two, action: AndroidUpdateQaAction.install),
        action: AndroidUpdateQaAction.install,
      ),
      refused(AndroidUpdateQaFailure.lease),
    );
  });

  test(
    'foreign generations, PIDs, schemas and extra fields cannot arm native work',
    () {
      final c = fixture();
      final original = lease(c);
      final changes = <String, Object?>{
        'schema': 2,
        'fixture_id': 'd' * 32,
        'source_sha': 'd' * 40,
        'run_id': '124',
        'run_attempt': '2',
        'stage': '2',
        'pid': 43,
        'action': 'other',
        'token': 'PRIVATE_VALUE',
      };
      for (final change in changes.entries) {
        expect(
          () => validateLease(c, {...original, change.key: change.value}),
          refused(AndroidUpdateQaFailure.lease),
        );
      }
      for (final pid in [0, -1, '42', 42.0, true]) {
        expect(
          () => validateLease(c, {...original, 'pid': pid}),
          refused(AndroidUpdateQaFailure.lease),
        );
      }
      for (final schema in [true, 1.0, '1']) {
        expect(
          () => validateLease(c, {...original, 'schema': schema}),
          refused(AndroidUpdateQaFailure.lease),
        );
      }
      expect(
        () => validateLease(c, {...original}..remove('pid')),
        refused(AndroidUpdateQaFailure.lease),
      );
    },
  );

  test('stale, pre-process and future lease files are refused', () {
    final c = fixture();
    for (final modified in [
      started.subtract(const Duration(seconds: 3)),
      started.add(const Duration(seconds: 13)),
    ]) {
      expect(
        () => validateLease(c, lease(c), modified: modified),
        refused(AndroidUpdateQaFailure.staleLease),
      );
    }
    expect(
      () => validateLease(
        c,
        lease(c),
        now: started.add(const Duration(seconds: 122)),
      ),
      refused(AndroidUpdateQaFailure.staleLease),
    );
    expect(
      () => validateLease(
        c,
        lease(c),
        now: started.subtract(const Duration(seconds: 1)),
      ),
      refused(AndroidUpdateQaFailure.staleLease),
    );
  });

  test(
    'malformed payloads are bounded and failures never contain their values',
    () {
      final c = fixture();
      expect(c.decode(jsonEncode(lease(c))), lease(c));
      for (final value in [
        '[1]',
        'null',
        '{"PRIVATE_VALUE":',
        'x' * (16 * 1024 + 1),
      ]) {
        try {
          c.decode(value);
          fail('A malformed payload was admitted');
        } on AndroidUpdateQaRefused catch (error) {
          expect(error.reason, AndroidUpdateQaFailure.payload);
          expect('$error', isNot(contains('PRIVATE_VALUE')));
        }
      }
    },
  );
}
