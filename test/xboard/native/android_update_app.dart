import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:fl_clash/xboard/update/download.dart';
import 'package:fl_clash/xboard/update/install/android_installer.dart';
import 'package:fl_clash/xboard/update/install/installer.dart';
import 'package:fl_clash/xboard/update/update_exception.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'android_update_contract.dart';
import 'update_qa_contract.dart' show updateQaReadFailed;
import 'update_store_observer.dart';

const _contract = AndroidUpdateQaContract(
  fixtureId: String.fromEnvironment('XC_ANDROID_UPDATE_FIXTURE'),
  sourceSha: String.fromEnvironment('XC_ANDROID_UPDATE_SOURCE'),
  runId: String.fromEnvironment('XC_ANDROID_UPDATE_RUN'),
  runAttempt: String.fromEnvironment('XC_ANDROID_UPDATE_ATTEMPT'),
  stage: String.fromEnvironment('XC_ANDROID_UPDATE_STAGE'),
  v2Sha256: String.fromEnvironment('XC_ANDROID_UPDATE_V2_SHA256'),
  v2Bytes: int.fromEnvironment('XC_ANDROID_UPDATE_V2_BYTES'),
);

enum _Failure { file, timeout, store, archive, permission, oldVersion }

class _Refused implements Exception {
  const _Refused(this.reason);
  final _Failure reason;
}

void _require(bool allowed, _Failure reason) {
  if (!allowed) throw _Refused(reason);
}

final _status = ValueNotifier<String>('Starting the SAFE component');

Future<String> _digest(String path) =>
    Isolate.run(() => sha256OfFile(File(path)));

/// This entry point has no account/runtime/Core or network listener.
Future<void> main() async {
  try {
    _contract.validateConfiguration();
    if (!const bool.fromEnvironment('XC_ANDROID_UPDATE_QA') ||
        !const bool.fromEnvironment('SAFE_MODE') ||
        !Platform.isAndroid) {
      exit(1);
    }
  } on Object {
    exit(1);
  }
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        appBar: AppBar(title: const Text('SAFE Android update component')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('CI component only — no account or VPN'),
              const SizedBox(height: 16),
              Text('Version ${_contract.version} / stage ${_contract.stage}'),
              const SizedBox(height: 16),
              ValueListenableBuilder<String>(
                valueListenable: _status,
                builder: (_, value, _) => Text(value),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  final probe = _Component();
  try {
    await probe.run();
  } on Object catch (error) {
    await probe.fail(error);
  }
}

class _Component {
  static const _key = 'native-update-qa';
  final started = DateTime.now();
  Directory? scope;
  PlatformSecureStore? store;
  UpdateQaStoreDiagnostics? diagnostics;
  AndroidUpdateInstaller? installer;
  bool keyOwned = false;
  bool failed = false;
  bool pendingWritten = false;
  String phase = 'identity';

  Map<String, Object?> get context => {
    'schema': 1,
    'fixture_id': _contract.fixtureId,
    'source_sha': _contract.sourceSha,
    'run_id': _contract.runId,
    'run_attempt': _contract.runAttempt,
    'stage': _contract.stage,
    'pid': pid,
  };

  String value(String stage) =>
      'xclient-native-update-$stage-${_contract.fixtureId}';

  File file(String name) {
    _require(
      scope != null &&
          RegExp(r'^[A-Za-z0-9-]{1,80}\.(?:json|apk)$').hasMatch(name),
      _Failure.file,
    );
    return File(p.join(scope!.path, name));
  }

  Future<void> emit(String name, Map<String, Object?> data) async {
    final target = file(name);
    _require(
      await FileSystemEntity.type(target.path, followLinks: false) ==
          FileSystemEntityType.notFound,
      _Failure.file,
    );
    final pending = File('${target.path}.pending');
    await pending.create(exclusive: true);
    await pending.writeAsString(jsonEncode(data), flush: true);
    await pending.rename(target.path);
  }

  Future<Map<String, Object?>?> control(AndroidUpdateQaAction action) async {
    final name = action == AndroidUpdateQaAction.prepare ? 'lease' : 'arm';
    final target = file('$name-${_contract.stage}.json');
    final type = await FileSystemEntity.type(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    _require(type == FileSystemEntityType.file, _Failure.file);
    final before = await target.stat();
    _require(before.size <= 16 * 1024, _Failure.file);
    final handle = await target.open();
    final List<int> bytes;
    try {
      bytes = await handle.read(16 * 1024 + 1);
    } finally {
      await handle.close();
    }
    final after = await target.stat();
    _require(
      bytes.length <= 16 * 1024 &&
          before.size == after.size &&
          before.modified == after.modified,
      _Failure.file,
    );
    final decoded = _contract.decode(utf8.decode(bytes));
    _contract.validateLease(
      decoded,
      pid: pid,
      action: action,
      started: started,
      modified: after.modified,
      now: DateTime.now(),
    );
    return decoded;
  }

  Future<void> waitControl(AndroidUpdateQaAction action) async {
    final clock = Stopwatch()..start();
    while (clock.elapsed < const Duration(minutes: 2)) {
      if (await control(action) != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    throw const _Refused(_Failure.timeout);
  }

  Future<String?> read(UpdateQaStoreOperation operation) async {
    final previous = xcLogSink;
    var nativeError = false;
    xcLogSink = (message, {required warn}) {
      if (updateQaReadFailed(message, _key)) nativeError = true;
    };
    try {
      final result = await diagnostics!.run(
        operation,
        () => store!.read(_key).timeout(const Duration(seconds: 15)),
      );
      _require(!nativeError, _Failure.store);
      return result;
    } finally {
      xcLogSink = previous;
    }
  }

  Future<void> deleteKey() async {
    if (!keyOwned) return;
    await diagnostics!.run(
      UpdateQaStoreOperation.cleanupDelete,
      () => store!.delete(_key).timeout(const Duration(seconds: 15)),
    );
    _require(
      await read(UpdateQaStoreOperation.cleanupRead) == null,
      _Failure.store,
    );
    keyOwned = false;
  }

  Future<void> run() async {
    final native = await PackageInfo.fromPlatform();
    final client = await ClientInfo.detect();
    _contract.validateNative(
      safeMode: const bool.fromEnvironment('SAFE_MODE'),
      isAndroid: Platform.isAndroid,
      brandId: BrandConfig.fromEnvironment().brandId,
      packageName: native.packageName,
      nativeVersion: native.version,
      nativeBuild: native.buildNumber,
      canonicalVersion: client.appVersion,
      canonicalBuild: client.build,
    );
    final cache = await (await getTemporaryDirectory()).resolveSymbolicLinks();
    final directory = Directory(p.join(cache, _contract.scopeName));
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    _require(
      type == FileSystemEntityType.directory ||
          type == FileSystemEntityType.notFound,
      _Failure.file,
    );
    await directory.create();
    _require(
      await directory.resolveSymbolicLinks() == directory.path &&
          p.isWithin(cache, directory.path),
      _Failure.file,
    );
    scope = directory;
    await emit('hello-${_contract.stage}.json', {
      ...context,
      'native_identity': true,
      'native_version': native.version,
      'native_build': native.buildNumber,
      'app_label': native.appName,
    });
    phase = 'prepareLease';
    _status.value = 'Waiting for the current process owner';
    await waitControl(AndroidUpdateQaAction.prepare);
    diagnostics = UpdateQaStoreDiagnostics(stage: _contract.stage, write: emit);
    store = PlatformSecureStore(
      brandId: _contract.namespace,
      storage: UpdateQaObservedStorage(diagnostics!),
    );
    if (_contract.stage == '2') {
      await verifyV2();
      return;
    }
    phase = 'initialStore';
    _require(
      await read(UpdateQaStoreOperation.initialRead) == null,
      _Failure.store,
    );
    keyOwned = true;
    await diagnostics!.run(
      UpdateQaStoreOperation.initialWrite,
      () => store!.write(_key, value('1')).timeout(const Duration(seconds: 15)),
    );
    _require(
      await read(UpdateQaStoreOperation.initialVerify) == value('1'),
      _Failure.store,
    );
    await emit('ready-1.json', {
      ...context,
      'synthetic_created_verified': true,
    });
    phase = 'installArm';
    _status.value = 'Synthetic storage verified; waiting for update arm';
    await waitControl(AndroidUpdateQaAction.install);
    await installV2();
  }

  Future<void> verifyV2() async {
    phase = 'crossStore';
    // The admitted second stage owns the same single fixture namespace as V1.
    // A failed native read must not be reported as confirmed synthetic cleanup.
    keyOwned = true;
    _require(
      await read(UpdateQaStoreOperation.crossRead) == value('1'),
      _Failure.store,
    );
    await diagnostics!.run(
      UpdateQaStoreOperation.replacementWrite,
      () => store!.write(_key, value('2')).timeout(const Duration(seconds: 15)),
    );
    _require(
      await read(UpdateQaStoreOperation.replacementRead) == value('2'),
      _Failure.store,
    );
    await deleteKey();
    await emit('verified-2.json', {
      ...context,
      'canonical_identity': true,
      'synthetic_read': true,
      'synthetic_replace': true,
      'synthetic_delete': true,
    });
    phase = 'complete';
    _status.value = 'V2 read, replacement and deletion verified';
  }

  ReleaseManifest manifest(String stage) => ReleaseManifest(
    brand: 'example',
    version: '1.0.0-pre.$stage',
    build: 10000400 + int.parse(stage),
    publishedAt: 0,
    assets: const {},
  );

  Future<void> installV2() async {
    phase = 'archive';
    final one = file('v1.apk');
    final two = file('v2.apk');
    for (final apk in [one, two]) {
      _require(
        await FileSystemEntity.type(apk.path, followLinks: false) ==
                FileSystemEntityType.file &&
            await apk.resolveSymbolicLinks() == apk.path,
        _Failure.file,
      );
    }
    _require(await two.length() == _contract.v2Bytes, _Failure.archive);
    final hash = await _digest(two.path);
    _require(hash == _contract.v2Sha256, _Failure.archive);
    final old = await AndroidUpdateInstaller.channel
        .invokeMapMethod<String, Object?>('inspectArchive', {'path': one.path});
    final next = await AndroidUpdateInstaller.channel
        .invokeMapMethod<String, Object?>('inspectArchive', {'path': two.path});
    _require(
      old?['samePackage'] == true &&
          old?['sameSigner'] == true &&
          old?['newerVersion'] == false &&
          next?['samePackage'] == true &&
          next?['sameSigner'] == true &&
          next?['newerVersion'] == true,
      _Failure.archive,
    );
    await emit('archive-1.json', {
      ...context,
      'old_archive_bound': true,
      'next_archive_bound': true,
      'v2_hash_verified': true,
    });
    installer = AndroidUpdateInstaller();
    _require(!await installer!.canInstall(), _Failure.permission);
    phase = 'permission';
    _status.value = 'Waiting for the system source-permission UI';
    _require(
      await installer!.requestInstallPermission().timeout(
        const Duration(minutes: 3),
      ),
      _Failure.permission,
    );
    _require(await installer!.canInstall(), _Failure.permission);
    var oldRefused = false;
    try {
      await installer!
          .install(one, manifest: manifest('1'))
          .timeout(const Duration(seconds: 15));
    } on XcUpdateException catch (error) {
      oldRefused = error.code == XcUpdateException.packageMismatch;
    }
    _require(oldRefused, _Failure.oldVersion);
    await emit('permission-1.json', {
      ...context,
      'source_permission_verified': true,
      'same_version_refused': true,
    });
    phase = 'install';
    _status.value = 'Waiting for the real system update confirmation';
    await installer!.install(
      two,
      manifest: manifest('2'),
      onStage: (stage) {
        if (stage != InstallStage.awaitingUser || pendingWritten) return;
        pendingWritten = true;
        unawaited(
          emit('pending-user-1.json', {
            ...context,
            'native_pending_user': true,
          }).catchError((Object error) => fail(error)),
        );
      },
    );
    _status.value =
        'Installer returned; OS replacement remains independently checked';
  }

  Future<void> fail(Object error) async {
    if (failed) return;
    failed = true;
    final kind = switch (error) {
      AndroidUpdateQaRefused(:final reason) => 'contract.${reason.name}',
      _Refused(:final reason) => reason.name,
      TimeoutException() => 'timeout',
      PlatformException() => 'platform',
      FileSystemException() => 'fileSystem',
      XcUpdateException() => 'installer',
      _ => 'unknown',
    };
    _status.value = 'Component failed at $phase ($kind)';
    installer?.dispose();
    var cleaned = !keyOwned;
    try {
      await deleteKey();
      cleaned = !keyOwned;
    } on Object {
      cleaned = false;
    }
    if (scope != null) {
      try {
        await emit('failure-${_contract.stage}.json', {
          ...context,
          'phase': phase,
          'error_class': kind,
          'synthetic_cleanup_confirmed': cleaned,
        });
      } on Object {
        _status.value = 'Component failed; receipt or cleanup unconfirmed';
      }
    }
  }
}
