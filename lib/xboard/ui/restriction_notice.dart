import 'dart:async';

import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:material_ui/material_ui.dart';

import '../core/sync/subscription_sync.dart';
import 'common/widgets.dart';

const _restrictionTitle = '节点获取受到限制';
const _restrictionAdvice = '请关闭其他代理或更换网络后重新检查；如仍受限，请核对套餐状态或联系客服。';
const _restrictionSafety = '客户端已禁止连接和使用旧节点。账户、套餐购买和工单仍可正常使用。';

class XcRestrictionNotice extends StatefulWidget {
  const XcRestrictionNotice({
    super.key,
    required this.status,
    required this.onCheck,
    required this.onPlans,
    required this.onTickets,
    this.now,
  });
  final SyncStatus status;
  final Future<void> Function() onCheck;
  final VoidCallback onPlans;
  final VoidCallback onTickets;
  final DateTime Function()? now;
  @override
  State<XcRestrictionNotice> createState() => _XcRestrictionNoticeState();
}

class _XcRestrictionNoticeState extends State<XcRestrictionNotice> {
  final _seen = <String>{};
  Timer? _clock;
  bool _promptOpen = false;
  BuildContext? _dialogContext;
  DateTime get _now => widget.now?.call() ?? DateTime.now();
  bool get _blocked => widget.status.phase == SyncPhase.blocked;
  String get _reason => widget.status.message ?? SyncMessages.blocked;
  int _seconds(DateTime? at) => at == null
      ? 0
      : ((at.difference(_now).inMilliseconds + 999) ~/ 1000).clamp(0, 86400);
  @override
  void initState() {
    super.initState();
    _updateClock();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _considerPrompt();
  }

  @override
  void didUpdateWidget(XcRestrictionNotice oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateClock();
    _considerPrompt();
  }

  void _updateClock() {
    _clock?.cancel();
    _clock = null;
    if (!_blocked) return;
    if (_seconds(widget.status.retryAt) == 0 &&
        _seconds(widget.status.nextSync) == 0) {
      return;
    }
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_seconds(widget.status.retryAt) == 0 &&
          _seconds(widget.status.nextSync) == 0) {
        _clock?.cancel();
        _clock = null;
      }
    });
  }

  void _considerPrompt() {
    if (!_blocked) {
      final dialog = _dialogContext;
      if (dialog != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!dialog.mounted) return;
          final route = ModalRoute.of(dialog);
          if (route != null && route.isActive) {
            Navigator.of(dialog).removeRoute(route);
          }
        });
      }
      return;
    }
    if (_promptOpen) return;
    final reason =
        '${widget.status.blockedCode ?? 'subscription_restricted'}:$_reason';
    if (!_seen.add(reason)) return;
    _promptOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !_blocked) {
        _promptOpen = false;
        return;
      }
      try {
        await showDialog<void>(
          context: context,
          useRootNavigator: false,
          builder: (context) {
            _dialogContext = context;
            return AlertDialog(
              title: const Text(_restrictionTitle),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 16,
                  children: [
                    Text(_reason),
                    const Text(_restrictionAdvice),
                    const Text(_restrictionSafety),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('我知道了'),
                ),
              ],
            );
          },
        );
      } finally {
        _dialogContext = null;
        _promptOpen = false;
        if (mounted) _considerPrompt();
      }
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_blocked) return const SizedBox.shrink();
    final wait = _seconds(widget.status.retryAt);
    final auto = _seconds(widget.status.nextSync);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Card(
        elevation: 0,
        color: Theme.of(context).colorScheme.errorContainer,
        shape: AppShape.xl.copyWith(side: BorderSide.none),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 8,
            children: [
              Text(_restrictionTitle, style: AppTextStyle.headline.of(context)),
              Text(_reason, maxLines: 4, overflow: TextOverflow.ellipsis),
              const Text(_restrictionSafety),
              if (widget.status.cleanupWarning case final warning?)
                Text(warning),
              Text(
                wait > 0
                    ? '请等待 $wait 秒后再手动检查${auto > 0 ? '；约 $auto 秒后自动复查' : ''}'
                    : auto > 0
                    ? '约 $auto 秒后自动复查，也可在更换网络后手动检查'
                    : '更换网络后可重新检查，连续操作至少间隔 10 秒',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  XcTaskButton(
                    label: '已更换网络，重新检查',
                    enabled: wait == 0,
                    action: widget.onCheck,
                  ),
                  TextButton(
                    onPressed: widget.onPlans,
                    child: const Text('账户与套餐'),
                  ),
                  TextButton(
                    onPressed: widget.onTickets,
                    child: const Text('联系客服'),
                  ),
                  TextButton(
                    onPressed: () => xcPush(
                      context,
                      XcPage(
                        title: _restrictionTitle,
                        child: xcList([
                          XcSection(
                            children: [
                              Text(_reason),
                              const Text(_restrictionAdvice),
                              const Text(_restrictionSafety),
                            ],
                          ),
                        ]),
                      ),
                    ),
                    child: const Text('查看详情'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class XcRestrictedNodesView extends StatefulWidget {
  const XcRestrictedNodesView({
    super.key,
    required this.status,
    required this.onCheck,
    this.now,
  });
  final SyncStatus status;
  final Future<void> Function() onCheck;
  final DateTime Function()? now;
  @override
  State<XcRestrictedNodesView> createState() => _XcRestrictedNodesViewState();
}

class _XcRestrictedNodesViewState extends State<XcRestrictedNodesView> {
  Timer? _clock;
  bool get _ready =>
      widget.status.retryAt == null ||
      !(widget.now?.call() ?? DateTime.now()).isBefore(widget.status.retryAt!);
  void _updateClock() {
    _clock?.cancel();
    _clock = null;
    if (_ready) return;
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (_ready) {
        _clock?.cancel();
        _clock = null;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _updateClock();
  }

  @override
  void didUpdateWidget(XcRestrictedNodesView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _updateClock();
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => xcList([
    XcSection(
      title: '暂时无法获取节点',
      children: [
        Text(widget.status.message ?? SyncMessages.blocked),
        const Text(_restrictionAdvice),
        const Text('服务器允许下发后才会重新显示节点，旧缓存不会用于连接。'),
        XcTaskButton(
          label: '已更换网络，重新检查',
          enabled: _ready,
          action: widget.onCheck,
        ),
      ],
    ),
  ]);
}
