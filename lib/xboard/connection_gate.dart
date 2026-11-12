import 'package:fl_clash/providers/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'update/update_providers.dart';
import 'update/update_policy.dart';
import 'update/version.dart';

String? xcConnectionBlockNow(Ref ref) {
  if (ref.read(xcClosingProvider)) return '客户端正在断开连接并退出';
  final observed = ref.read(xcConnectionBlockProvider);
  if (observed != null || !BrandConfig.isBranded) return observed;
  final runtime = ref.read(xcRuntimeProvider).value;
  if (runtime == null) return '正在等待账号安全初始化';
  final session = runtime.session.state;
  if (!session.isLoggedIn) return '请先登录账号';
  if (!session.deviceRegistered) return session.message ?? '请先完成设备注册';
  final policy = runtime.poller.state;
  final current = AppVersion.fromParts(
    runtime.client.appVersion,
    runtime.client.build,
  );
  if (current == null || decideUpdate(policy.policy, current).isForced) {
    return '请完成客户端更新后再连接';
  }
  if (!policy.canConnect) return policy.connectionMessage;
  final sync = runtime.sync.status;
  if (sync.phase == SyncPhase.blocked) return sync.message ?? '当前订阅不可用';
  if (sync.lastSuccess == null) return '正在安全应用账号节点，请稍后连接';
  return null;
}

final xcConnectionBlockProvider = Provider<String?>((ref) {
  if (ref.watch(xcClosingProvider)) return '客户端正在断开连接并退出';
  if (!BrandConfig.isBranded) return null;
  if (!ref.watch(initProvider)) return '客户端正在初始化';
  if (ref.watch(xcForceUpdateActiveProvider)) return '请完成客户端更新后再连接';
  final session = ref.watch(xcSessionProvider).value;
  if (session == null || !session.isLoggedIn) return '请先登录账号';
  if (!session.deviceRegistered) {
    return session.message ?? '请先完成设备注册';
  }
  final policy = ref.watch(xcRemoteStateProvider).value;
  if (policy?.canConnect != true) {
    return policy?.connectionMessage ?? '正在等待安全核验客户端版本';
  }
  final managedId = ref.watch(xcManagedProfileIdProvider).value;
  if (managedId == null || ref.watch(currentProfileIdProvider) != managedId) {
    return '正在同步账号节点，请稍后连接';
  }
  final sync = ref.watch(xcSyncStatusProvider).value;
  if (sync?.phase == SyncPhase.blocked) return sync?.message ?? '当前订阅不可用';
  if (sync?.lastSuccess == null) return '正在安全应用账号节点，请稍后连接';
  return null;
});

final xcConnectionMustStopProvider = Provider<bool>((ref) {
  if (!BrandConfig.isBranded) return false;
  if (ref.watch(xcForceUpdateActiveProvider)) return true;
  final session = ref.watch(xcSessionProvider).value;
  if (session != null && !session.isLoggedIn) return true;
  return ref.watch(xcSyncStatusProvider).value?.phase == SyncPhase.blocked;
});
