import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/crypto/crypto_exception.dart';
import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:fl_clash/xboard/update/install/installer.dart';
import 'package:fl_clash/xboard/update/update_exception.dart';
import 'package:fl_clash/xboard/update/update_http.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/version.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'update_qa_contract.dart';

class _Terminated implements Exception {
  const _Terminated(this.code);
  final int code;
}

class _HeldHttp implements UpdateHttp {
  final reply = Completer<UpdateHttpResponse>();
  var requests = 0;

  @override
  Future<UpdateHttpResponse> get(Uri uri) {
    requests++;
    return reply.future;
  }

  @override
  void close() {}
}

class _UnusedInstaller implements XcPlatformInstaller {
  @override
  String get extension => 'exe';

  @override
  Future<bool> canInstall() async => true;

  @override
  Future<bool> requestInstallPermission() async => true;

  @override
  Future<InstallOutcome> install(
    File file, {
    required ReleaseManifest manifest,
    InstallStageListener? onStage,
  }) => throw StateError('Unexpected native installation');
}

void main() {
  test(
    'forced auto start and explicit start share the actual pending run',
    () async {
      final http = _HeldHttp();
      final manager = XcUpdateManager(
        brand: const BrandConfig(brandId: 'example', displayName: 'Example'),
        current: AppVersion.tryParse('1.0.0-pre.1+10000401')!,
        platform: XcPlatform.windows,
        arch: 'x64',
        http: http,
        installer: _UnusedInstaller(),
        throttle: UpdateNoticeThrottle(MemoryUpdateNoticeStore()),
        workDir: () async => throw StateError('Unexpected package work'),
      );
      addTearDown(manager.dispose);
      await manager.onPolicy(
        const XcPolicy(
          brand: 'example',
          seq: 1,
          latest: '1.0.0-pre.2',
          minSupported: '1.0.0-pre.2',
          force: true,
          releaseUrls: ['https://localhost/fixture.json'],
        ),
      );
      final first = manager.start();
      final second = manager.start();
      expect(identical(first, second), isTrue);
      var returned = false;
      unawaited(first.then((_) => returned = true));
      await Future<void>.delayed(Duration.zero);
      expect(http.requests, 1);
      expect(returned, isFalse);
      expect(manager.state.phase, XcUpdatePhase.checking);
      http.reply.complete(
        UpdateHttpResponse(
          statusCode: 200,
          body: Stream.value(utf8.encode('{}')),
        ),
      );
      await first;
      expect(manager.state.phase, XcUpdatePhase.failed);
      expect(manager.state.error?.code, XcUpdateException.releaseInvalid);
      expect(
        updateQaFailureReceipt(
          const UpdateQaRefused('native_handoff_did_not_exit'),
          cleaned: true,
          update: manager.state,
        )['update'],
        {
          'phase': 'failed',
          'error_code': 'release_invalid',
          'force_active': true,
          'received': 0,
          'total': 0,
          'has_manifest': false,
        },
      );
    },
  );
  test(
    'diagnostics exclude arbitrary error codes, details, URLs and messages',
    () {
      const secret = 'SENSITIVE_TEST_VALUE';
      final result = updateQaFailureReceipt(
        const UpdateQaRefused('native_handoff_did_not_exit'),
        cleaned: false,
        update: const XcUpdateState(
          phase: XcUpdatePhase.failed,
          error: XcUpdateException(secret, secret),
          message: secret,
          received: 12,
          total: 23,
          manifest: ReleaseManifest(
            brand: secret,
            version: secret,
            build: 1,
            publishedAt: 1,
            assets: {
              'secret': ReleaseAsset(urls: [secret], sha256: secret, size: 1),
            },
          ),
        ),
      );
      expect(jsonEncode(result), isNot(contains(secret)));
      expect(result['update'], {
        'phase': 'failed',
        'error_code': 'unknown',
        'force_active': false,
        'received': 12,
        'total': 23,
        'has_manifest': true,
      });
      expect(updateQaFailureReceipt(StateError(secret), cleaned: false), {
        'success': false,
        'cleanup_verified': false,
        'error_class': 'native_update_app_error',
        'checkpoint': 'setup',
        'exception_kind': 'state',
      });
    },
  );
  test('fixed checkpoints and typed causes survive caught helper failure', () {
    const secret = 'SENSITIVE_TEST_VALUE';
    for (final (error, kind) in <(Object, UpdateQaExceptionKind)>[
      (const SocketException(secret), UpdateQaExceptionKind.socket),
      (const HandshakeException(secret), UpdateQaExceptionKind.handshake),
      (const HttpException(secret), UpdateQaExceptionKind.http),
      (
        const ProcessException(secret, [], secret),
        UpdateQaExceptionKind.process,
      ),
      (const FormatException(secret), UpdateQaExceptionKind.format),
      (StateError(secret), UpdateQaExceptionKind.state),
      (TimeoutException(secret), UpdateQaExceptionKind.timeout),
      (const FileSystemException(secret), UpdateQaExceptionKind.fileSystem),
      (const XcCryptoException(secret), UpdateQaExceptionKind.crypto),
      (const XcUpdateException(secret, secret), UpdateQaExceptionKind.update),
      (
        const UpdateQaRefused('fixture_refused'),
        UpdateQaExceptionKind.qaRefused,
      ),
      (Exception(secret), UpdateQaExceptionKind.unknown),
    ]) {
      expect(updateQaExceptionKind(error), kind);
    }
    final result = updateQaFailureReceipt(
      const UpdateQaRefused('native_handoff_did_not_exit'),
      cleaned: false,
      checkpoint: UpdateQaCheckpoint.helperIdentity,
      cause: UpdateQaExceptionKind.process,
      update: const XcUpdateState(
        phase: XcUpdatePhase.failed,
        error: XcUpdateException(XcUpdateException.install, secret),
      ),
    );
    expect(result['checkpoint'], 'helperIdentity');
    expect(result['exception_kind'], 'process');
    expect(jsonEncode(result), isNot(contains(secret)));
    expect((result['update'] as Map)['error_code'], 'install_failed');
  });
  for (final throws in [false, true]) {
    test(
      'production exit ${throws ? 'throw' : 'return'} records failure before nonzero termination',
      () async {
        final events = <String>[];
        final operation = requestUpdateQaExit(
          request: () async {
            events.add('requested');
            if (throws) throw StateError('exit failed');
          },
          recordFailure: (code) async => events.add(code),
          terminate: (code) {
            events.add('terminate:$code');
            throw _Terminated(code);
          },
        );
        await expectLater(
          operation,
          throwsA(
            isA<_Terminated>().having((value) => value.code, 'exit code', 1),
          ),
        );
        expect(events, [
          'requested',
          throws ? 'production_exit_failed' : 'production_exit_returned',
          'terminate:1',
        ]);
      },
    );
  }
  test('production-prefixed read failure cannot count as missing key', () {
    expect(
      updateQaReadFailed(
        '[xclient] secure read failed for qa.update: PlatformException',
        'qa.update',
      ),
      isTrue,
    );
    expect(
      updateQaReadFailed(
        '[xclient] secure read failed for xc.auth: PlatformException',
        'qa.update',
      ),
      isFalse,
    );
  });
  const nonce = 'aabbccddeeff00112233445566778899';
  final qa = UpdateQaContract(
    nonce: nonce,
    job: '12:1:update:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    output: p.normalize(p.absolute('out/update')),
    stage: '1',
  );
  final config = <String, Object?>{
    'nonce': qa.nonce,
    'job': qa.job,
    'output': qa.output,
    'installed_executable': qa.installedExecutable,
  };
  test(
    'unsafe, foreign and stale job inputs are rejected before bootstrap',
    () {
      for (final invalid in [
        () => qa.validate(
          safe: false,
          brand: 'example',
          executable: qa.installedExecutable,
          config: config,
        ),
        () => qa.validate(
          safe: true,
          brand: '98k',
          executable: qa.installedExecutable,
          config: config,
        ),
        () => qa.validate(
          safe: true,
          brand: 'example',
          executable: '/other/ExampleClient.exe',
          config: config,
        ),
        () => qa.validate(
          safe: true,
          brand: 'example',
          executable: qa.installedExecutable,
          config: {...config, 'nonce': 'other'},
        ),
      ]) {
        expect(invalid, throwsA(isA<UpdateQaRefused>()));
      }
      qa.validate(
        safe: true,
        brand: 'example',
        executable: qa.installedExecutable,
        config: config,
      );
    },
  );
  test('lease cannot grant a different PID, code or executable', () {
    final lease = {
      'pid': 7,
      'executable': qa.installedExecutable,
      'executable_sha256': 'f' * 64,
      'nonce': nonce,
      'job': qa.job,
    };
    qa.validateLease(
      lease,
      pid: 7,
      executable: qa.installedExecutable,
      sha256: 'f' * 64,
    );
    for (final invalid in [
      {...lease, 'pid': 8},
      {...lease, 'executable_sha256': 'e' * 64},
      {...lease, 'nonce': 'other'},
      {...lease, 'executable': '/other/ExampleClient.exe'},
    ]) {
      expect(
        () => qa.validateLease(
          invalid,
          pid: 7,
          executable: qa.installedExecutable,
          sha256: 'f' * 64,
        ),
        throwsA(isA<UpdateQaRefused>()),
      );
    }
  });
  test('synthetic namespace is bounded and distinct for each job nonce', () {
    expect(qa.namespace, 'qaabbccddeeff');
    expect(qa.build, '10000401');
    expect(qa.version, '1.0.0-pre.1');
  });
}
