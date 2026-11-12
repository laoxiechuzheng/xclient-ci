import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:fl_clash/common/constant.dart';
import 'package:fl_clash/main.dart' as application;
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/state.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:fl_clash/xboard/providers.dart' show xcRuntimeProvider;
import 'package:fl_clash/xboard/update/download.dart';
import 'package:fl_clash/xboard/update/install/macos_installer.dart';
import 'package:fl_clash/xboard/update/install/installer.dart'
    show spawnUpdateHelper;
import 'package:fl_clash/xboard/update/install/windows_installer.dart';
import 'package:fl_clash/xboard/update/update_http.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/version.dart';
import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:package_info_plus/package_info_plus.dart';

import 'update_qa_contract.dart';
import 'update_store_observer.dart';

const _contract = UpdateQaContract(
  nonce: String.fromEnvironment('XC_UPDATE_QA_NONCE'),
  job: String.fromEnvironment('XC_UPDATE_QA_JOB'),
  output: String.fromEnvironment('XC_UPDATE_QA_OUTPUT'),
  stage: String.fromEnvironment('XC_UPDATE_QA_STAGE'),
);

Future<String> _digest(String path) =>
    Isolate.run(() => sha256OfFile(File(path)));

Future<void> _writeNew(String path, Map<String, Object?> value) async {
  final file = File(path);
  requireUpdateQa(
    await FileSystemEntity.type(path, followLinks: false) ==
        FileSystemEntityType.notFound,
    'new_receipt_required',
  );
  final temporary = File('$path.next');
  await temporary.create(exclusive: true);
  await temporary.writeAsString(jsonEncode(value), flush: true);
  await temporary.rename(file.path);
}

Future<Map<String, Object?>> _waitJson(String path) async {
  final deadline = DateTime.now().add(const Duration(seconds: 60));
  final file = File(path);
  while (DateTime.now().isBefore(deadline)) {
    if (await file.exists()) {
      requireUpdateQa(
        await FileSystemEntity.type(path, followLinks: false) ==
            FileSystemEntityType.file,
        'regular_control_file_required',
      );
      return _contract.decode(await file.readAsString());
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  throw const UpdateQaRefused('controller_deadline');
}

class _UpdateQa {
  final executable = Platform.resolvedExecutable;
  final brand = BrandConfig.fromEnvironment();
  final private = p.join(_contract.output, 'private');
  final receipts = p.join(_contract.output, 'receipts');
  late final PlatformSecureStore store;
  late final UpdateQaStoreDiagnostics storeDiagnostics;
  XcUpdateManager? manager;
  Timer? stopWatch;
  bool ownsKey = false;
  bool exiting = false;
  bool admitted = false;
  bool normalStarted = false;
  bool stopHandling = false;
  var checkpoint = UpdateQaCheckpoint.setup;
  UpdateQaExceptionKind? operationCause;
  static const key = 'qa.update';

  Future<String?> _read(UpdateQaStoreOperation operation) =>
      storeDiagnostics.run(operation, _readObserved);

  Future<String?> _readObserved() async {
    var readFailed = false;
    final previous = xcLogSink;
    xcLogSink = (message, {required warn}) {
      if (updateQaReadFailed(message, key)) {
        readFailed = true;
      }
      previous?.call(message, warn: warn);
    };
    try {
      final value = await store.read(key).timeout(const Duration(seconds: 15));
      requireUpdateQa(!readFailed, 'native_secure_read_failed');
      return value;
    } finally {
      xcLogSink = previous;
    }
  }

  Future<void> _cleanupKey() async {
    if (!ownsKey) return;
    await storeDiagnostics.run(
      UpdateQaStoreOperation.cleanupDelete,
      () => store.delete(key).timeout(const Duration(seconds: 15)),
    );
    requireUpdateQa(
      await _read(UpdateQaStoreOperation.cleanupRead) == null,
      'native_secure_cleanup_failed',
    );
    ownsKey = false;
  }

  Future<void> _exit() async {
    if (exiting) return;
    exiting = true;
    checkpoint = UpdateQaCheckpoint.exit;
    stopWatch?.cancel();
    manager?.dispose();
    if (!admitted) exit(1);
    await _writeNew(p.join(receipts, 'exit-${_contract.stage}.json'), {
      'production_exit_requested': normalStarted,
    });
    if (normalStarted) {
      await requestUpdateQaExit(
        request: () async {
          try {
            await globalState.container
                .read(systemActionProvider.notifier)
                .handleExit();
          } catch (error) {
            operationCause = updateQaExceptionKind(error);
            rethrow;
          }
        },
        recordFailure: (code) async {
          try {
            await File(
              p.join(receipts, 'exit-${_contract.stage}.json'),
            ).delete();
          } finally {
            final failure = p.join(receipts, 'failure.json');
            if (await FileSystemEntity.type(failure, followLinks: false) ==
                FileSystemEntityType.notFound) {
              await _writeNew(
                failure,
                updateQaFailureReceipt(
                  UpdateQaRefused(code),
                  cleaned: false,
                  update: manager?.state,
                  checkpoint: checkpoint,
                  cause: operationCause,
                ),
              );
            }
          }
        },
        terminate: exit,
      );
    }
    exit(1);
  }

  Future<void> _watchStop() async {
    if (exiting ||
        stopHandling ||
        !await File(p.join(private, 'stop.json')).exists()) {
      return;
    }
    stopHandling = true;
    try {
      requireUpdateQa(
        _contract.decode(
              await File(p.join(private, 'stop.json')).readAsString(),
            )['nonce'] ==
            _contract.nonce,
        'stop_owner_mismatch',
      );
      await _cleanupKey();
      await _exit();
    } catch (error) {
      await fail(error);
    }
  }

  Future<void> _start(String executable, List<String> arguments) async {
    checkpoint = UpdateQaCheckpoint.helperStart;
    try {
      await _startHelper(executable, arguments);
    } catch (error) {
      operationCause = updateQaExceptionKind(error);
      rethrow;
    }
  }

  Future<void> _startHelper(String executable, List<String> arguments) async {
    final expected = Platform.isWindows
        ? WindowsUpdateInstaller.powerShellPath
        : '/bin/sh';
    requireUpdateQa(executable == expected, 'unexpected_helper');
    final process = await spawnUpdateHelper(executable, arguments);
    checkpoint = UpdateQaCheckpoint.helperIdentity;
    final Map<String, Object?> owner;
    if (Platform.isWindows) {
      final identityQuery =
          '\$p = Get-Process -Id ${process.pid} -ErrorAction Stop; '
          '[pscustomobject]@{pid=\$p.Id; executable=\$p.Path; '
          'started=\$p.StartTime.ToFileTimeUtc()} | ConvertTo-Json -Compress';
      final query = await Process.run(expected, [
        '-NoProfile',
        '-NonInteractive',
        '-WindowStyle',
        'Hidden',
        '-Command',
        identityQuery,
      ]);
      requireUpdateQa(query.exitCode == 0, 'helper_identity_unavailable');
      owner = _contract.decode('${query.stdout}');
    } else {
      final path = await Process.run('/bin/ps', [
        '-ww',
        '-p',
        '${process.pid}',
        '-o',
        'comm=',
      ]);
      final time = await Process.run('/bin/ps', [
        '-p',
        '${process.pid}',
        '-o',
        'lstart=',
      ]);
      requireUpdateQa(
        path.exitCode == 0 && time.exitCode == 0,
        'helper_identity_unavailable',
      );
      owner = {
        'pid': process.pid,
        'executable': '${path.stdout}'.trim(),
        'started': '${time.stdout}'.trim(),
      };
    }
    requireUpdateQa(
      owner['pid'] == process.pid &&
          p.equals(owner['executable'] as String, expected) &&
          '${owner['started']}'.isNotEmpty,
      'helper_owner_mismatch',
    );
    await _writeNew(p.join(receipts, 'helper.json'), {
      ...owner,
      'real_process_started': true,
      'force_active': manager?.forceActive == true,
    });
  }

  Future<void> run() async {
    requireUpdateQa(
      const bool.fromEnvironment('XC_UPDATE_QA') &&
          safeModeBuild &&
          (Platform.isWindows || Platform.isMacOS),
      'ci_safe_qa_required',
    );
    final configPath = p.join(private, 'app-config.json');
    requireUpdateQa(
      await _digest(configPath) ==
          const String.fromEnvironment('XC_UPDATE_QA_CONFIG_SHA256'),
      'compiled_config_changed',
    );
    final config = _contract.decode(await File(configPath).readAsString());
    _contract.validate(
      safe: safeModeBuild,
      brand: brand.brandId,
      executable: executable,
      config: config,
    );
    requireUpdateQa(
      await File(
            p.join(_contract.output, '.native-update-owned'),
          ).readAsString() ==
          _contract.nonce,
      'job_marker_mismatch',
    );
    admitted = true;
    if (_contract.stage == '1') {
      final env = Platform.environment;
      requireUpdateQa(
        env['GITHUB_ACTIONS'] == 'true' &&
            env['RUNNER_ENVIRONMENT'] == 'github-hosted' &&
            [
                  env['GITHUB_RUN_ID'],
                  env['GITHUB_RUN_ATTEMPT'],
                  env['GITHUB_JOB'],
                  env['GITHUB_SHA'],
                ].join(':') ==
                _contract.job,
        'github_hosted_job_required',
      );
    }
    final certificate = config['certificate'] as String;
    requireUpdateQa(
      p.isWithin(private, certificate) &&
          await _digest(certificate) == config['certificate_sha256'],
      'qa_certificate_changed',
    );
    SecurityContext.defaultContext.setTrustedCertificates(certificate);
    final binaryHash = await _digest(executable);
    await _writeNew(p.join(receipts, 'hello-${_contract.stage}.json'), {
      'pid': pid,
      'executable_sha256': binaryHash,
    });
    _contract.validateLease(
      await _waitJson(p.join(private, 'lease-${_contract.stage}.json')),
      pid: pid,
      executable: executable,
      sha256: binaryHash,
    );
    normalStarted = true;
    checkpoint = UpdateQaCheckpoint.bootstrap;
    application.main(const []);
    final deadline = DateTime.now().add(const Duration(seconds: 45));
    while (!globalState.isAttach) {
      requireUpdateQa(
        DateTime.now().isBefore(deadline),
        'normal_bootstrap_incomplete',
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    requireUpdateQa(
      globalState.container.read(initProvider),
      'normal_initialization_required',
    );
    final client = await ClientInfo.detect();
    final nativePackage = await PackageInfo.fromPlatform();
    requireUpdateQa(
      client.appVersion == _contract.version && client.build == _contract.build,
      'native_canonical_identity_mismatch',
    );
    requireUpdateQa(
      !Platform.isMacOS || nativePackage.packageName == 'com.xclient.example',
      'native_bundle_identity_mismatch',
    );
    await globalState.container
        .read(xcRuntimeProvider.future)
        .timeout(const Duration(seconds: 45));
    checkpoint = UpdateQaCheckpoint.secureStore;
    storeDiagnostics = UpdateQaStoreDiagnostics(
      stage: _contract.stage,
      write: (name, value) => _writeNew(p.join(receipts, name), value),
    );
    store = PlatformSecureStore(
      brandId: _contract.namespace,
      storage: UpdateQaObservedStorage(storeDiagnostics),
    );
    stopWatch = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => unawaited(_watchStop()),
    );
    if (_contract.stage == '2') {
      final ownership = await _waitJson(p.join(private, 'key-owned.json'));
      requireUpdateQa(
        ownership['nonce'] == _contract.nonce &&
            ownership['job'] == _contract.job,
        'synthetic_key_owner_mismatch',
      );
      ownsKey = true;
      requireUpdateQa(
        ownsKey &&
            await _read(UpdateQaStoreOperation.crossRead) ==
                _contract.synthetic,
        'cross_version_secure_read_failed',
      );
      await storeDiagnostics.run(
        UpdateQaStoreOperation.replacementWrite,
        () => store
            .write(key, '${_contract.synthetic}-replaced')
            .timeout(const Duration(seconds: 15)),
      );
      requireUpdateQa(
        await _read(UpdateQaStoreOperation.replacementRead) ==
            '${_contract.synthetic}-replaced',
        'cross_version_secure_replace_failed',
      );
      await _cleanupKey();
      await _writeNew(p.join(receipts, 'verified-2.json'), {
        'canonical_identity': true,
        'synthetic_read': true,
        'synthetic_replace': true,
        'synthetic_delete': true,
        'native_version': nativePackage.version,
        'native_build': nativePackage.buildNumber,
        'error_classes': <String>[],
      });
      return;
    }
    requireUpdateQa(
      await _read(UpdateQaStoreOperation.initialRead) == null,
      'preexisting_key_preserved',
    );
    await _writeNew(p.join(private, 'key-owned.json'), {
      'nonce': _contract.nonce,
      'job': _contract.job,
    });
    ownsKey = true;
    await storeDiagnostics.run(
      UpdateQaStoreOperation.initialWrite,
      () => store
          .write(key, _contract.synthetic)
          .timeout(const Duration(seconds: 15)),
    );
    requireUpdateQa(
      await _read(UpdateQaStoreOperation.initialVerify) == _contract.synthetic,
      'secure_write_failed',
    );
    await _writeNew(p.join(receipts, 'ready-1.json'), {
      'canonical_identity': true,
      'synthetic_write': true,
      'native_version': nativePackage.version,
      'native_build': nativePackage.buildNumber,
    });
    checkpoint = UpdateQaCheckpoint.waitingArm;
    requireUpdateQa(
      (await _waitJson(p.join(private, 'arm.json')))['nonce'] ==
          _contract.nonce,
      'controller_arm_mismatch',
    );
    final userAgent = buildUserAgent(
      client.uaParts(
        brandId: brand.brandId,
        coreVersion: brand.coreVersion,
        product: brand.uaProduct,
      ),
    );
    final policyHttp = IoUpdateHttp(userAgent: userAgent);
    late final XcPolicy policy;
    checkpoint = UpdateQaCheckpoint.policyFetch;
    try {
      final uri = Uri.parse(config['policy_url'] as String);
      requireUpdateQa(
        uri.scheme == 'https' && uri.host == 'localhost',
        'loopback_https_required',
      );
      final response = await policyHttp
          .get(uri)
          .timeout(const Duration(seconds: 20));
      try {
        requireUpdateQa(response.statusCode == 200, 'policy_http_failed');
        final data = <int>[];
        await for (final chunk in response.body.timeout(
          const Duration(seconds: 15),
        )) {
          data.addAll(chunk);
          requireUpdateQa(data.length <= 65536, 'policy_too_large');
        }
        checkpoint = UpdateQaCheckpoint.policyVerify;
        policy = await verifyPolicyDoc(
          Map<String, dynamic>.from(jsonDecode(utf8.decode(data)) as Map),
          ctrlKeys: brand.ctrlKeys,
          brandId: brand.brandId,
        );
      } finally {
        response.cancel();
      }
    } finally {
      policyHttp.close();
    }
    final installer = Platform.isWindows
        ? WindowsUpdateInstaller(exitApp: _exit, start: _start)
        : MacosUpdateInstaller(exitApp: _exit, start: _start);
    manager = XcUpdateManager(
      brand: brand,
      current: AppVersion.fromParts(client.appVersion, client.build)!,
      platform: client.platform,
      arch: client.arch,
      http: IoUpdateHttp(userAgent: userAgent),
      installer: installer,
      throttle: UpdateNoticeThrottle(MemoryUpdateNoticeStore()),
      workDir: () async => Directory(p.join(private, 'downloads')),
    );
    checkpoint = UpdateQaCheckpoint.managerStart;
    await manager!.onPolicy(policy);
    requireUpdateQa(manager!.forceActive, 'forced_manager_required');
    await manager!.start();
    if (!exiting) throw const UpdateQaRefused('native_handoff_did_not_exit');
  }

  Future<void> fail(Object error) async {
    final updateState = manager?.state;
    final failedCheckpoint = checkpoint;
    final failedCause = operationCause;
    var cleaned = false;
    try {
      await _cleanupKey();
      cleaned = !ownsKey;
    } catch (_) {
      cleaned = false;
    }
    if (admitted &&
        p.isAbsolute(_contract.output) &&
        await Directory(receipts).exists() &&
        !await File(p.join(receipts, 'failure.json')).exists()) {
      await _writeNew(
        p.join(receipts, 'failure.json'),
        updateQaFailureReceipt(
          error,
          cleaned: cleaned,
          update: updateState,
          checkpoint: failedCheckpoint,
          cause: failedCause,
        ),
      );
    }
    await _exit();
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final qa = _UpdateQa();
  try {
    await qa.run();
  } catch (error) {
    await qa.fail(error);
  }
}
