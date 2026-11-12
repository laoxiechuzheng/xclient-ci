import 'dart:io' as io;

import 'package:path/path.dart' as p;

import '../../core/log.dart';
import '../../core/sync/update_docs.dart';
import '../update_exception.dart';
import 'installer.dart';

class CodesignInfo {
  final String identifier;
  final String? teamId;

  /// The certificate chain, leaf first; empty for an ad-hoc signature.
  final List<String> authorities;
  final bool adhoc;
  final String? cdhash;

  const CodesignInfo({
    required this.identifier,
    this.teamId,
    this.authorities = const [],
    this.adhoc = false,
    this.cdhash,
  });

  /// codesign writes key=value metadata to stderr; no identifier means unsigned.
  static CodesignInfo? parse(String output) {
    String? identifier;
    String? teamId;
    String? cdhash;
    var adhoc = false;
    final authorities = <String>[];
    for (final raw in output.split('\n')) {
      final line = raw.trim();
      final eq = line.indexOf('=');
      if (eq <= 0) continue;
      final key = line.substring(0, eq);
      final value = line.substring(eq + 1).trim();
      switch (key) {
        case 'Identifier':
          identifier ??= value;
        case 'TeamIdentifier':
          teamId = value == 'not set' ? null : value;
        case 'Authority':
          authorities.add(value);
        case 'CDHash':
          cdhash = value;
        case 'Signature':
          adhoc = value == 'adhoc';
        case 'CodeDirectory v':
          if (value.contains('adhoc')) adhoc = true;
      }
    }
    if (identifier == null || identifier.isEmpty) return null;
    return CodesignInfo(
      identifier: identifier,
      teamId: teamId,
      authorities: authorities,
      adhoc: adhoc || authorities.isEmpty,
      cdhash: cdhash,
    );
  }
}

/// Certificate-signed replacements retain the bundle id, team and Authority chain.
/// Ad-hoc signatures have no stable signer or cross-version cdhash; trust comes from the signed manifest.
/// codesign --verify --deep --strict still checks bundle integrity.
bool signingIdentityMatches(CodesignInfo current, CodesignInfo next) {
  if (current.identifier != next.identifier) return false;
  if (current.adhoc) return next.adhoc;
  if (next.adhoc) return false;
  if (current.teamId != next.teamId) return false;
  if (current.authorities.length != next.authorities.length) return false;
  for (var i = 0; i < current.authorities.length; i++) {
    if (current.authorities[i] != next.authorities[i]) return false;
  }
  return true;
}

String shQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// A failed bundle swap or relaunch restores and opens the old bundle.
String macosSwapScript({
  required String appPath,
  required String newAppPath,
  required String stagingDir,
  required int appPid,
  required String logPath,
}) {
  return '''
#!/bin/sh
APP=${shQuote(appPath)}
NEW=${shQuote(newAppPath)}
STAGE=${shQuote(stagingDir)}
LOG=${shQuote(logPath)}
OLD="\$APP.xclient-old"
log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >>"\$LOG"; }
i=0
while kill -0 $appPid 2>/dev/null; do
  i=\$((i + 1))
  if [ "\$i" -gt 120 ]; then log "app still running, update aborted"; exit 1; fi
  sleep 0.5
done
rm -rf "\$OLD"
if ! mv "\$APP" "\$OLD"; then
  log "cannot move the old app aside"
  rm -rf "\$STAGE"
  open "\$APP"
  exit 1
fi
if mv "\$NEW" "\$APP"; then
  xattr -dr com.apple.quarantine "\$APP" 2>/dev/null
  if open "\$APP"; then
    log "updated"
    rm -rf "\$OLD" "\$STAGE"
    exit 0
  fi
  log "new app did not launch, rolling back"
  rm -rf "\$APP"
else
  log "cannot move the new app in, rolling back"
fi
mv "\$OLD" "\$APP"
rm -rf "\$STAGE"
open "\$APP"
exit 1
''';
}

String? appBundleOf(String executable) {
  final bundle = p.dirname(p.dirname(p.dirname(executable)));
  return bundle.endsWith('.app') ? bundle : null;
}

/// Staging beside the installed bundle keeps the swap on one volume; see README.md for fallback constraints.
class MacosUpdateInstaller implements XcPlatformInstaller {
  final Future<void> Function() exitApp;
  final DetachedStarter start;
  final ProcessRunner run;
  final String executable;
  final int appPid;

  final String downloadPage;

  MacosUpdateInstaller({
    required this.exitApp,
    this.downloadPage = '',
    DetachedStarter? start,
    ProcessRunner? run,
    String? executable,
    int? appPid,
  }) : start = start ?? startDetached,
       run = run ?? runProcess,
       executable = executable ?? io.Platform.resolvedExecutable,
       appPid = appPid ?? io.pid;

  @override
  String get extension => 'zip';

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<bool> requestInstallPermission() async => true;

  Future<CodesignInfo?> _codesignInfo(String bundle) async {
    final result = await run('/usr/bin/codesign', ['-dvvv', bundle]);
    if (result.exitCode != 0) return null;
    return CodesignInfo.parse('${result.stderr}\n${result.stdout}');
  }

  Future<InstallOutcome> _manual(io.File zip, String reason) async {
    xcLog('macOS update falls back to manual install: $reason', warn: true);
    await run('/usr/bin/open', ['-R', zip.path]);
    if (downloadPage.startsWith('https://')) {
      await run('/usr/bin/open', [downloadPage]);
    }
    return InstallOutcome.manual;
  }

  @override
  Future<InstallOutcome> install(
    io.File file, {
    required ReleaseManifest manifest,
    InstallStageListener? onStage,
  }) async {
    onStage?.call(InstallStage.preparing);
    final app = appBundleOf(executable);
    // Replacing a read-only translocated copy would not update the installed app.
    if (app == null || app.contains('/AppTranslocation/')) {
      return _manual(file, 'not an installed bundle');
    }
    final current = await _codesignInfo(app);
    if (current == null) return _manual(file, 'current app unsigned');
    final staging = io.Directory(
      p.join(p.dirname(app), '.${p.basenameWithoutExtension(app)}.update'),
    );
    try {
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create();
    } on io.FileSystemException {
      return _manual(file, 'bundle folder not writable');
    }
    Future<Never> fail(String code, String detail) async {
      try {
        await staging.delete(recursive: true);
      } on io.FileSystemException {
        // Left for the next attempt, which deletes it first.
      }
      throw XcUpdateException(code, detail);
    }

    final unzip = await run('/usr/bin/ditto', [
      '-x',
      '-k',
      file.path,
      staging.path,
    ]);
    if (unzip.exitCode != 0) {
      return fail(XcUpdateException.install, 'ditto ${unzip.exitCode}');
    }
    final bundles = [
      for (final entity in staging.listSync(followLinks: false))
        if (entity is io.Directory && entity.path.endsWith('.app')) entity.path,
    ];
    if (bundles.length != 1) {
      return fail(XcUpdateException.install, 'bundles ${bundles.length}');
    }
    final next = bundles.single;
    final verify = await run('/usr/bin/codesign', [
      '--verify',
      '--deep',
      '--strict',
      next,
    ]);
    if (verify.exitCode != 0) {
      return fail(XcUpdateException.signature, 'verify ${verify.exitCode}');
    }
    final nextInfo = await _codesignInfo(next);
    if (nextInfo == null || !signingIdentityMatches(current, nextInfo)) {
      return fail(XcUpdateException.signature, 'identity');
    }
    final script = io.File(p.join(staging.path, 'swap.sh'));
    await script.writeAsString(
      macosSwapScript(
        appPath: app,
        newAppPath: next,
        stagingDir: staging.path,
        appPid: appPid,
        logPath: p.join(file.parent.path, 'swap.log'),
      ),
    );
    await start('/bin/sh', [script.path]);
    await exitApp();
    return InstallOutcome.exiting;
  }
}
