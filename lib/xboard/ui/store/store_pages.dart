import 'dart:async';

import 'package:fl_clash/ui/icons/icons.dart';
import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:qr/qr.dart';

import '../../core/api/xboard_api.dart';
import '../common/components.dart';
import '../common/errors.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/motion.dart';
import '../common/rich_content.dart';
import '../common/tokens.dart';
import '../common/widgets.dart';
import 'checkout_logic.dart';

class XcPlansPage extends StatelessWidget {
  const XcPlansPage({super.key, required this.api, this.embedded = false});
  final XboardApi api;
  final bool embedded;
  @override
  Widget build(BuildContext context) {
    final body = XcLoad<List<Map<String, dynamic>>>(
      load: api.plans,
      builder: (context, plans, refresh) => LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 1080
              ? 3
              : constraints.maxWidth >= 700
              ? 2
              : 1;
          return xcList([
            if (plans.isEmpty)
              const XcStateView(
                glyph: AppGlyphs.resources,
                title: '暂无在售套餐',
                message: '站点还没有上架套餐，请稍后再来看看，或联系客服咨询。',
              ),
            for (var start = 0; start < plans.length; start += columns)
              Padding(
                padding: const EdgeInsets.only(bottom: XcSpace.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: XcSpace.md,
                  children: [
                    for (var index = start; index < start + columns; index++)
                      Expanded(
                        child: index < plans.length
                            ? XcPlanCard(
                                plan: plans[index],
                                onBuy: () => xcPush(
                                  context,
                                  XcPlanDetailPage(
                                    api: api,
                                    plan: plans[index],
                                  ),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                  ],
                ),
              ),
          ]);
        },
      ),
    );
    return embedded ? body : XcPage(title: '选购套餐', child: body);
  }
}

class XcPlanCard extends StatelessWidget {
  const XcPlanCard({super.key, required this.plan, required this.onBuy});
  final Map<String, dynamic> plan;
  final VoidCallback onBuy;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final price = XcPlans.displayPrice(plan);
    final soldOut = XcPlans.soldOut(plan);
    final prices = XcPlans.prices(plan);
    final saving = prices.fold<int>(
      0,
      (best, item) =>
          XcPlans.saving(plan, item) > best ? XcPlans.saving(plan, item) : best,
    );
    return XcPanel(
      elevated: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: XcSpace.md,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: XcSpace.sm,
            children: [
              Expanded(
                child: Text(
                  '${plan['name'] ?? '套餐'}',
                  style: XcType.title(context),
                ),
              ),
              if (soldOut)
                const XcBadge(label: '暂时售罄', tone: XcTone.warning)
              else if (saving > 0)
                XcBadge(label: '长周期最高省 $saving%', tone: XcTone.success),
            ],
          ),
          if (price != null)
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: context.xcMoney(price.cents),
                    style: XcType.figure(
                      context,
                    ).copyWith(color: colors.accent),
                  ),
                  TextSpan(
                    text: ' / ${price.label}',
                    style: XcType.secondary(context),
                  ),
                ],
              ),
            ),
          Wrap(
            spacing: XcSpace.xs,
            runSpacing: XcSpace.xs,
            children: [
              _Spec(
                glyph: AppGlyphs.dataUsage,
                text: XcFormat.planTraffic(plan['transfer_enable']),
              ),
              if (plan['speed_limit'] != null)
                _Spec(
                  glyph: AppGlyphs.speed,
                  text: '${plan['speed_limit']} Mbps',
                ),
              if (plan['device_limit'] != null)
                _Spec(
                  glyph: AppGlyphs.devices,
                  text: '${plan['device_limit']} 台设备',
                ),
              for (final tag in XcPlans.tags(plan))
                XcBadge(label: tag, tone: XcTone.accent),
            ],
          ),
          XcRichContent(content: '${plan['content'] ?? ''}'),
          XcButton(
            label: soldOut ? '暂时售罄' : '选择套餐',
            expand: true,
            onPressed: soldOut || price == null ? null : onBuy,
          ),
        ],
      ),
    );
  }
}

class _Spec extends StatelessWidget {
  const _Spec({required this.glyph, required this.text});
  final Glyph glyph;
  final String text;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return DecoratedBox(
      decoration: ShapeDecoration(color: colors.block, shape: XcRadius.pill),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 6,
          children: [
            GlyphIcon(glyph, size: 14, color: colors.muted),
            Text(
              text,
              style: AppTextStyle.caption1
                  .of(context, emphasized: true)
                  .copyWith(color: colors.title),
            ),
          ],
        ),
      ),
    );
  }
}

class XcPlanDetailPage extends StatefulWidget {
  const XcPlanDetailPage({
    super.key,
    required this.api,
    required this.plan,
    this.initialPeriod,
  });
  final XboardApi api;
  final Map<String, dynamic> plan;
  final String? initialPeriod;
  @override
  State<XcPlanDetailPage> createState() => _XcPlanDetailPageState();
}

class _XcPlanDetailPageState extends State<XcPlanDetailPage> {
  final _coupon = TextEditingController();
  late XcPlanPrice? _price;
  Map<String, dynamic>? _discount;
  String? _validatedCode;
  String? _couponError;
  String? _orderError;
  @override
  void initState() {
    super.initState();
    _price =
        XcPlans.prices(
          widget.plan,
          includeReset: true,
        ).where((item) => item.period == widget.initialPeriod).firstOrNull ??
        XcPlans.prices(widget.plan, includeReset: true).firstOrNull;
  }

  @override
  void dispose() {
    _coupon.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    if (_price == null || _coupon.text.trim().isEmpty) {
      xcMessage(context, '请先选择周期并填写优惠码');
      return;
    }
    final code = _coupon.text.trim();
    final period = _price!.period;
    setState(() => _couponError = null);
    final Map<String, dynamic> discount;
    try {
      discount = await widget.api.checkCoupon(
        code: code,
        planId: XcFormat.toInt(widget.plan['id'])!,
        period: period,
      );
    } catch (error) {
      if (mounted) setState(() => _couponError = xcErrorText(error));
      return;
    }
    if (mounted && _price?.period == period && _coupon.text.trim() == code) {
      setState(() {
        _discount = discount;
        _validatedCode = code;
      });
    }
  }

  Future<void> _buy() async {
    final price = _price;
    if (price == null) return;
    final code = _coupon.text.trim();
    if (code.isNotEmpty && code != _validatedCode) {
      xcMessage(context, '请先验证优惠码');
      return;
    }
    setState(() => _orderError = null);
    final String trade;
    try {
      trade = await XcCheckoutFlow(widget.api).placeOrder(
        planId: XcFormat.toInt(widget.plan['id'])!,
        period: price.period,
        couponCode: code,
      );
    } catch (error) {
      if (mounted) setState(() => _orderError = xcErrorText(error));
      return;
    }
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => XcOrderPage(api: widget.api, tradeNo: trade),
        ),
      );
    }
  }

  void _select(XcPlanPrice price) => setState(() {
    _price = price;
    _discount = null;
    _validatedCode = null;
    _couponError = null;
  });

  @override
  Widget build(BuildContext context) {
    final prices = XcPlans.prices(widget.plan, includeReset: true);
    final selected = _price;
    final discount = selected == null || _discount == null
        ? 0
        : XcCoupons.discount(_discount!, selected.cents);
    final total = selected == null ? 0 : selected.cents - discount;
    final canBuy = selected != null && !XcPlans.soldOut(widget.plan);
    final buy = XcTaskButton(
      label: '创建订单',
      loadingLabel: '正在创建订单',
      glyph: AppGlyphs.checkCircle,
      expand: true,
      size: XcButtonSize.large,
      enabled: canBuy,
      action: _buy,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 860;
        final sections = [
          _PlanSummary(plan: widget.plan),
          XcSection(
            title: '选择付款周期',
            glyph: AppGlyphs.clock,
            children: [
              _PeriodGrid(
                plan: widget.plan,
                prices: prices,
                selected: selected,
                onSelected: _select,
              ),
            ],
          ),
          XcSection(
            title: '优惠码',
            glyph: AppGlyphs.sparkle,
            children: [
              XcFieldTheme(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: XcSpace.sm,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _coupon,
                        decoration: const InputDecoration(labelText: '优惠码（可选）'),
                        autocorrect: false,
                        onChanged: (_) {
                          if (_discount != null || _couponError != null) {
                            setState(() {
                              _discount = null;
                              _validatedCode = null;
                              _couponError = null;
                            });
                          }
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: XcTaskButton(
                        label: '验证优惠码',
                        loadingLabel: '验证中',
                        variant: XcButtonVariant.secondary,
                        action: _check,
                      ),
                    ),
                  ],
                ),
              ),
              XcSwap(
                value: (_discount != null, _couponError),
                alignment: Alignment.topLeft,
                child: _discount != null
                    ? XcCallout(
                        tone: XcTone.success,
                        glyph: AppGlyphs.checkCircle,
                        title: '优惠已生效',
                        message: XcCoupons.describe(
                          _discount!,
                          symbol: context.xcCurrency.symbol,
                        ),
                      )
                    : _couponError != null
                    ? XcCallout(
                        tone: XcTone.danger,
                        glyph: AppGlyphs.error,
                        title: '优惠码暂时不能使用',
                        message: _couponError,
                      )
                    : Text(
                        '有优惠码可以填在这里，验证后自动计入价格。',
                        style: XcType.caption(context),
                      ),
              ),
            ],
          ),
          if (!wide)
            _CheckoutSummary(
              selected: selected,
              discount: discount,
              total: total,
              showTotal: false,
            ),
          if (_orderError case final error?)
            XcCallout(
              tone: XcTone.danger,
              glyph: AppGlyphs.error,
              title: '订单没有创建成功',
              message: '$error。也可以到“我的订单”查看是否已生成待支付订单。',
            ),
        ];
        if (!wide) {
          return XcPage(
            title: '${widget.plan['name'] ?? '套餐详情'}',
            bottom: XcBottomActionBar(
              summary: _TotalLine(total: total, selected: selected),
              children: [SizedBox(width: 188, child: buy)],
            ),
            child: xcList(sections),
          );
        }
        return XcPage(
          title: '${widget.plan['name'] ?? '套餐详情'}',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: xcList(sections)),
              SizedBox(
                width: 320,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(0, XcSpace.xs, 24, 24),
                  child: XcEntrance(
                    index: 1,
                    child: _CheckoutSummary(
                      selected: selected,
                      discount: discount,
                      total: total,
                      showTotal: true,
                      action: buy,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _PlanSummary extends StatelessWidget {
  const _PlanSummary({required this.plan});
  final Map<String, dynamic> plan;
  @override
  Widget build(BuildContext context) => XcSection(
    children: [
      Row(
        spacing: XcSpace.sm,
        children: [
          const XcGlyphWell(glyph: AppGlyphs.resources, size: 44),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text('${plan['name'] ?? '套餐'}', style: XcType.title(context)),
                Text(
                  [
                    XcFormat.planTraffic(plan['transfer_enable']),
                    if (plan['speed_limit'] != null)
                      '${plan['speed_limit']} Mbps',
                    if (plan['device_limit'] != null)
                      '${plan['device_limit']} 台设备',
                  ].join(' · '),
                  style: XcType.secondary(context),
                ),
              ],
            ),
          ),
        ],
      ),
      XcRichContent(content: '${plan['content'] ?? ''}'),
    ],
  );
}

class _PeriodGrid extends StatelessWidget {
  const _PeriodGrid({
    required this.plan,
    required this.prices,
    required this.selected,
    required this.onSelected,
  });
  final Map<String, dynamic> plan;
  final List<XcPlanPrice> prices;
  final XcPlanPrice? selected;
  final ValueChanged<XcPlanPrice> onSelected;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = constraints.maxWidth >= 480 ? 3 : 2;
      final width =
          (constraints.maxWidth - XcSpace.sm * (columns - 1)) / columns;
      return Wrap(
        spacing: XcSpace.sm,
        runSpacing: XcSpace.sm,
        children: [
          for (final price in prices)
            SizedBox(
              width: width,
              child: _PeriodTile(
                price: price,
                saving: XcPlans.saving(plan, price),
                selected: price == selected,
                onTap: () => onSelected(price),
              ),
            ),
        ],
      );
    },
  );
}

class _PeriodTile extends StatelessWidget {
  const _PeriodTile({
    required this.price,
    required this.saving,
    required this.selected,
    required this.onTap,
  });
  final XcPlanPrice price;
  final int saving;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final monthly = price.monthlyCents;
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: XcMotion.of(context, XcMotion.standard),
        curve: XcMotion.standardCurve,
        decoration: ShapeDecoration(
          color: selected ? colors.accentSoft : colors.block,
          shape: XcRadius.tile.copyWith(
            side: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: XcRadius.tile,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          price.label,
                          style: XcType.secondary(
                            context,
                          ).copyWith(color: selected ? colors.accent : null),
                        ),
                      ),
                      if (selected)
                        GlyphIcon(
                          AppGlyphs.checkCircle,
                          size: 18,
                          fill: 1,
                          color: colors.accent,
                        ),
                    ],
                  ),
                  Text(
                    context.xcMoney(price.cents),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: XcType.value(context),
                  ),
                  Text(
                    saving > 0
                        ? '省 $saving%'
                        : monthly != null
                        ? '约 ${context.xcMoney(monthly)}/月'
                        : ' ',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: XcType.caption(
                      context,
                    ).copyWith(color: saving > 0 ? colors.success : null),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _CheckoutSummary extends StatelessWidget {
  const _CheckoutSummary({
    required this.selected,
    required this.discount,
    required this.total,
    required this.showTotal,
    this.action,
  });
  final XcPlanPrice? selected;
  final int discount;
  final int total;
  final bool showTotal;
  final Widget? action;
  @override
  Widget build(BuildContext context) => XcSection(
    title: '费用明细',
    glyph: AppGlyphs.requests,
    children: [
      if (selected case final selected?)
        XcValue('套餐金额', context.xcMoney(selected.cents)),
      if (discount > 0) XcValue('优惠', '-${context.xcMoney(discount)}'),
      if (showTotal && selected != null) ...[
        Divider(height: 1, color: XcColors.of(context).hairline),
        XcValue('预计金额', context.xcMoney(total), strong: true),
      ],
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 6,
        children: [
          GlyphIcon(
            AppGlyphs.info,
            size: 15,
            color: XcColors.of(context).muted,
          ),
          Expanded(
            child: Text(
              '下单时优先使用账户余额，最终金额以订单详情为准。',
              style: XcType.caption(context),
            ),
          ),
        ],
      ),
      if (action case final action?) ...[
        const SizedBox(height: XcSpace.xs),
        action,
      ],
    ],
  );
}

class _TotalLine extends StatelessWidget {
  const _TotalLine({required this.total, required this.selected});
  final int total;
  final XcPlanPrice? selected;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        selected == null ? '请选择付款周期' : '预计金额 · ${selected!.label}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: XcType.caption(context),
      ),
      XcAnimatedNumber(
        value: total.toDouble(),
        format: (value) => context.xcMoney(value.round()),
        style: XcType.metric(
          context,
        ).copyWith(color: XcColors.of(context).accent),
      ),
    ],
  );
}

({XcTone tone, Glyph glyph}) xcOrderStyle(int status) => switch (status) {
  OrderStatus.pending => (tone: XcTone.warning, glyph: AppGlyphs.clock),
  OrderStatus.processing => (tone: XcTone.accent, glyph: AppGlyphs.sync),
  OrderStatus.completed => (tone: XcTone.success, glyph: AppGlyphs.checkCircle),
  OrderStatus.discounted => (tone: XcTone.success, glyph: AppGlyphs.check),
  OrderStatus.cancelled => (tone: XcTone.neutral, glyph: AppGlyphs.block),
  _ => (tone: XcTone.neutral, glyph: AppGlyphs.info),
};

class XcOrdersPage extends StatelessWidget {
  const XcOrdersPage({super.key, required this.api});
  final XboardApi api;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '我的订单',
    child: XcLoad<List<Map<String, dynamic>>>(
      load: api.orders,
      builder: (context, orders, refresh) => xcList([
        if (orders.isEmpty)
          const XcStateView(
            glyph: AppGlyphs.requests,
            title: '暂无订单',
            message: '购买套餐后，订单和支付状态会显示在这里。',
          ),
        for (final order in orders)
          Padding(
            padding: const EdgeInsets.only(bottom: XcSpace.sm),
            child: _OrderTile(
              order: order,
              onTap: () => xcPush(
                context,
                XcOrderPage(api: api, tradeNo: '${order['trade_no']}'),
              ),
            ),
          ),
      ]),
    ),
  );
}

class _OrderTile extends StatelessWidget {
  const _OrderTile({required this.order, required this.onTap});
  final Map<String, dynamic> order;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final status = XcOrders.status(order);
    final style = xcOrderStyle(status);
    return XcPanel(
      elevated: true,
      onTap: onTap,
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
      child: Row(
        spacing: XcSpace.sm,
        children: [
          XcGlyphWell(glyph: style.glyph, tone: style.tone, size: 40),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(
                  XcOrders.planName(order),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XcType.headline(context),
                ),
                Text(
                  '${XcOrders.typeLabel(order['type'])} · '
                  '${XcOrders.periodLabel(order['period'])} · '
                  '${XcFormat.date(order['created_at'], withTime: false)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: XcType.caption(context),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            spacing: 4,
            children: [
              Text(
                context.xcMoney(order['total_amount']),
                style: XcType.value(context),
              ),
              XcBadge(label: XcOrders.statusLabel(status), tone: style.tone),
            ],
          ),
          GlyphIcon(
            AppGlyphs.chevronForward,
            size: 18,
            color: XcColors.of(context).muted,
          ),
        ],
      ),
    );
  }
}

class XcOrderPage extends StatefulWidget {
  const XcOrderPage({
    super.key,
    required this.api,
    required this.tradeNo,
    this.pollInterval = const Duration(seconds: 3),
    this.pollTimeout = const Duration(minutes: 30),
  });
  final XboardApi api;
  final String tradeNo;
  final Duration pollInterval;
  final Duration pollTimeout;
  @override
  State<XcOrderPage> createState() => _XcOrderPageState();
}

class _XcOrderPageState extends State<XcOrderPage> {
  late Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _future;
  XcPaymentWatcher? _watcher;
  XcPayStep? _payment;
  int? _method;
  int? _polledStatus;
  bool _pollTimedOut = false;
  bool _refreshingEntitlements = false;
  bool _reconciled = false;
  String? _entitlementError;
  XcEntitlementRefresh? _entitlements;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _entitlements = XcCommerceScope.maybeOf(context)?.entitlements;
  }

  Future<(Map<String, dynamic>, List<Map<String, dynamic>>)> _load() async {
    final result = await Future.wait<Object>([
      widget.api.orderDetail(widget.tradeNo),
      widget.api.paymentMethods(),
    ]);
    final order = result[0] as Map<String, dynamic>;
    if (mounted) {
      final status = _polledStatus ?? XcOrders.status(order);
      _ensureWatching(status);
      unawaited(_reconcile(status));
    }
    return (order, result[1] as List<Map<String, dynamic>>);
  }

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  void _ensureWatching(int status) {
    if (status == OrderStatus.pending || status == OrderStatus.processing) {
      if (_watcher == null && !_pollTimedOut) unawaited(_watch());
    } else {
      _watcher?.stop();
    }
  }

  Future<void> _reconcile(int status) async {
    if (!mounted ||
        !xcOrderSucceeded(status) ||
        _reconciled ||
        _refreshingEntitlements ||
        _entitlements == null) {
      return;
    }
    setState(() {
      _refreshingEntitlements = true;
      _entitlementError = null;
    });
    try {
      await _entitlements!.orderCompleted(widget.tradeNo);
      if (mounted) setState(() => _reconciled = true);
    } catch (error) {
      if (mounted) setState(() => _entitlementError = xcErrorText(error));
    } finally {
      if (mounted) setState(() => _refreshingEntitlements = false);
    }
  }

  Future<void> _watch() async {
    final watcher = XcPaymentWatcher(
      check: () => widget.api.checkOrder(widget.tradeNo),
      interval: widget.pollInterval,
      timeout: widget.pollTimeout,
      onStatus: (status) async {
        if (!mounted) return;
        if (_polledStatus != status) {
          setState(() {
            _polledStatus = status;
            if (status != OrderStatus.pending) _payment = null;
            _future = _load();
          });
        }
        await _reconcile(status);
      },
    );
    _watcher = watcher;
    final status = await watcher.waitWhilePending();
    if (identical(_watcher, watcher)) _watcher = null;
    if (mounted && status == null && !watcher.stopped) {
      setState(() => _pollTimedOut = true);
    }
  }

  @override
  void dispose() {
    _watcher?.stop();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (!mounted) return;
    setState(() {
      _polledStatus = null;
      _pollTimedOut = false;
      _future = _load();
    });
    await _future;
  }

  Future<void> _pay() async {
    final payment = await XcCheckoutFlow(
      widget.api,
    ).pay(tradeNo: widget.tradeNo, methodId: _method);
    if (!mounted) return;
    setState(() => _payment = payment);
    if (payment.action == XcPayAction.openUrl) {
      if (!await xcOpenExternal(payment.uri!)) {
        if (mounted) xcMessage(context, '无法打开支付页面，请选择其他支付方式');
      }
    } else if (payment.action == XcPayAction.paid) {
      await _refresh();
    }
  }

  Future<void> _cancel() async {
    if (!await xcConfirm(context, '取消订单', '确认取消这笔未支付订单？')) return;
    await widget.api.cancelOrder(widget.tradeNo);
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) => XcPage(
    title: '订单详情',
    child: FutureBuilder<(Map<String, dynamic>, List<Map<String, dynamic>>)>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return XcStateView(
            tone: XcTone.danger,
            glyph: AppGlyphs.wifiOff,
            title: '订单信息没有加载出来',
            message: xcErrorText(snapshot.error!),
            action: XcButton(
              label: '重试',
              variant: XcButtonVariant.secondary,
              glyph: AppGlyphs.refresh,
              onPressed: _refresh,
            ),
          );
        }
        if (!snapshot.hasData) {
          return const Center(
            child: CommonCircleLoading.page(semanticLabel: '正在加载'),
          );
        }
        final (order, methods) = snapshot.data!;
        final status = _polledStatus ?? XcOrders.status(order);
        final pending = status == OrderStatus.pending;
        final needsMethod = xcNeedsPaymentMethod(order);
        final deadline = XcOrders.deadline(order);
        final expired =
            deadline != null &&
            deadline * 1000 <= DateTime.now().millisecondsSinceEpoch;
        final method = methods
            .where((item) => XcFormat.toInt(item['id']) == _method)
            .firstOrNull;
        final watching =
            (pending || status == OrderStatus.processing) && !_pollTimedOut;
        return RefreshIndicator(
          onRefresh: _refresh,
          child: xcList([
            _OrderHero(
              order: order,
              status: status,
              expired: expired,
              deadline: deadline,
              watching: watching,
              synced: _reconciled,
            ),
            if (status == OrderStatus.processing ||
                _payment?.action == XcPayAction.paid)
              const _Gap(
                XcCallout(
                  glyph: AppGlyphs.sync,
                  title: '套餐正在开通',
                  message: '支付已受理，套餐正在开通。开通完成后会自动刷新账户与节点。',
                ),
              ),
            if (_refreshingEntitlements)
              const _Gap(
                XcCallout(
                  glyph: AppGlyphs.cloudSync,
                  title: '套餐已开通，正在刷新账户与节点…',
                  children: [
                    Padding(
                      padding: EdgeInsets.only(top: XcSpace.xs),
                      child: ClipPath(
                        clipper: ShapeBorderClipper(shape: AppShape.full),
                        child: LinearProgressIndicator(minHeight: 6),
                      ),
                    ),
                  ],
                ),
              ),
            if (_reconciled)
              const _Gap(
                XcCallout(
                  tone: XcTone.success,
                  glyph: AppGlyphs.checkCircle,
                  title: '套餐已开通，账户信息与节点同步已检查。',
                  message: '回到首页即可一键连接。',
                ),
              ),
            if (_entitlementError != null)
              _Gap(
                XcCallout(
                  tone: XcTone.danger,
                  glyph: AppGlyphs.error,
                  title: '账户刷新没有完成',
                  message: '订单已完成，刷新账户与节点失败：$_entitlementError',
                  actions: [
                    XcTaskButton(
                      label: '重试刷新账户与节点',
                      size: XcButtonSize.small,
                      variant: XcButtonVariant.secondary,
                      action: () => _reconcile(status),
                    ),
                  ],
                ),
              ),
            if (_pollTimedOut)
              const _Gap(
                XcCallout(
                  tone: XcTone.warning,
                  glyph: AppGlyphs.clock,
                  title: '自动查询已暂停',
                  message: '可刷新状态，或稍后从“我的订单”重新进入查询。',
                ),
              ),
            if (pending)
              XcSection(
                title: '支付订单',
                glyph: AppGlyphs.lock,
                children: [
                  if (expired)
                    const XcCallout(
                      tone: XcTone.warning,
                      glyph: AppGlyphs.warning,
                      title: '订单已超过支付期限',
                      message: '请刷新状态后重新下单。',
                    ),
                  if (needsMethod)
                    for (final item in methods)
                      _MethodTile(
                        method: item,
                        amount: XcFormat.toInt(order['total_amount']) ?? 0,
                        selected: XcFormat.toInt(item['id']) == _method,
                        onTap: () => setState(
                          () => _method = XcFormat.toInt(item['id']),
                        ),
                      ),
                  if (method != null)
                    XcValue(
                      '支付手续费',
                      context.xcMoney(
                        XcOrders.handlingFee(
                          method,
                          XcFormat.toInt(order['total_amount']) ?? 0,
                        ),
                      ),
                    ),
                  if (needsMethod && methods.isEmpty)
                    const XcCallout(
                      tone: XcTone.warning,
                      glyph: AppGlyphs.warning,
                      title: '暂无可用支付方式，请联系客服。',
                    ),
                  if (!needsMethod)
                    Text(
                      '订单金额已由账户余额或优惠抵扣，确认后即可完成支付。',
                      style: XcType.caption(context),
                    ),
                  XcTaskButton(
                    label: needsMethod ? '前往支付' : '使用余额完成支付',
                    loadingLabel: '正在发起支付',
                    glyph: needsMethod
                        ? AppGlyphs.openExternal
                        : AppGlyphs.check,
                    size: XcButtonSize.large,
                    expand: true,
                    enabled: !expired && (!needsMethod || _method != null),
                    action: _pay,
                  ),
                  if (_payment case final payment?)
                    XcSwap(
                      value: payment.action,
                      alignment: Alignment.topCenter,
                      child: switch (payment.action) {
                        XcPayAction.showQr => _QrPanel(
                          payment: payment,
                          onOpen: () async {
                            if (!await xcOpenExternal(payment.uri!) &&
                                context.mounted) {
                              xcMessage(context, '无法打开支付链接');
                            }
                          },
                        ),
                        XcPayAction.openUrl => const XcCallout(
                          glyph: AppGlyphs.openExternal,
                          title: '已尝试在浏览器中打开支付页面，支付完成后请返回客户端。',
                        ),
                        XcPayAction.unsupported => const XcCallout(
                          tone: XcTone.danger,
                          glyph: AppGlyphs.error,
                          title: '此支付方式返回了暂不支持的内容，请更换支付方式或联系客服。',
                        ),
                        XcPayAction.paid => const SizedBox.shrink(),
                      },
                    ),
                  Row(
                    spacing: XcSpace.sm,
                    children: [
                      Expanded(
                        flex: 3,
                        child: XcTaskButton(
                          label: '刷新支付状态',
                          variant: XcButtonVariant.secondary,
                          action: _refresh,
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: XcTaskButton(
                          label: '取消订单',
                          variant: XcButtonVariant.danger,
                          action: _cancel,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            _OrderDetails(
              order: order,
              tradeNo: widget.tradeNo,
              pending: pending,
              deadline: deadline,
            ),
            if (!pending)
              XcTaskButton(
                label: '刷新订单状态',
                glyph: AppGlyphs.refresh,
                variant: XcButtonVariant.secondary,
                expand: true,
                action: _refresh,
              ),
          ]),
        );
      },
    ),
  );
}

class _Gap extends StatelessWidget {
  const _Gap(this.child);
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: XcSpace.md),
    child: child,
  );
}

class _OrderHero extends StatelessWidget {
  const _OrderHero({
    required this.order,
    required this.status,
    required this.expired,
    required this.deadline,
    required this.watching,
    required this.synced,
  });
  final Map<String, dynamic> order;
  final int status;
  final bool expired;
  final int? deadline;
  final bool watching;
  final bool synced;

  String get _hint => switch (status) {
    OrderStatus.pending when expired => '订单已超过支付期限，请重新下单',
    OrderStatus.pending => '请在 ${XcFormat.date(deadline)} 前完成支付',
    OrderStatus.processing => '支付已受理，正在为你开通套餐',
    OrderStatus.completed => '套餐已开通，回到首页即可连接',
    OrderStatus.discounted => '订单已折抵到新的订单中',
    OrderStatus.cancelled => '订单已取消，可以重新选购套餐',
    _ => '订单状态暂时无法识别，请刷新或联系客服',
  };

  @override
  Widget build(BuildContext context) {
    final style = xcOrderStyle(status);
    final colors = XcColors.of(context);
    return XcSection(
      children: [
        Row(
          spacing: XcSpace.md,
          children: [
            XcSwap(
              value: status,
              child: XcGlyphWell(
                glyph: style.glyph,
                tone: style.tone,
                size: 56,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 2,
                children: [
                  XcSwap(
                    value: status,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      XcOrders.statusLabel(status),
                      style: XcType.title(context).copyWith(
                        color: style.tone == XcTone.neutral
                            ? null
                            : colors.toneOf(style.tone),
                      ),
                    ),
                  ),
                  Text(
                    '${XcOrders.planName(order)} · '
                    '${XcOrders.periodLabel(order['period'])}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: XcType.body(context),
                  ),
                  Text(_hint, style: XcType.caption(context)),
                ],
              ),
            ),
          ],
        ),
        if (status != OrderStatus.cancelled)
          _OrderSteps(status: status, synced: synced),
        if (watching)
          Row(
            spacing: XcSpace.xs,
            children: [
              GlyphIcon(AppGlyphs.sync, size: 14, color: colors.muted),
              Text('正在自动确认支付结果…', style: XcType.caption(context)),
            ],
          ),
      ],
    );
  }
}

class _OrderSteps extends StatelessWidget {
  const _OrderSteps({required this.status, required this.synced});
  final int status;
  final bool synced;

  static const _labels = ['提交订单', '完成支付', '开通套餐', '同步节点'];

  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final reached = switch (status) {
      OrderStatus.pending => 1,
      OrderStatus.processing => 2,
      OrderStatus.completed || OrderStatus.discounted => synced ? 4 : 3,
      _ => 1,
    };
    return Row(
      children: [
        for (var index = 0; index < _labels.length; index++)
          Expanded(
            child: Column(
              spacing: 6,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: index == 0
                          ? const SizedBox()
                          : _StepLine(active: index <= reached),
                    ),
                    AnimatedContainer(
                      duration: XcMotion.of(context, XcMotion.standard),
                      width: 22,
                      height: 22,
                      decoration: ShapeDecoration(
                        color: index < reached
                            ? colors.accent
                            : index == reached
                            ? colors.accentSoft
                            : colors.block,
                        shape: CircleBorder(
                          side: index == reached
                              ? BorderSide(color: colors.accent, width: 1.5)
                              : BorderSide.none,
                        ),
                      ),
                      child: index < reached
                          ? GlyphIcon(
                              AppGlyphs.check,
                              size: 14,
                              color: colors.onAccent,
                            )
                          : null,
                    ),
                    Expanded(
                      child: index == _labels.length - 1
                          ? const SizedBox()
                          : _StepLine(active: index + 1 <= reached),
                    ),
                  ],
                ),
                Text(
                  _labels[index],
                  style: XcType.caption(
                    context,
                  ).copyWith(color: index <= reached ? colors.title : null),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.active});
  final bool active;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    return AnimatedContainer(
      duration: XcMotion.of(context, XcMotion.standard),
      height: 2,
      color: active ? colors.accent : colors.hairline,
    );
  }
}

class _OrderDetails extends StatelessWidget {
  const _OrderDetails({
    required this.order,
    required this.tradeNo,
    required this.pending,
    required this.deadline,
  });
  final Map<String, dynamic> order;
  final String tradeNo;
  final bool pending;
  final int? deadline;
  @override
  Widget build(BuildContext context) => XcSection(
    title: '订单信息',
    glyph: AppGlyphs.requests,
    children: [
      XcValue('订单号', tradeNo),
      XcValue(
        '类型 / 周期',
        '${XcOrders.typeLabel(order['type'])} / ${XcOrders.periodLabel(order['period'])}',
      ),
      XcValue('套餐金额', context.xcMoney(order['total_amount']), strong: true),
      XcValue('余额支付', context.xcMoney(order['balance_amount'])),
      XcValue('优惠金额', context.xcMoney(order['discount_amount'])),
      XcValue('折抵金额', context.xcMoney(order['surplus_amount'])),
      XcValue('创建时间', XcFormat.date(order['created_at'])),
      if (pending) XcValue('支付截止', XcFormat.date(deadline)),
      if (order['paid_at'] != null)
        XcValue('支付时间', XcFormat.date(order['paid_at'])),
    ],
  );
}

class _MethodTile extends StatelessWidget {
  const _MethodTile({
    required this.method,
    required this.amount,
    required this.selected,
    required this.onTap,
  });
  final Map<String, dynamic> method;
  final int amount;
  final bool selected;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final colors = XcColors.of(context);
    final fee = XcOrders.handlingFee(method, amount);
    return Semantics(
      button: true,
      selected: selected,
      child: AnimatedContainer(
        duration: XcMotion.of(context, XcMotion.standard),
        decoration: ShapeDecoration(
          color: selected ? colors.accentSoft : colors.block,
          shape: XcRadius.tile.copyWith(
            side: BorderSide(
              color: selected ? colors.accent : Colors.transparent,
              width: 1.5,
            ),
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: XcRadius.tile,
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                spacing: XcSpace.sm,
                children: [
                  GlyphIcon(
                    selected ? AppGlyphs.checkCircle : AppGlyphs.qrCode,
                    size: 20,
                    fill: selected ? 1 : 0,
                    color: selected ? colors.accent : colors.muted,
                  ),
                  Expanded(
                    child: Text(
                      '${method['name'] ?? method['payment'] ?? '支付方式'}',
                      style: XcType.body(context),
                    ),
                  ),
                  if (fee > 0)
                    Text(
                      '手续费 ${context.xcMoney(fee)}',
                      style: XcType.caption(context),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QrPanel extends StatelessWidget {
  const _QrPanel({required this.payment, required this.onOpen});
  final XcPayStep payment;
  final VoidCallback onOpen;
  @override
  Widget build(BuildContext context) => Column(
    spacing: XcSpace.sm,
    children: [
      DecoratedBox(
        decoration: ShapeDecoration(
          color: Colors.white,
          shape: XcRadius.card,
          shadows: XcShadow.card(XcColors.of(context)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(XcSpace.sm),
          child: XcPaymentQr(content: payment.qrContent!),
        ),
      ),
      Text(
        '请使用支付应用扫描二维码；完成后状态会自动刷新。',
        textAlign: TextAlign.center,
        style: XcType.secondary(context),
      ),
      if (payment.uri != null)
        XcButton(
          label: '打开支付链接',
          glyph: AppGlyphs.openExternal,
          variant: XcButtonVariant.ghost,
          size: XcButtonSize.small,
          onPressed: onOpen,
        ),
    ],
  );
}

class XcPaymentQr extends StatelessWidget {
  const XcPaymentQr({super.key, required this.content});
  final String content;
  @override
  Widget build(BuildContext context) {
    try {
      final qr = QrImage(QrCode(payload: QrPayload.fromString(content)));
      return Semantics(
        label: '支付二维码',
        image: true,
        child: CustomPaint(
          size: const Size.square(240),
          painter: _QrPainter(qr),
        ),
      );
    } catch (_) {
      return const Text('支付二维码内容无效，请更换支付方式。');
    }
  }
}

class _QrPainter extends CustomPainter {
  const _QrPainter(this.qr);
  final QrImage qr;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.white);
    final cell = size.shortestSide / (qr.moduleCount + 8);
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false;
    for (var row = 0; row < qr.moduleCount; row++) {
      for (var column = 0; column < qr.moduleCount; column++) {
        if (qr.isDark(row, column)) {
          canvas.drawRect(
            Rect.fromLTWH((column + 4) * cell, (row + 4) * cell, cell, cell),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter oldDelegate) => oldDelegate.qr != qr;
}
