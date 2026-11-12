import 'package:material_ui/material_ui.dart';

import 'format.dart';

/// Panel currency belongs to this authenticated UI tree, never a process global.
class XcCurrency {
  const XcCurrency({required this.code, required this.symbol});
  static const cny = XcCurrency(code: 'CNY', symbol: '¥');
  final String code;
  final String symbol;

  factory XcCurrency.fromConfig(Map<String, dynamic> config) {
    final rawCode = '${config['currency'] ?? ''}'.trim().toUpperCase();
    final code = rawCode.isEmpty ? 'CNY' : rawCode;
    final rawSymbol = '${config['currency_symbol'] ?? ''}'.trim();
    final symbol = rawSymbol.isNotEmpty
        ? rawSymbol
        : switch (code) {
            'CNY' => '¥',
            'USD' => r'$',
            'EUR' => '€',
            'GBP' => '£',
            'JPY' => '¥',
            _ => '$code ',
          };
    return XcCurrency(code: code, symbol: symbol);
  }

  String money(Object? cents) => XcFormat.money(cents, symbol: symbol);
}

/// Deduplicates completed orders for one login. A failed refresh can be retried.
class XcEntitlementRefresh {
  XcEntitlementRefresh(this.refresh);
  final Future<void> Function() refresh;
  final _orders = <String, Future<void>>{};

  Future<void> orderCompleted(String tradeNo) {
    final existing = _orders[tradeNo];
    if (existing != null) return existing;
    final future = Future<void>.sync(refresh);
    _orders[tradeNo] = future;
    return future.catchError((Object error, StackTrace stack) {
      if (identical(_orders[tradeNo], future)) _orders.remove(tradeNo);
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> giftCardRedeemed() => refresh();
}

/// Placed above the account Navigator so every purchase route shares it.
class XcCommerceScope extends InheritedWidget {
  const XcCommerceScope({
    super.key,
    required this.currency,
    required this.entitlements,
    required super.child,
  });
  final XcCurrency currency;
  final XcEntitlementRefresh entitlements;

  static XcCommerceScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<XcCommerceScope>();

  @override
  bool updateShouldNotify(XcCommerceScope oldWidget) =>
      oldWidget.currency != currency || oldWidget.entitlements != entitlements;
}

extension XcCommerceContext on BuildContext {
  XcCurrency get xcCurrency =>
      XcCommerceScope.maybeOf(this)?.currency ?? XcCurrency.cny;
  String xcMoney(Object? cents) => xcCurrency.money(cents);
}
