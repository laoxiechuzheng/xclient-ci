import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/widgets.dart';
import 'support_pages.dart';

class XcGiftCardsPage extends StatefulWidget {
  const XcGiftCardsPage({
    super.key,
    required this.api,
    required this.onRedeemed,
  });
  final XboardApi api;
  final Future<void> Function() onRedeemed;
  @override
  State<XcGiftCardsPage> createState() => _XcGiftCardsPageState();
}

class _XcGiftCardsPageState extends State<XcGiftCardsPage> {
  final _code = TextEditingController();
  Map<String, dynamic>? _preview;
  String? _checkedCode;
  int _page = 1;
  int _revision = 0;
  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final code = _code.text.trim();
    if (code.length < 8 || code.length > 32) {
      xcMessage(context, '请输入 8–32 位礼品卡码');
      return;
    }
    final preview = await widget.api.giftCardCheck(code);
    if (mounted && _code.text.trim() == code) {
      setState(() {
        _preview = preview;
        _checkedCode = code;
      });
    }
  }

  Future<void> _redeem() async {
    final code = _code.text.trim();
    if (code != _checkedCode || !XcFormat.toBool(_preview?['can_redeem'])) {
      return;
    }
    if (!await xcConfirm(context, '兑换礼品卡', '确认兑换当前礼品卡？奖励以服务器结算结果为准。')) return;
    final result = await widget.api.giftCardRedeem(code);
    if (!mounted) return;
    setState(() {
      _preview = null;
      _checkedCode = null;
      _revision++;
    });
    _code.clear();
    xcMessage(context, '${result['message'] ?? '兑换成功'}');
    await widget.onRedeemed();
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '礼品卡',
    child: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              TextField(
                controller: _code,
                decoration: const InputDecoration(labelText: '礼品卡码'),
                autocorrect: false,
                onChanged: (_) {
                  if (_preview != null) {
                    setState(() {
                      _preview = null;
                      _checkedCode = null;
                    });
                  }
                },
              ),
              Row(
                spacing: 12,
                children: [
                  Expanded(
                    child: XcTaskButton(
                      label: '检查礼品卡',
                      tonal: true,
                      action: _check,
                    ),
                  ),
                  Expanded(
                    child: XcTaskButton(
                      label: '确认兑换',
                      enabled:
                          _checkedCode == _code.text.trim() &&
                          XcFormat.toBool(_preview?['can_redeem']),
                      action: _redeem,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: XcLoad<XbPage>(
            key: ValueKey('$_page:$_revision'),
            load: () => widget.api.giftCardHistory(page: _page),
            builder: (context, data, refresh) => xcList([
              if (_preview case final preview?)
                XcSection(
                  title: '奖励预览',
                  children: [
                    XcValue(
                      '状态',
                      (preview['code_info'] as Map?)?['status_name'],
                    ),
                    XcRewards(rewards: preview['reward_preview']),
                    if (!XcFormat.toBool(preview['can_redeem']))
                      Text('${preview['reason'] ?? '当前不可兑换'}'),
                  ],
                ),
              const Text('兑换历史'),
              if (data.items.isEmpty) const Text('暂无兑换记录'),
              for (final record in data.items)
                XcSection(
                  title: '${record['template_name'] ?? '礼品卡'}',
                  children: [
                    XcValue('卡码', record['code']),
                    XcValue('兑换时间', XcFormat.date(record['created_at'])),
                    XcValue('类型', record['template_type_name']),
                    XcRewards(rewards: record['rewards_given']),
                    TextButton(
                      onPressed: () => xcPush(
                        context,
                        XcGiftCardDetailPage(
                          api: widget.api,
                          id: XcFormat.toInt(record['id'])!,
                        ),
                      ),
                      child: const Text('查看详情'),
                    ),
                  ],
                ),
              XcPagination(
                page: _page,
                hasNext: _page * 15 < data.total,
                onPage: (next) => setState(() => _page = next),
              ),
            ]),
          ),
        ),
      ],
    ),
  );
}

class XcGiftCardDetailPage extends StatelessWidget {
  const XcGiftCardDetailPage({super.key, required this.api, required this.id});
  final XboardApi api;
  final int id;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '礼品卡兑换详情',
    child: XcLoad<Map<String, dynamic>>(
      load: () => api.giftCardDetail(id),
      builder: (context, data, refresh) => xcList([
        XcSection(
          title: '${data['template_name'] ?? '礼品卡'}',
          children: [
            XcValue('卡码', data['code']),
            XcValue('兑换时间', XcFormat.date(data['created_at'])),
            XcValue('奖励倍数', data['multiplier_applied']),
            XcRewards(rewards: data['rewards_given'] ?? data['rewards']),
          ],
        ),
        if (data['invite_rewards'] != null)
          XcSection(
            title: '邀请奖励',
            children: [XcRewards(rewards: data['invite_rewards'])],
          ),
      ]),
    ),
  );
}

class XcRewards extends StatelessWidget {
  const XcRewards({super.key, required this.rewards});
  final Object? rewards;
  @override
  Widget build(BuildContext context) {
    final value = rewards;
    if (value is! Map) return const Text('奖励以服务器结算结果为准');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 8,
      children: [
        if (value['balance'] != null)
          XcValue('余额奖励', context.xcMoney(value['balance'])),
        if (value['transfer_enable'] != null)
          XcValue('流量奖励', XcFormat.bytes(value['transfer_enable'])),
        if (value['expire_days'] != null)
          XcValue('延长有效期', '${value['expire_days']} 天'),
        if (value['plan_validity_days'] != null)
          XcValue('套餐有效期', '${value['plan_validity_days']} 天'),
        if (value['plan_name'] != null || value['plan_id'] != null)
          XcValue('套餐', value['plan_name'] ?? '#${value['plan_id']}'),
        if (value['device_limit'] != null)
          XcValue('增加设备数', value['device_limit']),
        if (XcFormat.toBool(value['reset_package'])) const Text('重置当前流量'),
        if (value.isEmpty) const Text('暂无奖励信息'),
      ],
    );
  }
}
