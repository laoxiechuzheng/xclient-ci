import 'dart:io';

import 'package:path/path.dart' as p;

import 'brand_edits.dart';

const managedProbePatchPath =
    'tool/xclient/patches/mihomo-managed-probes.patch';

String prepareMihomoPatch(String root, {bool checkOnly = false}) {
  final module = p.join(root, 'core', 'Clash.Meta');
  if (FileSystemEntity.typeSync(p.join(module, '.git')) ==
      FileSystemEntityType.notFound) {
    if (checkOnly) return 'Mihomo patch deferred: submodule is not initialized';
    throw const BrandEditException(
      'initialize core/Clash.Meta before branding',
    );
  }
  final patch = File(p.join(root, managedProbePatchPath));
  if (!patch.existsSync()) {
    throw const BrandEditException('managed probe patch is missing');
  }
  final base = RegExp(
    r'^# XClient-Mihomo-Base: ([a-f0-9]{40})\r?$',
    multiLine: true,
  ).firstMatch(patch.readAsStringSync())?[1];
  if (base == null) {
    throw const BrandEditException('managed probe patch has no valid base');
  }
  ProcessResult git(List<String> arguments) {
    try {
      return Process.runSync('git', arguments, workingDirectory: module);
    } on ProcessException {
      throw const BrandEditException('git is required for the Mihomo patch');
    }
  }

  final top = git(['rev-parse', '--show-toplevel']);
  var ownsWorktree = false;
  if (top.exitCode == 0) {
    try {
      ownsWorktree = FileSystemEntity.identicalSync(
        module,
        (top.stdout as String).trim(),
      );
    } on FileSystemException {
      ownsWorktree = false;
    }
  }
  if (!ownsWorktree) {
    throw const BrandEditException(
      'core/Clash.Meta is not its own Git worktree',
    );
  }
  final head = git(['rev-parse', 'HEAD']);
  if (head.exitCode != 0 || (head.stdout as String).trim() != base) {
    throw BrandEditException('Mihomo patch requires pinned commit $base');
  }
  final absolutePatch = p.absolute(patch.path);
  if (git(['apply', '--reverse', '--check', absolutePatch]).exitCode == 0) {
    return 'Mihomo managed probe patch is ready';
  }
  if (git(['apply', '--check', absolutePatch]).exitCode != 0) {
    throw const BrandEditException(
      'Mihomo patch conflicts with the worktree; existing edits were preserved',
    );
  }
  if (checkOnly) {
    return 'Mihomo managed probe patch is pending (read-only check)';
  }
  if (git(['apply', absolutePatch]).exitCode != 0) {
    throw const BrandEditException('Mihomo patch could not be applied');
  }
  return 'Mihomo managed probe patch applied';
}
