import 'dart:async';
import 'dart:io';

import 'package:fl_clash/common/common.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart';

import '../core/ua.dart';
import '../providers.dart';
import 'install/android_installer.dart';
import 'install/installer.dart';
import 'install/macos_installer.dart';
import 'install/windows_installer.dart';
import 'update_http.dart';
import 'update_manager.dart';
import 'update_policy.dart';
import 'version.dart';

class XcUpdateFlag extends Notifier<bool> {
  @override
  bool build() => false;
  void set(bool value) => state = value;
}

final xcAndroidActivityProvider = NotifierProvider<XcUpdateFlag, bool>(
  XcUpdateFlag.new,
);
final xcUpdateOpenRequestedProvider = NotifierProvider<XcUpdateFlag, bool>(
  XcUpdateFlag.new,
);

final xcUpdateUiReadyProvider = Provider<bool>(
  (ref) =>
      ref.watch(appVisibleProvider) &&
      !ref.watch(xcClosingProvider) &&
      (!ref.watch(xcManagedAndroidProvider) ||
          ref.watch(xcAndroidActivityProvider)),
);

const _androidUpdateChannel = MethodChannel('xclient/update');

Future<void> notifyAndroidUpdateAction(String? kind) async {
  try {
    if (kind == null) {
      await _androidUpdateChannel.invokeMethod<bool>('clearUpdateAction');
    } else {
      await _androidUpdateChannel.invokeMethod<bool>('notifyUpdateAction', {
        'kind': kind,
      });
    }
  } on Object {
    return;
  }
}

XcPlatformInstaller _installerFor(
  Ref ref,
  XcPlatform platform,
  BrandConfig brand,
) {
  Future<void> exitApp() =>
      ref.read(systemActionProvider.notifier).handleExit();
  return switch (platform) {
    XcPlatform.android => AndroidUpdateInstaller(),
    XcPlatform.windows => WindowsUpdateInstaller(exitApp: exitApp),
    XcPlatform.macos => MacosUpdateInstaller(
      exitApp: exitApp,
      downloadPage: brand.panelWebUrl,
    ),
  };
}

/// Mount at app startup so forced updates run without opening the update page.
final xcUpdateManagerProvider = Provider<XcUpdateManager?>((ref) {
  if (ref.read(xcRuntimeShutdownProvider).isClosed) return null;
  final runtime = ref.watch(xcRuntimeProvider).value;
  if (runtime == null) return null;
  final client = runtime.client;
  final manager = XcUpdateManager(
    brand: runtime.brand,
    current:
        AppVersion.fromParts(client.appVersion, client.build) ??
        const AppVersion(0, 0, 0),
    platform: client.platform,
    arch: client.arch,
    http: IoUpdateHttp(
      userAgent: runtime.userAgent,
      connector: ref.watch(xcDirectConnectorProvider),
    ),
    installer: _installerFor(ref, client.platform, runtime.brand),
    throttle: UpdateNoticeThrottle(const PrefsUpdateNoticeStore()),
    workDir: () async => Directory(join(await appPath.tempPath, 'xc-update')),
  );
  ref.onDispose(manager.dispose);
  ref.listen<XcPolicy?>(
    xcPolicyProvider,
    (_, policy) => unawaited(manager.onPolicy(policy)),
  );
  unawaited(
    manager.cleanupPackages().then(
      (_) => manager.onPolicy(ref.read(xcPolicyProvider)),
    ),
  );
  return manager;
});

final xcUpdateStateProvider = StreamProvider<XcUpdateState>((ref) async* {
  final manager = ref.watch(xcUpdateManagerProvider);
  if (manager == null) {
    yield const XcUpdateState();
    return;
  }
  yield manager.state;
  yield* manager.changes;
});

/// Gate connections and stop a running core; account, purchase and ticket pages remain usable.
final xcForceUpdateActiveProvider = Provider<bool>((ref) {
  final state = ref.watch(xcUpdateStateProvider).value;
  final policy = ref.watch(xcPolicyProvider);
  final current = ref.watch(xcCurrentVersionProvider);
  final version = current == null ? null : AppVersion.tryParse(current);
  return state?.isForced == true ||
      (version != null && decideUpdate(policy, version).isForced);
});

final xcCurrentVersionProvider = Provider<String?>((ref) {
  final client = ref.watch(xcRuntimeProvider).value?.client;
  if (client == null) return null;
  return client.build.isEmpty
      ? client.appVersion
      : '${client.appVersion}+${client.build}';
});
