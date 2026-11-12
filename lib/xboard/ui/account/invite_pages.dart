import 'package:fl_clash/ui/icons/icons.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/components.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/tokens.dart';
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
        final earned = (XcFormat.toInt(stat(1)) ?? 0) > 0;
        final link = Uri.tryParse(widget.panelWebUrl);
        return xcList([
          XcSection(
            title: '邀请收益',
            glyph: AppGlyphs.star,
            trailing: XcBadge(label: '佣金比例 ${stat(3)}%', tone: XcTone.success),
            children: [
              XcMetric(
                label: '累计佣金',
                value: context.xcMoney(stat(1)),
                valueWidget: Text(
                  context.xcMoney(stat(1)),
                  style: XcType.figure(
                    context,
                  ).copyWith(color: XcColors.of(context).success),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: XcMetric(
                      label: '可用佣金',
                      value: context.xcMoney(stat(4)),
                    ),
                  ),
                  Expanded(
                    child: XcMetric(
                      label: '确认中佣金',
                      value: context.xcMoney(stat(2)),
                    ),
                  ),
                  Expanded(
                    child: XcMetric(label: '邀请注册人数', value: '${stat(0)}'),
                  ),
                ],
              ),
              if (!earned)
                XcCallout(
                  tone: XcTone.success,
                  glyph: AppGlyphs.sparkle,
                  title: '还没有佣金',
                  message: '把下方的邀请链接发给朋友，对方注册并购买套餐后，你可获得 ${stat(3)}% 佣金。',
                ),
              XcMenuRow(
                title: '佣金明细',
                subtitle: '每一笔佣金的来源订单',
                glyph: AppGlyphs.requests,
                tone: XcTone.neutral,
                onTap: () => xcPush(context, XcCommissionPage(api: widget.api)),
              ),
            ],
          ),
          XcSection(
            title: '我的邀请码',
            glyph: AppGlyphs.link,
            children: [
              if (codes is List)
                for (final item in codes.whereType<Map>())
                  _InviteCode(
                    code: '${item['code']}',
                    visits: item['pv'] ?? 0,
                    link: link != null && link.scheme == 'https'
                        ? link
                              .replace(
                                fragment:
                                    '/register?code=${Uri.encodeComponent('${item['code']}')}',
                              )
                              .toString()
                        : null,
                  ),
              XcTaskButton(
                label: '生成邀请码',
                glyph: AppGlyphs.add,
                variant: XcButtonVariant.secondary,
                action: () async {
                  await widget.api.createInviteCode();
                  await refresh();
                },
              ),
            ],
          ),
          XcSection(
            title: '佣金转入余额',
            glyph: AppGlyphs.swap,
            children: [
              Text('转入后可用于购买套餐，此操作无法撤回。', style: XcType.caption(context)),
              XcFieldTheme(
                floating: true,
                child: TextField(
                  controller: _amount,
                  decoration: InputDecoration(
                    labelText: '转入金额（${context.xcCurrency.code}）',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                ),
              ),
              XcTaskButton(
                label: '转入余额',
                loadingLabel: '正在转入',
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
              glyph: AppGlyphs.upload,
              children: [
                Wrap(
                  spacing: XcSpace.xs,
                  runSpacing: XcSpace.xs,
                  children: [
                    for (final method in methods)
                      _MethodChip(
                        label: method,
                        selected: method == _method,
                        onTap: () => setState(() => _method = method),
                      ),
                  ],
                ),
                XcFieldTheme(
                  floating: true,
                  child: TextField(
                    controller: _account,
                    decoration: const InputDecoration(labelText: '收款账号'),
                    autocorrect: false,
                  ),
                ),
                XcTaskButton(
                  label: '提交提现申请',
                  loadingLabel: '正在提交',
                  variant: XcButtonVariant.secondary,
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

class _InviteCode extends StatelessWidget {
  const _InviteCode({required this.code, required this.visits, this.link});
  final String code;
  final Object visits;
  final String? link;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.block, shape: XcRadius.tile),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Row(
                    spacing: XcSpace.xs,
                    children: [
                      SelectableText(code, style: XcType.value(context)),
                      Text('访问 $visits 次', style: XcType.caption(context)),
                    ],
                  ),
                  if (link case final link?)
                    SelectableText(
                      link,
                      maxLines: 1,
                      style: XcType.caption(context),
                    ),
                ],
              ),
            ),
            IconButton(
              tooltip: '复制邀请链接',
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: link ?? code));
                if (context.mounted) xcMessage(context, '已复制邀请链接');
              },
              icon: GlyphIcon(AppGlyphs.copy, size: 20, color: colors.accent),
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: XcMotion.of(context, XcMotion.standard),
        decoration: ShapeDecoration(
          color: selected ? colors.accentSoft : colors.block,
          shape: XcRadius.pill.copyWith(
            side: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: XcRadius.pill,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                label,
                style: XcType.secondary(
                  context,
                ).copyWith(color: selected ? colors.accent : colors.title),
              ),
            ),
          ),
        ),
      ),
    );
  }
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
        if (data.items.isEmpty)
          const XcStateView(
            glyph: AppGlyphs.requests,
            title: '暂无佣金明细',
            message: '被邀请的朋友购买套餐后，佣金记录会显示在这里。',
          ),
        for (final item in data.items)
          XcSection(
            title: '获得佣金 ${context.xcMoney(item['get_amount'])}',
            glyph: AppGlyphs.link,
            children: [
              XcValue('时间', XcFormat.date(item['created_at'])),
              XcValue('订单金额', context.xcMoney(item['order_amount'])),
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
