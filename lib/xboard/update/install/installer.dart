import 'dart:async';
import 'dart:io';

import '../../core/sync/update_docs.dart';

enum InstallOutcome { exiting, installed, manual }

enum InstallStage { awaitingUser, preparing }

typedef InstallStageListener = void Function(InstallStage stage);

/// Receives only files verified against the signed release document (size and SHA-256).
abstract class XcPlatformInstaller {
  String get extension;

  Future<bool> canInstall();

  /// Android resumes after the per-app unknown-app setting and returns the resulting permission.
  Future<bool> requestInstallPermission();

  Future<InstallOutcome> install(
    File file, {
    required ReleaseManifest manifest,
    InstallStageListener? onStage,
  });
}

abstract interface class DisposableUpdateInstaller {
  void dispose();
}

typedef DetachedStarter =
    Future<void> Function(String executable, List<String> arguments);

typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> arguments);

Future<Process> spawnUpdateHelper(
  String executable,
  List<String> arguments,
) async {
  final windows = Platform.isWindows;
  final process = await Process.start(
    executable,
    arguments,
    mode: windows ? ProcessStartMode.normal : ProcessStartMode.detached,
  );
  if (windows) {
    // DETACHED_PROCESS can terminate Windows PowerShell before its script runs.
    unawaited(process.stdout.drain<void>().catchError((Object _) {}));
    unawaited(process.stderr.drain<void>().catchError((Object _) {}));
    await process.stdin.close();
  }
  return process;
}

Future<void> startDetached(String executable, List<String> arguments) async {
  await spawnUpdateHelper(executable, arguments);
}

Future<ProcessResult> runProcess(String executable, List<String> arguments) =>
    Process.run(executable, arguments);
