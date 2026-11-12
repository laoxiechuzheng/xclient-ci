import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../brand/brand_config.dart';
import '../core/log.dart';
import '../core/sync/update_docs.dart';
import '../core/ua.dart';
import 'download.dart';
import 'install/installer.dart';
import 'release_fetch.dart';
import 'update_exception.dart';
import 'update_http.dart';
import 'update_policy.dart';
import 'version.dart';

enum XcUpdatePhase {
  idle,
  checking,
  downloading,

  needsPermission,
  installing,

  awaitingUser,

  restarting,

  manual,
  failed,
}

class XcUpdateState {
  final XcUpdatePhase phase;
  final UpdateDecision decision;
  final ReleaseManifest? manifest;
  final int received;
  final int total;

  final String? message;
  final XcUpdateException? error;

  /// The UI must call noticeShown after displaying a notice to start the 24h quiet period.
  final bool noticeDue;

  final DateTime? retryAt;

  const XcUpdateState({
    this.phase = XcUpdatePhase.idle,
    this.decision = UpdateDecision.none,
    this.manifest,
    this.received = 0,
    this.total = 0,
    this.message,
    this.error,
    this.noticeDue = false,
    this.retryAt,
  });

  bool get isForced => decision.isForced;

  bool get isBusy => switch (phase) {
    XcUpdatePhase.checking ||
    XcUpdatePhase.downloading ||
    XcUpdatePhase.installing ||
    XcUpdatePhase.awaitingUser ||
    XcUpdatePhase.restarting => true,
    _ => false,
  };

  double? get progress => total > 0 ? (received / total).clamp(0, 1) : null;

  XcUpdateState copyWith({
    XcUpdatePhase? phase,
    UpdateDecision? decision,
    ReleaseManifest? manifest,
    int? received,
    int? total,
    String? message,
    XcUpdateException? error,
    bool? noticeDue,
    DateTime? retryAt,
    bool clearMessage = false,
    bool clearRetry = false,
  }) => XcUpdateState(
    phase: phase ?? this.phase,
    decision: decision ?? this.decision,
    manifest: manifest ?? this.manifest,
    received: received ?? this.received,
    total: total ?? this.total,
    message: clearMessage ? null : (message ?? this.message),
    error: clearMessage ? null : (error ?? this.error),
    noticeDue: noticeDue ?? this.noticeDue,
    retryAt: clearRetry ? null : (retryAt ?? this.retryAt),
  );
}

class XcUpdateManager {
  final BrandConfig brand;
  final AppVersion current;
  final XcPlatform platform;
  final String arch;
  final UpdateHttp http;
  final XcPlatformInstaller installer;
  final UpdateNoticeThrottle throttle;

  final Future<Directory> Function() workDir;

  final Duration Function(int attempt) retryDelay;

  final _controller = StreamController<XcUpdateState>.broadcast();
  XcUpdateState _state = const XcUpdateState();
  Future<void>? _running;
  Timer? _retryTimer;
  int _failures = 0;
  bool _disposed = false;
  int _policyEpoch = 0;
  bool _restartForPolicy = false;

  XcUpdateManager({
    required this.brand,
    required this.current,
    required this.platform,
    required this.arch,
    required this.http,
    required this.installer,
    required this.throttle,
    required this.workDir,
    Duration Function(int attempt)? retryDelay,
  }) : retryDelay = retryDelay ?? defaultRetryDelay;

  static Duration defaultRetryDelay(int attempt) {
    const steps = [1, 2, 5, 10, 30];
    return Duration(minutes: steps[(attempt - 1).clamp(0, steps.length - 1)]);
  }

  XcUpdateState get state => _state;

  Stream<XcUpdateState> get changes => _controller.stream;

  /// Forced updates gate connections while account, purchase and ticket pages remain usable.
  bool get forceActive => _state.isForced;

  void _emit(XcUpdateState next) {
    if (_disposed) return;
    _state = next;
    _controller.add(next);
  }

  Future<void> onPolicy(XcPolicy? policy) async {
    if (_disposed || policy == null) return;
    final decision = decideUpdate(policy, current);
    final previous = _state.decision;
    final sameTarget =
        previous.mode == decision.mode && previous.latest == decision.latest;
    final changed = !sameTarget || previous.policy?.seq != policy.seq;
    if (changed) {
      _policyEpoch++;
      _retryTimer?.cancel();
      _restartForPolicy = _running != null && decision.isForced;
    }
    if (!decision.hasUpdate) {
      _retryTimer?.cancel();
      _emit(
        XcUpdateState(
          phase: _running == null ? XcUpdatePhase.idle : _state.phase,
          decision: decision,
        ),
      );
      return;
    }
    if (changed) {
      _failures = 0;
      _emit(
        _state.copyWith(
          phase: _running == null ? XcUpdatePhase.idle : null,
          decision: decision,
          noticeDue: false,
          clearMessage: _running == null,
          clearRetry: true,
        ),
      );
    }
    if (decision.isForced) {
      // Retry failures on the timer; permission/manual states await the user, not a repeated policy.
      if (_running == null && (changed || _state.phase == XcUpdatePhase.idle)) {
        unawaited(start());
      }
      return;
    }
    final epoch = _policyEpoch;
    if (_running == null &&
        !_state.noticeDue &&
        _state.phase == XcUpdatePhase.idle &&
        await throttle.shouldNotify(decision.latest) &&
        epoch == _policyEpoch) {
      _emit(_state.copyWith(noticeDue: true));
    }
  }

  Future<void> noticeShown() async {
    final latest = _state.decision.latest;
    _emit(_state.copyWith(noticeDue: false));
    if (latest.isNotEmpty) await throttle.markNotified(latest);
  }

  /// Concurrent update requests share one run.
  Future<void> start() {
    if (_disposed || !_state.decision.hasUpdate) return Future.value();
    _retryTimer?.cancel();
    return _running ??= _run().whenComplete(() {
      _running = null;
      if (_restartForPolicy && !_disposed) {
        _restartForPolicy = false;
        unawaited(start());
      }
    });
  }

  Future<void> grantPermission() async {
    final granted = await installer.requestInstallPermission();
    if (granted) {
      await start();
    } else {
      _emit(
        _state.copyWith(
          phase: XcUpdatePhase.needsPermission,
          error: const XcUpdateException(XcUpdateException.permission),
          message: const XcUpdateException(
            XcUpdateException.permission,
          ).displayMessage,
        ),
      );
    }
  }

  Future<void> _run() async {
    final epoch = _policyEpoch;
    bool currentPolicy() => !_disposed && epoch == _policyEpoch;
    final decision = _state.decision;
    final policy = decision.policy;
    if (policy == null) return;
    _emit(
      _state.copyWith(
        phase: XcUpdatePhase.checking,
        noticeDue: false,
        received: 0,
        total: 0,
        clearMessage: true,
        clearRetry: true,
      ),
    );
    try {
      final manifest = await fetchReleaseManifest(
        urls: policy.releaseUrls,
        http: http,
        relKeys: brand.relKeys,
        brandId: brand.brandId,
        expectedVersion: policy.latest,
      );
      if (!currentPolicy()) return;
      ensureNewer(manifest, current);
      final selected = selectAsset(manifest, platform, arch);
      _emit(
        _state.copyWith(
          phase: XcUpdatePhase.downloading,
          manifest: manifest,
          total: selected.asset.size,
        ),
      );
      final dir = await workDir();
      var shown = -1;
      final file = await downloadVerified(
        asset: selected.asset,
        target: File(
          p.join(
            dir.path,
            packageFileName(
              brandId: brand.brandId,
              assetKey: selected.key,
              version: manifest.version,
              extension: installer.extension,
            ),
          ),
        ),
        http: http,
        isCancelled: () => !currentPolicy(),
        onProgress: (received, total) {
          // About 200 steps, not one event per network chunk.
          final step = total > 0 ? received * 200 ~/ total : 0;
          if (step == shown) return;
          shown = step;
          _emit(_state.copyWith(received: received, total: total));
        },
      );
      if (!currentPolicy()) return;
      if (!await installer.canInstall()) {
        _emit(
          _state.copyWith(
            phase: XcUpdatePhase.needsPermission,
            message: const XcUpdateException(
              XcUpdateException.permission,
            ).displayMessage,
          ),
        );
        return;
      }
      if (!currentPolicy()) return;
      _emit(_state.copyWith(phase: XcUpdatePhase.installing));
      final outcome = await installer.install(
        file,
        manifest: manifest,
        onStage: (stage) => _emit(
          _state.copyWith(
            phase: stage == InstallStage.awaitingUser
                ? XcUpdatePhase.awaitingUser
                : XcUpdatePhase.installing,
          ),
        ),
      );
      _failures = 0;
      switch (outcome) {
        case InstallOutcome.exiting:
        case InstallOutcome.installed:
          _emit(_state.copyWith(phase: XcUpdatePhase.restarting));
        case InstallOutcome.manual:
          _emit(
            _state.copyWith(
              phase: XcUpdatePhase.manual,
              message: '无法自动替换应用。已在访达中显示新版本安装包，请将其中的应用拖入“应用程序”文件夹替换旧版本。',
            ),
          );
      }
    } on XcUpdateException catch (error) {
      if (currentPolicy()) _fail(error);
    } catch (error) {
      if (currentPolicy()) {
        _fail(
          XcUpdateException(XcUpdateException.install, '${error.runtimeType}'),
        );
      }
    } finally {
      if (!currentPolicy() && !_disposed) {
        _emit(_state.copyWith(phase: XcUpdatePhase.idle));
      }
    }
  }

  void _fail(XcUpdateException error) {
    xcLog('update failed: $error', warn: true);
    _failures++;
    DateTime? retryAt;
    final permission = error.code == XcUpdateException.permission;
    if (_state.isForced && !permission) {
      final delay = retryDelay(_failures);
      retryAt = DateTime.now().add(delay);
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () => unawaited(start()));
    }
    _emit(
      _state.copyWith(
        phase: permission
            ? XcUpdatePhase.needsPermission
            : XcUpdatePhase.failed,
        error: error,
        message: error.displayMessage,
        retryAt: retryAt,
      ),
    );
  }

  /// cleanupPackages reads the version back from this name.
  static String packageFileName({
    required String brandId,
    required String assetKey,
    required String version,
    required String extension,
  }) => '$brandId-$assetKey-v$version.$extension';

  static final _packageVersion = RegExp(r'-v([0-9A-Za-z.+-]+)\.(apk|exe|zip)$');

  /// Run once at startup before any update; removes installed/older packages and stale .part files.
  Future<void> cleanupPackages() async {
    try {
      final dir = await workDir();
      if (!await dir.exists()) return;
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        final match = _packageVersion.firstMatch(name);
        final version = match == null
            ? null
            : AppVersion.tryParse(match.group(1)!);
        final stale =
            name.endsWith('.part') ||
            (version != null && version.compareSemver(current) <= 0);
        if (stale && _running == null) await entity.delete();
      }
    } on FileSystemException catch (error) {
      xcLog('update cleanup failed: ${error.message}', warn: true);
    }
  }

  void dispose() {
    _disposed = true;
    _retryTimer?.cancel();
    http.close();
    final platformInstaller = installer;
    if (platformInstaller is DisposableUpdateInstaller) {
      (platformInstaller as DisposableUpdateInstaller).dispose();
    }
    unawaited(_controller.close());
  }
}
