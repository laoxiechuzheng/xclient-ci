import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/xclient/src/brand_edits.dart';
import '../../../tool/xclient/src/mihomo_patch.dart';

void main() {
  late Directory root;
  late Directory module;

  String git(List<String> args, {Directory? at}) {
    final result = Process.runSync(
      'git',
      args,
      workingDirectory: (at ?? module).path,
      environment: {
        'GIT_AUTHOR_NAME': 'Contributor',
        'GIT_COMMITTER_NAME': 'Contributor',
        'GIT_AUTHOR_EMAIL': 'fixture@example.invalid',
        'GIT_COMMITTER_EMAIL': 'fixture@example.invalid',
      },
    );
    if (result.exitCode != 0) {
      throw StateError('fixture Git failed: ${result.stderr}');
    }
    return (result.stdout as String).trim();
  }

  File native(String name) => File(p.join(module.path, 'adapter', name));

  setUp(() {
    root = Directory.systemTemp.createTempSync('managed-patch-test-');
    module = Directory(p.join(root.path, 'core', 'Clash.Meta'))
      ..createSync(recursive: true);
    git(['init', '--quiet']);
    git(['config', 'core.autocrlf', 'false']);
    git(['config', 'commit.gpgsign', 'false']);
    final emptyHooks = Directory(p.join(root.path, 'empty-hooks'))
      ..createSync();
    git(['config', 'core.hooksPath', emptyHooks.path]);
    native('adapter.go')
      ..parent.createSync()
      ..writeAsStringSync('prefix\nold adapter\nsuffix\n');
    native('patch.go').writeAsStringSync('prefix\nold hook\nsuffix\n');
    File(p.join(module.path, 'keep.txt')).writeAsStringSync('original\n');
    git(['add', '.']);
    git(['commit', '--quiet', '-m', 'fixture base']);
    final base = git(['rev-parse', 'HEAD']);
    File(p.join(root.path, managedProbePatchPath))
      ..parent.createSync(recursive: true)
      ..writeAsStringSync('''# XClient-Mihomo-Base: $base

diff --git a/adapter/adapter.go b/adapter/adapter.go
--- a/adapter/adapter.go
+++ b/adapter/adapter.go
@@ -1,3 +1,3 @@
 prefix
-old adapter
+new adapter
 suffix
diff --git a/adapter/patch.go b/adapter/patch.go
--- a/adapter/patch.go
+++ b/adapter/patch.go
@@ -1,3 +1,3 @@
 prefix
-old hook
+new hook
 suffix
''');
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('real Git application is idempotent and preserves other edits', () {
    final keep = File(p.join(module.path, 'keep.txt'))
      ..writeAsStringSync('owned dirty edit\n');
    final untracked = File(p.join(module.path, 'other.txt'))
      ..writeAsStringSync('untracked edit\n');
    final head = git(['rev-parse', 'HEAD']);
    expect(prepareMihomoPatch(root.path), contains('applied'));
    expect(native('adapter.go').readAsStringSync(), contains('new adapter'));
    expect(native('patch.go').readAsStringSync(), contains('new hook'));
    expect(prepareMihomoPatch(root.path), contains('ready'));
    expect(keep.readAsStringSync(), 'owned dirty edit\n');
    expect(untracked.readAsStringSync(), 'untracked edit\n');
    expect(git(['rev-parse', 'HEAD']), head);
    git([
      'apply',
      '--reverse',
      '--check',
      p.join(root.path, managedProbePatchPath),
    ]);
  });

  test('read-only check does not apply or stage the patch', () {
    expect(prepareMihomoPatch(root.path, checkOnly: true), contains('pending'));
    expect(native('adapter.go').readAsStringSync(), contains('old adapter'));
    expect(native('patch.go').readAsStringSync(), contains('old hook'));
    expect(git(['status', '--porcelain']), isEmpty);
  });

  test('partial application fails without rewriting either file', () {
    native('adapter.go').writeAsStringSync('prefix\nnew adapter\nsuffix\n');
    final before = native('adapter.go').readAsStringSync();
    expect(
      () => prepareMihomoPatch(root.path),
      throwsA(isA<BrandEditException>()),
    );
    expect(native('adapter.go').readAsStringSync(), before);
    expect(native('patch.go').readAsStringSync(), contains('old hook'));
  });

  test('overlapping dirty source fails without rewriting it', () {
    native('adapter.go').writeAsStringSync('prefix\nuser edit\nsuffix\n');
    final before = git(['status', '--porcelain']);
    expect(
      () => prepareMihomoPatch(root.path),
      throwsA(isA<BrandEditException>()),
    );
    expect(native('adapter.go').readAsStringSync(), contains('user edit'));
    expect(native('patch.go').readAsStringSync(), contains('old hook'));
    expect(git(['status', '--porcelain']), before);
  });

  test('a different HEAD is rejected even when the patch would apply', () {
    git(['commit', '--quiet', '--allow-empty', '-m', 'different base']);
    expect(
      () => prepareMihomoPatch(root.path),
      throwsA(isA<BrandEditException>()),
    );
    expect(native('adapter.go').readAsStringSync(), contains('old adapter'));
  });

  test(
    'uninitialized module defers checks and never reads the parent HEAD',
    () {
      final other = Directory(p.join(root.path, 'outer'))..createSync();
      git(['init', '--quiet'], at: other);
      Directory(
        p.join(other.path, 'core', 'Clash.Meta'),
      ).createSync(recursive: true);
      expect(
        prepareMihomoPatch(other.path, checkOnly: true),
        contains('deferred'),
      );
      expect(
        () => prepareMihomoPatch(other.path),
        throwsA(isA<BrandEditException>()),
      );
    },
  );
}
