import 'dart:convert';
import 'dart:io' as io;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../../core/sync/update_docs.dart';
import 'installer.dart';

const innoSilentArgs = [
  '/VERYSILENT',
  '/SUPPRESSMSGBOXES',
  '/NORESTART',
  '/CLOSEAPPLICATIONS',
];

String _psQuote(String value) => "'${value.replaceAll("'", "''")}'";

/// Waits for clean app exit, installs with UAC, then relaunches even after failure.
/// The non-elevated helper relaunches because Inno's Run entry is skipifsilent.
String windowsUpdateScript({
  required String setupPath,
  required String appPath,
  required int appPid,
  required String logPath,
}) {
  final args = [
    for (final arg in innoSilentArgs) _psQuote(arg),
    "('/LOG=\"' + \$log + '\"')",
  ].join(',');
  return [
    r"$ErrorActionPreference = 'Continue'",
    '\$setup = ${_psQuote(setupPath)}',
    '\$app = ${_psQuote(appPath)}',
    '\$log = ${_psQuote(logPath)}',
    'Wait-Process -Id $appPid -Timeout 60 -ErrorAction SilentlyContinue',
    'if (Get-Process -Id $appPid -ErrorAction SilentlyContinue) { exit 1 }',
    'try {',
    '  \$p = Start-Process -FilePath \$setup -ArgumentList @($args) -WindowStyle Hidden -Verb RunAs -Wait -PassThru',
    "  Add-Content -Path (\$log + '.helper') -Value ('exit ' + \$p.ExitCode)",
    '} catch {',
    "  Add-Content -Path (\$log + '.helper') -Value ('failed ' + \$_)",
    '}',
    'Start-Process -FilePath \$app',
  ].join('\n');
}

/// EncodedCommand uses base64 of UTF-16LE across process quoting boundaries.
String encodePowerShell(String script) {
  final units = script.codeUnits;
  final bytes = ByteData(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes.setUint16(i * 2, units[i], Endian.little);
  }
  return base64.encode(bytes.buffer.asUint8List());
}

class WindowsUpdateInstaller implements XcPlatformInstaller {
  /// Stops the core and exits through FlClash's handleExit.
  final Future<void> Function() exitApp;
  final DetachedStarter start;
  final String appPath;
  final int appPid;

  WindowsUpdateInstaller({
    required this.exitApp,
    DetachedStarter? start,
    String? appPath,
    int? appPid,
  }) : start = start ?? startDetached,
       appPath = appPath ?? io.Platform.resolvedExecutable,
       appPid = appPid ?? io.pid;

  static String get powerShellPath {
    final root = io.Platform.environment['SystemRoot'] ?? r'C:\Windows';
    return p.windows.join(
      root,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  @override
  String get extension => 'exe';

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<bool> requestInstallPermission() async => true;

  @override
  Future<InstallOutcome> install(
    io.File file, {
    required ReleaseManifest manifest,
    InstallStageListener? onStage,
  }) async {
    onStage?.call(InstallStage.preparing);
    final script = windowsUpdateScript(
      setupPath: file.path,
      appPath: appPath,
      appPid: appPid,
      logPath: p.join(file.parent.path, 'install.log'),
    );
    await start(powerShellPath, [
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-EncodedCommand',
      encodePowerShell(script),
    ]);
    await exitApp();
    return InstallOutcome.exiting;
  }
}
