import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _parentSource = r'''
import 'dart:convert';
import 'dart:io';
import 'package:fl_clash/xboard/update/install/installer.dart';
import 'package:fl_clash/xboard/update/install/windows_installer.dart';
String quote(String value) => "'${value.replaceAll("'", "''")}'";
Future<void> main(List<String> args) async {
  final home = args[0], nonce = args[1];
  if (!Platform.isWindows || !RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce) ||
      File('$home/owner').readAsStringSync() != nonce) exit(2);
  final script = '[System.IO.File]::WriteAllText(${quote('$home/started')}, [string]\$PID); '
      '[System.Threading.Thread]::Sleep(2500); '
      '[System.IO.File]::WriteAllText(${quote('$home/completed')}, ${quote(nonce)})';
  await startDetached(WindowsUpdateInstaller.powerShellPath, [
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-WindowStyle', 'Hidden', '-EncodedCommand', encodePowerShell(script),
  ]);
  await File('$home/parent-ready').writeAsString(nonce, flush: true);
  exit(0);
}
''';

void main() {
  final sdk = Platform.environment['XC_UPDATE_HELPER_TEST_DART'] ?? '';
  test(
    'production Windows helper completes after its Dart parent exits',
    () async {
      expect(p.isAbsolute(sdk) && await File(sdk).exists(), isTrue);
      final scratch = p.absolute('.dart_tool');
      final random = Random.secure();
      final nonce = List.generate(
        16,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final directory = await Directory(
        p.join(scratch, 'update-helper-$nonce'),
      ).create();
      final marker = File(p.join(directory.path, 'owner'));
      final completed = File(p.join(directory.path, 'completed'));
      await marker.writeAsString(nonce, flush: true);
      final source = File(p.join(directory.path, 'parent.dart'));
      await source.writeAsString(_parentSource);
      Process? parent;
      try {
        parent = await Process.start(sdk, [
          '--disable-dart-dev',
          '--packages=${p.absolute('.dart_tool/package_config.json')}',
          source.path,
          directory.path,
          nonce,
        ]);
        unawaited(parent.stdout.drain<void>().catchError((Object _) {}));
        unawaited(parent.stderr.drain<void>().catchError((Object _) {}));
        final code = await parent.exitCode.timeout(const Duration(seconds: 12));
        expect(code, 0, reason: 'owned SDK parent must exit normally');
        expect(
          await completed.exists(),
          isFalse,
          reason:
              'the child must still have pending work when its parent exits',
        );
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!await completed.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        final started = File(p.join(directory.path, 'started'));
        final startedByChild = await started.exists();
        final completedByChild =
            await completed.exists() && await completed.readAsString() == nonce;
        // ignore: avoid_print
        print(
          jsonEncode({
            'production_wrapper': true,
            'parent_exit_zero': code == 0,
            'child_script_started': startedByChild,
            'completed_after_parent_exit': completedByChild,
          }),
        );
        expect(
          startedByChild,
          isTrue,
          reason: 'the real helper must execute its first instruction',
        );
        expect(
          completedByChild,
          isTrue,
          reason: 'the real helper must survive parent exit',
        );
      } finally {
        if (parent != null) {
          try {
            await parent.exitCode.timeout(const Duration(seconds: 1));
          } on TimeoutException {
            parent.kill();
            await parent.exitCode;
          }
        }
        expect(await marker.readAsString(), nonce);
        expect(
          p.isWithin(scratch, await directory.resolveSymbolicLinks()),
          isTrue,
        );
        await directory.delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || sdk.isEmpty
        ? 'Requires explicit native Dart SDK for the harmless Windows helper probe.'
        : false,
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
