import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/xboard/core/crypto/crypto_exception.dart';
import 'package:fl_clash/xboard/update/update_exception.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:path/path.dart' as p;

class UpdateQaRefused implements Exception {
  const UpdateQaRefused(this.code);
  final String code;
}

void requireUpdateQa(bool allowed, String code) {
  if (!allowed) throw UpdateQaRefused(code);
}

bool updateQaReadFailed(String message, String key) =>
    message.contains('secure read failed for $key:');

enum UpdateQaCheckpoint {
  setup,
  bootstrap,
  secureStore,
  waitingArm,
  policyFetch,
  policyVerify,
  managerStart,
  helperStart,
  helperIdentity,
  exit,
}

enum UpdateQaExceptionKind {
  qaRefused,
  socket,
  handshake,
  http,
  process,
  format,
  state,
  type,
  timeout,
  fileSystem,
  crypto,
  update,
  unknown,
}

UpdateQaExceptionKind updateQaExceptionKind(Object error) => switch (error) {
  UpdateQaRefused() => UpdateQaExceptionKind.qaRefused,
  SocketException() => UpdateQaExceptionKind.socket,
  HandshakeException() => UpdateQaExceptionKind.handshake,
  HttpException() => UpdateQaExceptionKind.http,
  ProcessException() => UpdateQaExceptionKind.process,
  FormatException() => UpdateQaExceptionKind.format,
  StateError() => UpdateQaExceptionKind.state,
  TypeError() => UpdateQaExceptionKind.type,
  TimeoutException() => UpdateQaExceptionKind.timeout,
  FileSystemException() => UpdateQaExceptionKind.fileSystem,
  XcCryptoException() => UpdateQaExceptionKind.crypto,
  XcUpdateException() => UpdateQaExceptionKind.update,
  _ => UpdateQaExceptionKind.unknown,
};

const _updateErrorCodes = {
  XcUpdateException.noReleaseUrls,
  XcUpdateException.releaseFetch,
  XcUpdateException.releaseInvalid,
  XcUpdateException.notNewer,
  XcUpdateException.noAsset,
  XcUpdateException.download,
  XcUpdateException.size,
  XcUpdateException.checksum,
  XcUpdateException.permission,
  XcUpdateException.packageMismatch,
  XcUpdateException.install,
  XcUpdateException.aborted,
  XcUpdateException.signature,
  XcUpdateException.unsupported,
};

Map<String, Object?> updateQaFailureReceipt(
  Object error, {
  required bool cleaned,
  XcUpdateState? update,
  UpdateQaCheckpoint checkpoint = UpdateQaCheckpoint.setup,
  UpdateQaExceptionKind? cause,
}) => {
  'success': false,
  'cleanup_verified': cleaned,
  'error_class': error is UpdateQaRefused
      ? error.code
      : 'native_update_app_error',
  'checkpoint': checkpoint.name,
  'exception_kind': (cause ?? updateQaExceptionKind(error)).name,
  if (update != null)
    'update': {
      'phase': update.phase.name,
      'error_code': update.error == null
          ? null
          : _updateErrorCodes.contains(update.error!.code)
          ? update.error!.code
          : 'unknown',
      'force_active': update.isForced,
      'received': update.received,
      'total': update.total,
      'has_manifest': update.manifest != null,
    },
};

Future<Never> requestUpdateQaExit({
  required Future<void> Function() request,
  required Future<void> Function(String code) recordFailure,
  required Never Function(int code) terminate,
}) async {
  var code = 'production_exit_returned';
  try {
    await request();
  } catch (_) {
    code = 'production_exit_failed';
  }
  try {
    await recordFailure(code);
  } finally {
    terminate(1);
  }
}

class UpdateQaContract {
  const UpdateQaContract({
    required this.nonce,
    required this.job,
    required this.output,
    required this.stage,
  });

  final String nonce;
  final String job;
  final String output;
  final String stage;

  String get version => '1.0.0-pre.$stage';
  String get build => stage == '1' ? '10000401' : '10000402';
  String get namespace => 'q${nonce.substring(0, 12)}';
  String get synthetic => 'update-qa-$nonce';

  void validate({
    required bool safe,
    required String brand,
    required String executable,
    required Map<String, Object?> config,
  }) {
    requireUpdateQa(safe && brand == 'example', 'safe_example_required');
    requireUpdateQa(
      RegExp(r'^[0-9a-f]{32}$').hasMatch(nonce) &&
          (stage == '1' || stage == '2'),
      'compiled_identity_invalid',
    );
    requireUpdateQa(
      p.isAbsolute(output) && p.normalize(output) == output,
      'output_invalid',
    );
    requireUpdateQa(
      config['nonce'] == nonce &&
          config['job'] == job &&
          config['output'] == output,
      'job_config_mismatch',
    );
    requireUpdateQa(
      config['installed_executable'] == executable &&
          p.isWithin(output, executable),
      'installed_owner_required',
    );
  }

  void validateLease(
    Map<String, Object?> lease, {
    required int pid,
    required String executable,
    required String sha256,
  }) {
    requireUpdateQa(
      lease['nonce'] == nonce &&
          lease['job'] == job &&
          lease['pid'] == pid &&
          lease['executable'] == executable &&
          lease['executable_sha256'] == sha256,
      'launch_lease_mismatch',
    );
  }

  Map<String, Object?> decode(String raw) =>
      Map<String, Object?>.from(jsonDecode(raw) as Map);

  String get installedExecutable =>
      p.join(output, 'private', 'installed', 'ExampleClient.exe');
}
