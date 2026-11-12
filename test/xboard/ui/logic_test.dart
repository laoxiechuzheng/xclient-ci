import 'package:fl_clash/xboard/core/api/xboard_api.dart';
import 'package:fl_clash/xboard/ui/common/errors.dart';
import 'package:fl_clash/xboard/ui/common/format.dart';
import 'package:fl_clash/xboard/ui/common/commerce.dart';
import 'package:fl_clash/xboard/ui/common/widgets.dart';
import 'package:fl_clash/xboard/ui/store/checkout_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'panel currency config is immutable and falls back only when absent',
    () {
      final usd = XcCurrency.fromConfig({
        'currency': 'USD',
        'currency_symbol': r'$',
      });
      expect(usd.money(1234), r'$12.34');
      expect(XcCurrency.fromConfig({'currency': 'USD'}).money(1234), r'$12.34');
      expect(XcCurrency.fromConfig({}).money(1234), '¥12.34');
      expect(
        XcCurrency.fromConfig({'currency': 'CHF'}).money(1234),
        'CHF 12.34',
      );
      expect(usd.money(1234), r'$12.34');
    },
  );
  test(
    'completed orders refresh once per login and retry failed refreshes',
    () async {
      var calls = 0;
      var fail = true;
      final effects = XcEntitlementRefresh(() async {
        calls++;
        if (fail) throw StateError('offline');
      });
      await expectLater(effects.orderCompleted('one'), throwsStateError);
      fail = false;
      await Future.wait([
        effects.orderCompleted('one'),
        effects.orderCompleted('one'),
      ]);
      await effects.orderCompleted('one');
      expect(calls, 2);
      await effects.giftCardRedeemed();
      expect(calls, 3);
    },
  );
  test(
    'cancelled and discounted orders stop polling without provisioning',
    () async {
      for (final status in [OrderStatus.cancelled, OrderStatus.discounted]) {
        final watcher = XcPaymentWatcher(
          check: () async => status,
          interval: Duration.zero,
        );
        expect(await watcher.waitWhilePending(), status);
        expect(xcOrderSucceeded(status), isFalse);
      }
    },
  );
  test('processing is not entitlement completion', () {
    expect(xcOrderSucceeded(OrderStatus.processing), isFalse);
    expect(xcOrderSucceeded(OrderStatus.discounted), isFalse);
    expect(xcOrderSucceeded(OrderStatus.completed), isTrue);
  });
  test(
    'payment polling continues through processing until completed',
    () async {
      final statuses = [
        OrderStatus.pending,
        OrderStatus.processing,
        OrderStatus.processing,
        OrderStatus.completed,
      ];
      final watcher = XcPaymentWatcher(
        check: () async => statuses.removeAt(0),
        interval: Duration.zero,
      );
      expect(await watcher.waitWhilePending(), OrderStatus.completed);
      expect(statuses, isEmpty);
    },
  );
  test('login validates email and an eight-character password', () {
    expect(validateLoginEmail(''), isNotNull);
    expect(validateLoginEmail('invalid'), isNotNull);
    expect(validateLoginEmail('demo@example.invalid'), isNull);
    expect(validateLoginPassword('1234567'), isNotNull);
    expect(validateLoginPassword('12345678'), isNull);
  });
  test('a subscription expired one second ago is expired', () {
    final now = DateTime.utc(2026, 11, 4);
    final expired = now.millisecondsSinceEpoch ~/ 1000 - 1;
    expect(XcFormat.expiry(expired, now: now), contains('已过期'));
  });
  test('session timestamps accept the panel ISO format', () {
    expect(
      XcFormat.dateTimeOf('2026-11-04T00:00:00.000000Z')?.toUtc(),
      DateTime.utc(2026, 11, 4),
    );
  });
  test('external links reject non-https and embedded credentials', () async {
    expect(await xcOpenExternal(Uri.parse('http://example.invalid')), isFalse);
    expect(await xcOpenExternal(Uri.parse('javascript:alert(1)')), isFalse);
    expect(
      await xcOpenExternal(Uri.parse('https://name:secret@example.invalid')),
      isFalse,
    );
  });
  test('free plan prices remain available while null periods are hidden', () {
    final prices = XcPlans.prices({'month_price': 0, 'year_price': null});
    expect(prices, [const XcPlanPrice(PlanPeriod.month, 0)]);
    expect(XcFormat.money(1234), '¥12.34');
  });
  test('checkout resolves paid, qr, redirect and unsupported results', () {
    expect(
      resolveCheckout(const XbCheckoutResult(-1, true)).action,
      XcPayAction.paid,
    );
    expect(
      resolveCheckout(const XbCheckoutResult(0, 'payment-value')).action,
      XcPayAction.showQr,
    );
    expect(
      resolveCheckout(
        const XbCheckoutResult(1, 'https://example.invalid/pay'),
      ).action,
      XcPayAction.openUrl,
    );
    expect(
      resolveCheckout(const XbCheckoutResult(1, 'javascript:alert(1)')).action,
      XcPayAction.unsupported,
    );
  });
}
