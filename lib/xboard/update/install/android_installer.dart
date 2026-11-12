import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import '../../core/log.dart';
import '../../core/sync/update_docs.dart';
import '../update_exception.dart';
import 'installer.dart';

class AndroidInstallStatus {
  final int sessionId;

  final String status;
  final String message;

  const AndroidInstallStatus(this.sessionId, this.status, this.message);

  bool get isTerminal => status != 'pending_user';
}

/// Native PackageInstaller checks package name and signing certificate before commit.
/// Unknown-app permission and confirmation remain system-controlled.
class AndroidUpdateInstaller
    implements XcPlatformInstaller, DisposableUpdateInstaller {
  static const channel = MethodChannel('xclient/update');

  final Duration confirmTimeout;

  final _statuses = StreamController<AndroidInstallStatus>.broadcast();
  Completer<AndroidInstallStatus>? _activeInstall;

  AndroidUpdateInstaller({this.confirmTimeout = const Duration(minutes: 15)}) {
    channel.setMethodCallHandler(_onCall);
  }

  Future<Object?> _onCall(MethodCall call) async {
    if (call.method != 'onInstallStatus') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    _statuses.add(
      AndroidInstallStatus(
        (args['sessionId'] as num?)?.toInt() ?? -1,
        '${args['status'] ?? 'failure'}',
        '${args['message'] ?? ''}',
      ),
    );
    return null;
  }

  @override
  String get extension => 'apk';

  @override
  Future<bool> canInstall() async =>
      await channel.invokeMethod<bool>('canInstall') ?? false;

  @override
  Future<bool> requestInstallPermission() async =>
      await channel.invokeMethod<bool>('openInstallSettings') ?? false;

  @override
  Future<InstallOutcome> install(
    File file, {
    required ReleaseManifest manifest,
    InstallStageListener? onStage,
  }) async {
    if (!await canInstall()) {
      throw const XcUpdateException(XcUpdateException.permission);
    }
    onStage?.call(InstallStage.preparing);
    final info = await channel.invokeMapMethod<String, Object?>(
      'inspectArchive',
      {'path': file.path},
    );
    if (info == null || info['samePackage'] != true) {
      throw const XcUpdateException(
        XcUpdateException.packageMismatch,
        'package',
      );
    }
    if (info['sameSigner'] != true || info['newerVersion'] != true) {
      throw const XcUpdateException(
        XcUpdateException.packageMismatch,
        'signer',
      );
    }
    final pending = <AndroidInstallStatus>[];
    final terminal = Completer<AndroidInstallStatus>();
    _activeInstall = terminal;
    int? sessionId;
    final subscription = _statuses.stream.listen((status) {
      if (sessionId == null) {
        pending.add(status);
        return;
      }
      _route(status, sessionId, onStage, terminal);
    });
    try {
      final committedSessionId = await channel.invokeMethod<int>('install', {
        'path': file.path,
      });
      if (committedSessionId == null) {
        throw const XcUpdateException(XcUpdateException.install, 'session');
      }
      sessionId = committedSessionId;
      for (final status in pending) {
        _route(status, committedSessionId, onStage, terminal);
      }
      final result = await terminal.future.timeout(
        confirmTimeout,
        onTimeout: () => AndroidInstallStatus(
          committedSessionId,
          'aborted',
          'confirm timeout',
        ),
      );
      switch (result.status) {
        case 'success':
          return InstallOutcome.installed;
        case 'aborted':
          throw XcUpdateException(XcUpdateException.aborted, result.message);
        default:
          xcLog('android install failed: ${result.message}', warn: true);
          throw XcUpdateException(XcUpdateException.install, result.message);
      }
    } on PlatformException catch (error) {
      throw XcUpdateException(XcUpdateException.install, error.code);
    } finally {
      _activeInstall = null;
      await subscription.cancel();
    }
  }

  void _route(
    AndroidInstallStatus status,
    int sessionId,
    InstallStageListener? onStage,
    Completer<AndroidInstallStatus> terminal,
  ) {
    if (status.sessionId != sessionId) return;
    if (!status.isTerminal) {
      onStage?.call(InstallStage.awaitingUser);
    } else if (!terminal.isCompleted) {
      terminal.complete(status);
    }
  }

  @override
  void dispose() {
    final active = _activeInstall;
    if (active != null && !active.isCompleted) {
      active.complete(const AndroidInstallStatus(-1, 'aborted', 'disposed'));
    }
    channel.setMethodCallHandler(null);
    unawaited(_statuses.close());
  }
}
