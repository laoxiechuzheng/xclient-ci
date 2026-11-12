import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/widgets.dart';
import 'support_pages.dart';

class XcInvitePage extends StatefulWidget {
  const XcInvitePage({super.key, required this.api, required this.panelWebUrl});
  final XboardApi api;
  final String panelWebUrl;
  @override
  State<XcInvitePage> createState() => _XcInvitePageState();
}

class _XcInvitePageState extends State<XcInvitePage> {
  final _amount = TextEditingController();
  final _account = TextEditingController();
  String? _method;
  @override
  void dispose() {
    _amount.dispose();
    _account.dispose();
    super.dispose();
  }

  Future<(Map<String, dynamic>, Map<String, dynamic>)> _load() async {
    final result = await Future.wait([
      widget.api.invites(),
      widget.api.commConfig(),
    ]);
    return (result[0], result[1]);
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '邀请与佣金',
    child: XcLoad<(Map<String, dynamic>, Map<String, dynamic>)>(
      load: _load,
      builder: (context, data, refresh) {
        final (invites, config) = data;
        final rawStats = invites['stat'];
        final stats = rawStats is List ? rawStats : const [];
        Object? stat(int index) => index < stats.length ? stats[index] : 0;
        final codes = invites['codes'];
        final rawMethods = config['withdraw_methods'];
        final methods = [
          if (rawMethods is List)
            for (final value in rawMethods) '$value',
        ];
        return xcList([
          XcSection(
            title: '邀请收益',
            children: [
              XcValue('邀请注册人数', stat(0)),
              XcValue('累计佣金', context.xcMoney(stat(1))),
              XcValue('确认中佣金', context.xcMoney(stat(2))),
              XcValue('佣金比例', '${stat(3)}%'),
              XcValue('可用佣金', context.xcMoney(stat(4))),
              XcMenuRow(
                title: '佣金明细',
                onTap: () => xcPush(context, XcCommissionPage(api: widget.api)),
              ),
            ],
          ),
          XcSection(
            title: '我的邀请码',
            children: [
              if (codes is List)
                for (final item in codes.whereType<Map>()) ...[
                  XcValue('邀请码', item['code']),
                  XcValue('访问次数', item['pv'] ?? 0),
                  if (Uri.tryParse(widget.panelWebUrl) case final url?
                      when url.scheme == 'https')
                    SelectableText(
                      url
                          .replace(
                            fragment:
                                '/register?code=${Uri.encodeComponent('${item['code']}')}',
                          )
                          .toString(),
                    ),
                  const Divider(),
                ],
              XcTaskButton(
                label: '生成邀请码',
                action: () async {
                  await widget.api.createInviteCode();
                  await refresh();
                },
              ),
            ],
          ),
          XcSection(
            title: '佣金转入余额',
            children: [
              const Text('转入后可用于购买套餐，此操作无法撤回。'),
              TextField(
                controller: _amount,
                decoration: InputDecoration(
                  labelText: '转入金额（${context.xcCurrency.code}）',
                ),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
              ),
              XcTaskButton(
                label: '转入余额',
                action: () async {
                  final yuan = double.tryParse(_amount.text.trim());
                  if (yuan == null ||
                      !yuan.isFinite ||
                      yuan <= 0 ||
                      (yuan * 100).round() <= 0) {
                    xcMessage(context, '请输入有效金额');
                    return;
                  }
                  final cents = (yuan * 100).round();
                  if (!await xcConfirm(
                    context,
                    '佣金转入余额',
                    '确认将 ${context.xcMoney(cents)} 转入余额？',
                  )) {
                    return;
                  }
                  await widget.api.transferCommission(cents);
                  if (!mounted) return;
                  _amount.clear();
                  await refresh();
                },
              ),
            ],
          ),
          if (!XcFormat.toBool(config['withdraw_close']) && methods.isNotEmpty)
            XcSection(
              title: '申请提现',
              children: [
                Wrap(
                  spacing: 8,
                  children: [
                    for (final method in methods)
                      ChoiceChip(
                        label: Text(method),
                        selected: method == _method,
                        onSelected: (_) => setState(() => _method = method),
                      ),
                  ],
                ),
                TextField(
                  controller: _account,
                  decoration: const InputDecoration(labelText: '收款账号'),
                  autocorrect: false,
                ),
                XcTaskButton(
                  label: '提交提现申请',
                  action: () async {
                    if (_method == null || _account.text.trim().isEmpty) {
                      xcMessage(context, '请选择提现方式并填写收款账号');
                      return;
                    }
                    if (!await xcConfirm(
                      context,
                      '申请提现',
                      '确认提交提现申请？处理进度可在工单中查看。',
                    )) {
                      return;
                    }
                    await widget.api.withdrawCommission(
                      method: _method!,
                      account: _account.text.trim(),
                    );
                    if (!mounted) return;
                    _account.clear();
                    if (context.mounted) {
                      xcMessage(context, '提现申请已提交，请在工单中查看进度');
                    }
                    await refresh();
                  },
                ),
              ],
            ),
        ]);
      },
    ),
  );
}

class XcCommissionPage extends StatefulWidget {
  const XcCommissionPage({super.key, required this.api});
  final XboardApi api;
  @override
  State<XcCommissionPage> createState() => _XcCommissionPageState();
}

class _XcCommissionPageState extends State<XcCommissionPage> {
  int _page = 1;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '佣金明细',
    child: XcLoad<XbPage>(
      key: ValueKey(_page),
      load: () => widget.api.inviteDetails(page: _page),
      builder: (context, data, refresh) => xcList([
        if (data.items.isEmpty) const Text('暂无佣金明细'),
        for (final item in data.items)
          XcSection(
            children: [
              XcValue('时间', XcFormat.date(item['created_at'])),
              XcValue('订单金额', context.xcMoney(item['order_amount'])),
              XcValue('获得佣金', context.xcMoney(item['get_amount'])),
              XcValue('订单号', item['trade_no']),
            ],
          ),
        XcPagination(
          page: _page,
          hasNext: _page * 10 < data.total,
          onPage: (next) => setState(() => _page = next),
        ),
      ]),
    ),
  );
}
