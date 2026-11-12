import 'package:fl_clash/ui/icons/icons.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api/xboard_api.dart';
import '../common/components.dart';
import '../common/errors.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/motion.dart';
import '../common/tokens.dart';
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
  String? _checkError;
  String? _redeemed;
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
    setState(() {
      _checkError = null;
      _redeemed = null;
    });
    final Map<String, dynamic> preview;
    try {
      preview = await widget.api.giftCardCheck(code);
    } catch (error) {
      if (mounted) setState(() => _checkError = xcErrorText(error));
      return;
    }
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
    final message = '${result['message'] ?? '兑换成功'}';
    setState(() {
      _preview = null;
      _checkedCode = null;
      _redeemed = message;
      _revision++;
    });
    _code.clear();
    xcMessage(context, message);
    await widget.onRedeemed();
  }

  Widget? _result() {
    if (_redeemed case final message?) {
      return XcCallout(
        tone: XcTone.success,
        glyph: AppGlyphs.checkCircle,
        title: '兑换成功',
        message: '$message。账户与节点会自动刷新。',
      );
    }
    if (_checkError case final error?) {
      return XcCallout(
        tone: XcTone.danger,
        glyph: AppGlyphs.error,
        title: '礼品卡检查失败',
        message: error,
      );
    }
    final preview = _preview;
    if (preview == null) return null;
    final status = (preview['code_info'] as Map?)?['status_name'];
    return XcFormat.toBool(preview['can_redeem'])
        ? XcCallout(
            tone: XcTone.success,
            glyph: AppGlyphs.star,
            title: '可以兑换',
            message: status == null ? '确认后奖励会发放到你的账户。' : '礼品卡状态：$status',
            children: [
              Padding(
                padding: const EdgeInsets.only(top: XcSpace.xs),
                child: XcRewards(rewards: preview['reward_preview']),
              ),
            ],
          )
        : XcCallout(
            tone: XcTone.danger,
            glyph: AppGlyphs.block,
            title: '暂时不能兑换',
            message: '${preview['reason'] ?? '当前不可兑换'}',
            children: [
              if (status != null)
                Text('礼品卡状态：$status', style: XcType.caption(context)),
            ],
          );
  }

  @override
  Widget build(BuildContext context) {
    final gutter = XcSpace.gutterOf(MediaQuery.sizeOf(context).width);
    final result = _result();
    return XcPage(
      title: '礼品卡',
      child: Column(
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(gutter, XcSpace.xs, gutter, 0),
            child: XcEntrance(
              child: XcSection(
                title: '兑换礼品卡',
                glyph: AppGlyphs.star,
                children: [
                  Text(
                    '输入礼品卡码，先检查能获得什么奖励，再确认兑换。',
                    style: XcType.caption(context),
                  ),
                  XcFieldTheme(
                    child: TextField(
                      controller: _code,
                      decoration: const InputDecoration(
                        labelText: '礼品卡码',
                        prefixIcon: GlyphIcon(AppGlyphs.key, size: 20),
                      ),
                      autocorrect: false,
                      onChanged: (_) {
                        if (_preview != null || _checkError != null) {
                          setState(() {
                            _preview = null;
                            _checkedCode = null;
                            _checkError = null;
                          });
                        }
                      },
                    ),
                  ),
                  Row(
                    spacing: XcSpace.sm,
                    children: [
                      Expanded(
                        child: XcTaskButton(
                          label: '检查礼品卡',
                          loadingLabel: '检查中',
                          variant: XcButtonVariant.secondary,
                          action: _check,
                        ),
                      ),
                      Expanded(
                        child: XcTaskButton(
                          label: '确认兑换',
                          loadingLabel: '兑换中',
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
          ),
          Expanded(
            child: XcLoad<XbPage>(
              key: ValueKey('$_page:$_revision'),
              load: () => widget.api.giftCardHistory(page: _page),
              builder: (context, data, refresh) => xcList([
                if (result != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: XcSpace.md),
                    child: XcSwap(
                      value: (_redeemed, _checkError, _checkedCode),
                      alignment: Alignment.topLeft,
                      child: result,
                    ),
                  ),
                const XcSectionHeader(title: '兑换历史'),
                if (data.items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(left: 4, bottom: XcSpace.md),
                    child: Text('暂无兑换记录', style: XcType.secondary(context)),
                  ),
                for (final record in data.items)
                  XcSection(
                    title: '${record['template_name'] ?? '礼品卡'}',
                    glyph: AppGlyphs.star,
                    trailing: XcButton(
                      label: '查看详情',
                      size: XcButtonSize.small,
                      variant: XcButtonVariant.ghost,
                      onPressed: () => xcPush(
                        context,
                        XcGiftCardDetailPage(
                          api: widget.api,
                          id: XcFormat.toInt(record['id'])!,
                        ),
                      ),
                    ),
                    children: [
                      XcValue('卡码', record['code']),
                      XcValue('兑换时间', XcFormat.date(record['created_at'])),
                      XcValue('类型', record['template_type_name']),
                      XcRewards(rewards: record['rewards_given']),
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
          glyph: AppGlyphs.star,
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
            glyph: AppGlyphs.link,
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
    if (value is! Map) {
      return Text('奖励以服务器结算结果为准', style: XcType.caption(context));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: XcSpace.xs,
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
        if (XcFormat.toBool(value['reset_package']))
          Text('重置当前流量', style: XcType.secondary(context)),
        if (value.isEmpty) Text('暂无奖励信息', style: XcType.caption(context)),
      ],
    );
  }
}
