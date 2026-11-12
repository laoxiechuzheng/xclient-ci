import 'dart:async';

import '../../core/api/xboard_api.dart';
import '../common/format.dart';

// `paid` acknowledges payment; the panel may still be provisioning the plan.
enum XcPayAction { paid, showQr, openUrl, unsupported }

class XcPayStep {
  final XcPayAction action;

  final String? qrContent;

  final Uri? uri;

  const XcPayStep(this.action, {this.qrContent, this.uri});

  @override
  String toString() => 'XcPayStep(${action.name}, qr: $qrContent, uri: $uri)';
}

XcPayStep resolveCheckout(XbCheckoutResult result) {
  if (result.isPaid) return const XcPayStep(XcPayAction.paid);
  final qr = result.qrContent;
  if (qr != null && qr.isNotEmpty) {
    return XcPayStep(
      XcPayAction.showQr,
      qrContent: qr,
      uri: result.redirectUri,
    );
  }
  final uri = result.redirectUri;
  if (uri != null) return XcPayStep(XcPayAction.openUrl, uri: uri);
  return const XcPayStep(XcPayAction.unsupported);
}

bool xcNeedsPaymentMethod(Map<String, dynamic> order) =>
    (XcFormat.toInt(order['total_amount']) ?? 0) > 0;

class XcCheckoutFlow {
  final XboardApi api;

  const XcCheckoutFlow(this.api);

  Future<String> placeOrder({
    required int planId,
    required String period,
    String? couponCode,
  }) {
    final code = couponCode?.trim();
    return api.saveOrder(
      planId: planId,
      period: period,
      couponCode: code == null || code.isEmpty ? null : code,
    );
  }

  Future<XcPayStep> pay({required String tradeNo, int? methodId}) async {
    final result = await api.checkout(tradeNo: tradeNo, method: methodId);
    return resolveCheckout(result);
  }
}

class XcPaymentWatcher {
  final Future<int> Function() check;
  final Future<void> Function(int status)? onStatus;
  final Duration interval;
  final Duration timeout;

  bool _stopped = false;

  XcPaymentWatcher({
    required this.check,
    this.onStatus,
    this.interval = const Duration(seconds: 3),
    this.timeout = const Duration(minutes: 30),
  });

  bool get stopped => _stopped;

  void stop() => _stopped = true;

  Future<int?> waitWhilePending() async {
    // status 1 is processing; only status 3 confirms entitlement changes.
    final deadline = DateTime.now().add(timeout);
    while (!_stopped && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      if (_stopped) return null;
      try {
        final status = await check();
        if (_stopped) return null;
        await onStatus?.call(status);
        if (status == OrderStatus.completed ||
            status == OrderStatus.cancelled ||
            status == OrderStatus.discounted) {
          return status;
        }
      } catch (_) {
        // A network blip; the next tick asks again.
      }
    }
    return null;
  }
}

bool xcOrderSucceeded(int status) => status == OrderStatus.completed;
