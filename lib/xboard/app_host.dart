import 'dart:async';

import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import 'lifecycle.dart';
import 'probe/settings_tile.dart';
import 'providers.dart';
import 'ui/common/exit_action.dart';
import 'ui/login.dart';
import 'ui/shell.dart';
import 'update/update_widgets.dart';

class XcAppHost extends ConsumerWidget {
  const XcAppHost({super.key, this.startupFailed = false, this.onRetry});

  final bool startupFailed;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(xcClosingProvider)) {
      final canRetry = ref.watch(xcExitRetryProvider);
      return PopScope(
        canPop: false,
        child: Scaffold(
          body: XcClosingPanel(
            onRetry: canRetry
                ? () {
                    unawaited(
                      ref
                          .read(systemActionProvider.notifier)
                          .handleExit()
                          .catchError((Object _) {}),
                    );
                  }
                : null,
          ),
        ),
      );
    }
    if (!ref.watch(initProvider)) {
      if (startupFailed) {
        return XcRootBackScope(
          child: Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 16,
                  children: [
                    const Text('客户端初始化未完成'),
                    const Text('若系统中仍有本客户端的 VPN 连接，请先在系统设置中停止，再重试。'),
                    FilledButton(
                      onPressed: onRetry,
                      child: const Text('重新初始化'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }
      return const XcRootBackScope(
        child: Scaffold(body: Center(child: CommonCircleLoading())),
      );
    }
    ref.watch(xcLifecycleBindingProvider);
    final policy = ref.watch(xcRemoteStateProvider).value;
    final session = ref.watch(xcSessionProvider).value;
    return Column(
      children: [
        if (session?.isLoggedIn == true &&
            session?.deviceRegistered == true &&
            policy?.canConnect != true)
          XcPolicyAdmissionBanner(
            state: policy,
            onRetry: () => ref.read(xcActionsProvider).pollState(),
          ),
        Expanded(
          child: XcUpdateHost(
            child: XcAuthGate(
              child: XcAppShell(
                settingsTiles: [
                  const XcProbeSettingsTile(),
                  const XcUpdateTile(),
                  if (ref.watch(xcManagedAndroidProvider)) const XcExitAction(),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class XcClosingPanel extends StatelessWidget {
  const XcClosingPanel({super.key, this.onRetry});
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        spacing: 20,
        children: [
          if (onRetry == null) const CommonCircleLoading(),
          Text(onRetry == null ? '正在断开连接并退出' : '暂未确认退出状态'),
          const Text('停止连接后会安全释放客户端。'),
          if (onRetry != null)
            FilledButton(onPressed: onRetry, child: const Text('重试退出')),
        ],
      ),
    ),
  );
}

class XcPolicyAdmissionBanner extends StatelessWidget {
  const XcPolicyAdmissionBanner({super.key, this.state, required this.onRetry});
  final RemoteState? state;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => SafeArea(
    bottom: false,
    child: MaterialBanner(
      content: Text(state?.connectionMessage ?? '正在等待安全核验客户端版本'),
      actions: [
        TextButton(
          onPressed: state?.phase == PolicyCheckPhase.checking ? null : onRetry,
          child: const Text('重试版本核验'),
        ),
      ],
    ),
  );
}
