import '../../core/api/xboard_api.dart';

abstract final class XcFormat {
  static const _gib = 1024 * 1024 * 1024;

  static int? toInt(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v.trim()) ?? double.tryParse(v)?.toInt(),
    final bool v => v ? 1 : 0,
    _ => null,
  };

  static double? toDouble(Object? value) => switch (value) {
    final num v => v.toDouble(),
    final String v => double.tryParse(v.trim()),
    _ => null,
  };

  static bool toBool(Object? value) => switch (value) {
    final bool v => v,
    final num v => v != 0,
    final String v => v == '1' || v.toLowerCase() == 'true',
    _ => false,
  };

  static String money(Object? cents, {String symbol = '¥'}) {
    final value = (toDouble(cents) ?? 0) / 100;
    final text = value.abs().toStringAsFixed(2);
    return '${value < 0 ? '-' : ''}$symbol$text';
  }

  static String bytes(Object? bytes) {
    final value = toDouble(bytes) ?? 0;
    if (value <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    var exp = 0;
    var scaled = value;
    while (scaled >= 1024 && exp < units.length - 1) {
      scaled /= 1024;
      exp++;
    }
    var fixed = scaled.toStringAsFixed(exp == 0 ? 0 : 2);
    if (fixed.contains('.')) {
      fixed = fixed.replaceFirst(RegExp(r'\.?0+$'), '');
    }
    return '$fixed ${units[exp]}';
  }

  static String planTraffic(Object? gb) {
    final value = toDouble(gb);
    if (value == null || value <= 0) return '不限流量';
    return bytes(value * _gib);
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  static DateTime? dateTimeOf(Object? seconds) {
    final value = toInt(seconds);
    if (value == null) {
      return seconds is String ? DateTime.tryParse(seconds)?.toLocal() : null;
    }
    if (value <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(value * 1000);
  }

  static String date(Object? seconds, {bool withTime = true}) {
    final time = dateTimeOf(seconds);
    if (time == null) return '—';
    final day = '${time.year}-${_pad(time.month)}-${_pad(time.day)}';
    return withTime ? '$day ${_pad(time.hour)}:${_pad(time.minute)}' : day;
  }

  static String duration(int seconds) {
    final minutes = (seconds < 0 ? 0 : seconds) ~/ 60;
    final days = minutes ~/ 1440;
    final hours = (minutes % 1440) ~/ 60;
    final rest = minutes % 60;
    if (days > 0) return hours > 0 ? '$days 天 $hours 小时' : '$days 天';
    if (hours > 0) return rest > 0 ? '$hours 小时 $rest 分钟' : '$hours 小时';
    return '${rest < 1 ? 1 : rest} 分钟';
  }

  static int? daysLeft(Object? seconds, {DateTime? now}) {
    final end = toInt(seconds);
    if (end == null || end <= 0) return null;
    final current = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final diff = end - current;
    return diff >= 0 ? (diff + 86399) ~/ 86400 : -(((-diff) + 86399) ~/ 86400);
  }

  static String expiry(Object? seconds, {DateTime? now}) {
    final days = daysLeft(seconds, now: now);
    if (days == null) return '长期有效';
    if (days < 0) return '${date(seconds, withTime: false)}（已过期）';
    return '${date(seconds, withTime: false)}（剩 $days 天）';
  }
}

class XcPlanPrice {
  final String period;
  final int cents;

  const XcPlanPrice(this.period, this.cents);

  static const months = {
    PlanPeriod.month: 1,
    PlanPeriod.quarter: 3,
    PlanPeriod.halfYear: 6,
    PlanPeriod.year: 12,
    PlanPeriod.twoYear: 24,
    PlanPeriod.threeYear: 36,
  };

  String get label => PlanPeriod.labels[period] ?? period;

  int? get monthCount => months[period];

  int? get monthlyCents {
    final count = monthCount;
    if (count == null || count <= 1) return null;
    return (cents / count).round();
  }

  @override
  bool operator ==(Object other) =>
      other is XcPlanPrice && other.period == period && other.cents == cents;

  @override
  int get hashCode => Object.hash(period, cents);

  @override
  String toString() => 'XcPlanPrice($period, $cents)';
}

abstract final class XcPlans {
  static List<XcPlanPrice> prices(
    Map<String, dynamic> plan, {
    bool includeReset = false,
  }) {
    return [
      for (final period in PlanPeriod.all)
        if (includeReset || period != PlanPeriod.reset)
          if (XcFormat.toInt(plan[period]) case final cents?)
            XcPlanPrice(period, cents),
    ];
  }

  static const _displayOrder = [
    PlanPeriod.onetime,
    PlanPeriod.month,
    PlanPeriod.quarter,
    PlanPeriod.halfYear,
    PlanPeriod.year,
    PlanPeriod.twoYear,
    PlanPeriod.threeYear,
  ];

  static XcPlanPrice? displayPrice(Map<String, dynamic> plan) {
    for (final period in _displayOrder) {
      if (XcFormat.toInt(plan[period]) case final cents?) {
        return XcPlanPrice(period, cents);
      }
    }
    return null;
  }

  static int saving(Map<String, dynamic> plan, XcPlanPrice price) {
    final month = XcFormat.toInt(plan[PlanPeriod.month]);
    final count = price.monthCount;
    if (month == null || month <= 0 || count == null || count <= 1) return 0;
    final ratio = 1 - price.cents / (month * count);
    final percent = (ratio * 100).round();
    return percent > 0 ? percent : 0;
  }

  static bool soldOut(Map<String, dynamic> plan) {
    final capacity = plan['capacity_limit'];
    if (capacity == null) return false;
    final value = XcFormat.toInt(capacity);
    return value == null || value <= 0;
  }

  static List<String> tags(Map<String, dynamic> plan) {
    final tags = plan['tags'];
    return [
      if (tags is List)
        for (final tag in tags)
          if ('$tag'.trim().isNotEmpty) '$tag'.trim(),
    ];
  }

  static int? resetPriceCents(Map<String, dynamic>? plan) {
    if (plan == null) return null;
    // getSubscribe uses major units; PlanResource's reset_price uses cents.
    final prices = plan['prices'];
    if (prices is Map) {
      final yuan = XcFormat.toDouble(prices['reset_traffic']);
      if (yuan != null && yuan > 0) return (yuan * 100).round();
    }
    final cents = XcFormat.toInt(plan[PlanPeriod.reset]);
    return cents != null && cents > 0 ? cents : null;
  }
}

abstract final class XcCoupons {
  static int discount(Map<String, dynamic> coupon, int priceCents) {
    final type = XcFormat.toInt(coupon['type']);
    final value = XcFormat.toDouble(coupon['value']) ?? 0;
    final raw = switch (type) {
      1 => value.round(),
      2 => (priceCents * value / 100).round(),
      _ => 0,
    };
    if (raw <= 0) return 0;
    return raw > priceCents ? priceCents : raw;
  }

  static String describe(Map<String, dynamic> coupon, {String symbol = '¥'}) {
    final type = XcFormat.toInt(coupon['type']);
    final value = XcFormat.toDouble(coupon['value']) ?? 0;
    final name = '${coupon['name'] ?? ''}'.trim();
    final text = switch (type) {
      1 => '立减 ${XcFormat.money(value, symbol: symbol)}',
      2 => '优惠 ${_trim(value)}%',
      _ => '已验证',
    };
    return name.isEmpty ? text : '$name · $text';
  }

  static String _trim(double value) => value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsFixed(2);
}

abstract final class XcOrders {
  static const defaultPaySeconds = 7200;

  static const typeLabels = {1: '新购', 2: '续费', 3: '升级', 4: '流量重置'};

  static int? deadline(Map<String, dynamic> order) {
    final expires = XcFormat.toInt(order['expires_at']);
    if (expires != null && expires > 0) return expires;
    final created = XcFormat.toInt(order['created_at']);
    if (created == null || created <= 0) return null;
    return created + defaultPaySeconds;
  }

  static int status(Map<String, dynamic> order) =>
      XcFormat.toInt(order['status']) ?? -1;

  static bool isPending(Map<String, dynamic> order) =>
      status(order) == OrderStatus.pending;

  static String statusLabel(int status) => OrderStatus.labels[status] ?? '未知状态';

  static String typeLabel(Object? type) =>
      typeLabels[XcFormat.toInt(type)] ?? '订单';

  static String periodLabel(Object? period) =>
      PlanPeriod.labels['$period'] ?? '$period';

  static String planName(Map<String, dynamic> order) {
    final plan = order['plan'];
    if (plan is Map && plan['name'] != null) return '${plan['name']}';
    return '套餐 #${order['plan_id'] ?? '—'}';
  }

  static int handlingFee(Map<String, dynamic> method, int amountCents) {
    final fixed = XcFormat.toInt(method['handling_fee_fixed']) ?? 0;
    final percent = XcFormat.toDouble(method['handling_fee_percent']) ?? 0;
    if (fixed <= 0 && percent <= 0) return 0;
    return (amountCents * percent / 100).round() + fixed;
  }
}

abstract final class XcTickets {
  static const levelLabels = {0: '低', 1: '中', 2: '高'};

  static String levelLabel(Object? level) =>
      levelLabels[XcFormat.toInt(level)] ?? '—';

  static bool isClosed(Map<String, dynamic> ticket) =>
      XcFormat.toInt(ticket['status']) == 1;

  static String statusLabel(Map<String, dynamic> ticket) {
    if (isClosed(ticket)) return '已关闭';
    return XcFormat.toInt(ticket['reply_status']) == 1 ? '已回复' : '待回复';
  }
}

abstract final class XcCycleText {
  static const reasons = {
    'purchase': '新购套餐，开启新周期',
    'upgrade': '更换套餐，开启新周期',
    'onetime': '购买一次性流量',
    'rollover': '上一周期结束，自动进入新周期',
    'catch_up': '从最近的周期点开始',
    'advance': '流量用尽，提前开启本周期',
    'advanced': '流量用尽，提前结束并开启下一周期',
    'admin': '管理员调整，周期重新开始',
    'bootstrap': '启用周期记录时建立',
    'replaced': '被新购、换套餐或管理员重设替换',
    'expired': '订阅到期',
    'cycle_rollover': '周期到期，已用流量清零并进入新周期',
    'auto_advance': '流量用尽，提前开启下一周期',
    'new_purchase': '新购套餐时清零',
    'plan_change': '更换套餐时清零',
    'onetime_purchase': '购买一次性流量时清零',
    'renewal_reset': '续费时清零',
    'reset_package': '购买流量重置包，本周期已用流量清零',
    'gift_card_reset': '礼品卡重置流量',
    'admin_reset': '管理员手动重置流量',
    'admin_restart': '管理员重设周期时清零',
    'admin_usage_edit': '管理员修改了已用流量',
    'order_reset': '订单开通时清零',
  };

  static const resetMethods = {
    'monthly': '按月（购买日）重置',
    'first_day_month': '每月 1 日重置',
    'yearly': '按年（购买日）重置',
    'first_day_year': '每年 1 月 1 日重置',
    'never': '不重置',
  };

  static const advanceReasons = {
    'eligible': '流量用尽时可提前开启下一周期',
    'no_cycle': '当前没有周期',
    'no_expiry': '长期套餐不支持提前换周期',
    'final_cycle': '本周期已是最后一个周期',
    'remaining_too_short': '剩余有效期不足',
    'disabled': '未开启提前换周期',
  };

  static String reason(Object? code) =>
      reasons['$code'] ?? (code == null ? '—' : '$code');
}
