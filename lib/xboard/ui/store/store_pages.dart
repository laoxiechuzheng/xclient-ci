import 'dart:async';

import 'package:fl_clash/ui/typography.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_clash/ui/loading.dart';
import 'package:qr/qr.dart';

import '../../core/api/xboard_api.dart';
import '../common/errors.dart';
import '../common/format.dart';
import '../common/commerce.dart';
import '../common/rich_content.dart';
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
      builder: (context, plans, refresh) => xcList([
        if (plans.isEmpty) const Text('暂无在售套餐'),
        for (final plan in plans)
          XcPlanCard(
            plan: plan,
            onBuy: () =>
                xcPush(context, XcPlanDetailPage(api: api, plan: plan)),
          ),
      ]),
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
    final price = XcPlans.displayPrice(plan);
    final soldOut = XcPlans.soldOut(plan);
    return XcSection(
      title: '${plan['name'] ?? '套餐'}',
      children: [
        if (price != null)
          Text(
            '${context.xcMoney(price.cents)} / ${price.label}',
            style: AppTextStyle.title1.of(context),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            Chip(label: Text(XcFormat.planTraffic(plan['transfer_enable']))),
            if (plan['speed_limit'] != null)
              Chip(label: Text('${plan['speed_limit']} Mbps')),
            if (plan['device_limit'] != null)
              Chip(label: Text('${plan['device_limit']} 台设备')),
            for (final tag in XcPlans.tags(plan)) Chip(label: Text(tag)),
          ],
        ),
        XcRichContent(content: '${plan['content'] ?? ''}'),
        FilledButton(
          onPressed: soldOut || price == null ? null : onBuy,
          child: Text(soldOut ? '暂时售罄' : '选择套餐'),
        ),
      ],
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
    final discount = await widget.api.checkCoupon(
      code: code,
      planId: XcFormat.toInt(widget.plan['id'])!,
      period: period,
    );
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
    final trade = await XcCheckoutFlow(widget.api).placeOrder(
      planId: XcFormat.toInt(widget.plan['id'])!,
      period: price.period,
      couponCode: code,
    );
    if (mounted) {
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => XcOrderPage(api: widget.api, tradeNo: trade),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final prices = XcPlans.prices(widget.plan, includeReset: true);
    final selected = _price;
    final discount = selected == null || _discount == null
        ? 0
        : XcCoupons.discount(_discount!, selected.cents);
    return XcPage(
      title: '${widget.plan['name'] ?? '套餐详情'}',
      child: xcList([
        XcSection(
          children: [
            XcRichContent(content: '${widget.plan['content'] ?? ''}'),
            const Text('选择付款周期'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final price in prices)
                  ChoiceChip(
                    label: Text(
                      '${price.label} ${context.xcMoney(price.cents)}',
                    ),
                    selected: price == selected,
                    onSelected: (_) => setState(() {
                      _price = price;
                      _discount = null;
                      _validatedCode = null;
                    }),
                  ),
              ],
            ),
            TextField(
              controller: _coupon,
              decoration: const InputDecoration(labelText: '优惠码（可选）'),
              autocorrect: false,
              onChanged: (_) {
                if (_discount != null) {
                  setState(() {
                    _discount = null;
                    _validatedCode = null;
                  });
                }
              },
            ),
            XcTaskButton(label: '验证优惠码', tonal: true, action: _check),
            if (_discount != null)
              Text(
                XcCoupons.describe(
                  _discount!,
                  symbol: context.xcCurrency.symbol,
                ),
              ),
            if (selected != null)
              XcValue('套餐金额', context.xcMoney(selected.cents)),
            if (discount > 0) XcValue('优惠', '-${context.xcMoney(discount)}'),
            if (selected != null)
              XcValue('预计金额', context.xcMoney(selected.cents - discount)),
            const Text('下单时优先使用账户余额，最终金额以订单详情为准。'),
            XcTaskButton(
              label: '创建订单',
              enabled: selected != null && !XcPlans.soldOut(widget.plan),
              action: _buy,
            ),
          ],
        ),
      ]),
    );
  }
}

class XcOrdersPage extends StatelessWidget {
  const XcOrdersPage({super.key, required this.api});
  final XboardApi api;
  @override
  Widget build(BuildContext context) => XcPage(
    title: '我的订单',
    child: XcLoad<List<Map<String, dynamic>>>(
      load: api.orders,
      builder: (context, orders, refresh) => xcList([
        if (orders.isEmpty) const Text('暂无订单'),
        for (final order in orders)
          XcSection(
            children: [
              XcValue(
                XcOrders.planName(order),
                XcOrders.statusLabel(XcOrders.status(order)),
              ),
              XcValue('订单金额', context.xcMoney(order['total_amount'])),
              XcValue('创建时间', XcFormat.date(order['created_at'])),
              TextButton(
                onPressed: () => xcPush(
                  context,
                  XcOrderPage(api: api, tradeNo: '${order['trade_no']}'),
                ),
                child: const Text('查看订单'),
              ),
            ],
          ),
      ]),
    ),
  );
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
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(xcErrorText(snapshot.error!)),
                TextButton(onPressed: _refresh, child: const Text('重试')),
              ],
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
        return RefreshIndicator(
          onRefresh: _refresh,
          child: xcList([
            XcSection(
              title: XcOrders.planName(order),
              children: [
                XcValue('状态', XcOrders.statusLabel(status)),
                XcValue('订单号', widget.tradeNo),
                XcValue(
                  '类型 / 周期',
                  '${XcOrders.typeLabel(order['type'])} / ${XcOrders.periodLabel(order['period'])}',
                ),
                XcValue('套餐金额', context.xcMoney(order['total_amount'])),
                XcValue('余额支付', context.xcMoney(order['balance_amount'])),
                XcValue('优惠金额', context.xcMoney(order['discount_amount'])),
                XcValue('折抵金额', context.xcMoney(order['surplus_amount'])),
                XcValue('创建时间', XcFormat.date(order['created_at'])),
                if (pending) XcValue('支付截止', XcFormat.date(deadline)),
                if (order['paid_at'] != null)
                  XcValue('支付时间', XcFormat.date(order['paid_at'])),
              ],
            ),
            if (status == OrderStatus.processing ||
                _payment?.action == XcPayAction.paid)
              const XcSection(
                children: [Text('支付已受理，套餐正在开通。开通完成后会自动刷新账户与节点。')],
              ),
            if (_refreshingEntitlements)
              const XcSection(
                children: [LinearProgressIndicator(), Text('套餐已开通，正在刷新账户与节点…')],
              ),
            if (_reconciled)
              const XcSection(children: [Text('套餐已开通，账户信息与节点同步已检查。')]),
            if (_entitlementError != null)
              XcSection(
                children: [
                  Text('订单已完成，刷新账户与节点失败：$_entitlementError'),
                  XcTaskButton(
                    label: '重试刷新账户与节点',
                    action: () => _reconcile(status),
                  ),
                ],
              ),
            if (_pollTimedOut)
              const XcSection(
                children: [Text('自动查询已暂停。可刷新状态，或稍后从“我的订单”重新进入查询。')],
              ),
            if (!pending)
              XcTaskButton(label: '刷新订单状态', tonal: true, action: _refresh),
            if (pending)
              XcSection(
                title: '支付订单',
                children: [
                  if (expired) const Text('订单已超过支付期限，请刷新状态后重新下单。'),
                  if (needsMethod)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final item in methods)
                          ChoiceChip(
                            label: Text(
                              '${item['name'] ?? item['payment'] ?? '支付方式'}',
                            ),
                            selected: XcFormat.toInt(item['id']) == _method,
                            onSelected: (_) => setState(
                              () => _method = XcFormat.toInt(item['id']),
                            ),
                          ),
                      ],
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
                    const Text('暂无可用支付方式，请联系客服。'),
                  XcTaskButton(
                    label: needsMethod ? '前往支付' : '使用余额完成支付',
                    enabled: !expired && (!needsMethod || _method != null),
                    action: _pay,
                  ),
                  if (_payment case final payment?) ...[
                    if (payment.action == XcPayAction.showQr) ...[
                      Center(child: XcPaymentQr(content: payment.qrContent!)),
                      const Text('请使用支付应用扫描二维码；完成后状态会自动刷新。'),
                      if (payment.uri != null)
                        TextButton(
                          onPressed: () async {
                            if (!await xcOpenExternal(payment.uri!) &&
                                context.mounted) {
                              xcMessage(context, '无法打开支付链接');
                            }
                          },
                          child: const Text('打开支付链接'),
                        ),
                    ],
                    if (payment.action == XcPayAction.openUrl)
                      const Text('已尝试在浏览器中打开支付页面，支付完成后请返回客户端。'),
                    if (payment.action == XcPayAction.unsupported)
                      const Text('此支付方式返回了暂不支持的内容，请更换支付方式或联系客服。'),
                  ],
                  XcTaskButton(label: '刷新支付状态', tonal: true, action: _refresh),
                  XcTaskButton(label: '取消订单', tonal: true, action: _cancel),
                ],
              ),
          ]),
        );
      },
    ),
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
