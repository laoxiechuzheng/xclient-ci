import 'dart:io' show InternetAddress;

import '../net/api_client.dart';
import '../net/api_exception.dart';

class XbPage {
  final List<Map<String, dynamic>> items;
  final int total;

  const XbPage(this.items, this.total);

  static XbPage fromJson(Object? json) {
    if (json is! Map) return const XbPage([], 0);
    final data = json['data'];
    final total = json['total'];
    return XbPage([
      if (data is List)
        for (final item in data)
          if (item is Map<String, dynamic>) item,
    ], total is num ? total.toInt() : 0);
  }
}

class XbCheckoutResult {
  final int type;
  final Object? data;

  const XbCheckoutResult(this.type, this.data);

  bool get isPaid => type == -1 || data == true;

  String? get qrContent => type == 0 && data is String ? data as String : null;

  Uri? get redirectUri {
    final value = data;
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    return type == 1 || type == 0 ? uri : null;
  }
}

abstract final class PlanPeriod {
  static const month = 'month_price';
  static const quarter = 'quarter_price';
  static const halfYear = 'half_year_price';
  static const year = 'year_price';
  static const twoYear = 'two_year_price';
  static const threeYear = 'three_year_price';
  static const onetime = 'onetime_price';
  static const reset = 'reset_price';

  static const all = [
    month,
    quarter,
    halfYear,
    year,
    twoYear,
    threeYear,
    onetime,
    reset,
  ];

  static const labels = {
    month: '月付',
    quarter: '季付',
    halfYear: '半年付',
    year: '年付',
    twoYear: '两年付',
    threeYear: '三年付',
    onetime: '一次性',
    reset: '流量重置包',
  };
}

abstract final class OrderStatus {
  static const pending = 0;
  static const processing = 1;
  static const cancelled = 2;
  static const completed = 3;
  static const discounted = 4;

  static const labels = {
    pending: '待支付',
    processing: '开通中',
    cancelled: '已取消',
    completed: '已完成',
    discounted: '已折抵',
  };
}

/// Never returns panel subscription URLs or tokens to callers.
class XboardApi {
  final ApiClient client;
  final String? _checkoutReferer;

  XboardApi(this.client, {String? checkoutWebUrl})
    : _checkoutReferer = _checkoutOrigin(checkoutWebUrl);

  static String? _checkoutOrigin(String? value) {
    if (value == null || value.isEmpty) return null;
    const invalid = FormatException(
      'checkoutWebUrl must be a valid HTTPS URL without user info',
    );
    if (RegExp(r'[\s\x00-\x1f\x7f]', unicode: true).hasMatch(value)) {
      throw invalid;
    }
    final authority = RegExp(
      r'^https://(\[[A-Fa-f0-9:.]+\]|[A-Za-z0-9.-]+)(?::([0-9]+))?(?:[/?#]|$)',
      caseSensitive: false,
    ).firstMatch(value);
    final uri = Uri.tryParse(value);
    if (authority == null || uri == null || uri.host.isEmpty) throw invalid;
    final rawPort = authority.group(2);
    final port = rawPort == null ? null : int.tryParse(rawPort);
    if (rawPort != null && (port == null || port < 1 || port > 65535)) {
      throw invalid;
    }
    var host = uri.host;
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    }
    if (InternetAddress.tryParse(host) == null) {
      final dns = host.endsWith('.')
          ? host.substring(0, host.length - 1)
          : host;
      final label = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
      if (dns.length > 253 ||
          RegExp(r'^[0-9.]+$').hasMatch(dns) ||
          dns.split('.').any((part) => !label.hasMatch(part))) {
        throw invalid;
      }
    }
    // Build a fresh origin: replace(query: null) would preserve a private query.
    return Uri(scheme: 'https', host: host, port: port, path: '/').toString();
  }

  static const _user = '/api/v1/user';
  static const _plugin = '/api/v1/xclient';

  Future<Object?> _get(String path, [Map<String, Object?>? query]) =>
      client.call('GET', path, query: query);

  Future<Object?> _post(String path, Map<String, Object?> form) =>
      client.call('POST', path, form: form, idempotent: false);

  Map<String, dynamic> _map(Object? value) =>
      value is Map<String, dynamic> ? value : <String, dynamic>{};

  List<Map<String, dynamic>> _list(Object? value) => [
    if (value is List)
      for (final item in value)
        if (item is Map<String, dynamic>) item,
  ];

  Future<Map<String, dynamic>> guestConfig() async =>
      _map(await client.call('GET', '/api/v1/guest/comm/config', auth: false));

  Future<Map<String, dynamic>> userInfo() async =>
      _map(await _get('$_user/info'));

  /// `[pending orders, open tickets, invited users]`.
  Future<List<int>> stat() async {
    final data = await _get('$_user/getStat');
    return [
      if (data is List)
        for (final item in data) item is num ? item.toInt() : 0,
    ];
  }

  Future<Map<String, dynamic>> subscribeSummary() async {
    final data =
        Map<String, dynamic>.of(_map(await _get('$_user/getSubscribe')))
          ..remove('subscribe_url')
          ..remove('token');
    return data;
  }

  Future<Map<String, dynamic>> commConfig() async =>
      _map(await _get('$_user/comm/config'));

  Future<List<Map<String, dynamic>>> activeSessions() async => [
    for (final session in _list(await _get('$_user/getActiveSession')))
      {
        for (final key in [
          'id',
          'name',
          'created_at',
          'last_used_at',
          'expires_at',
        ])
          if (session.containsKey(key)) key: session[key],
      },
  ];

  Future<void> removeActiveSession(int id) async {
    await _post('$_user/removeActiveSession', {'session_id': id});
  }

  Future<Map<String, dynamic>> telegramBotInfo() async =>
      _map(await _get('$_user/telegram/getBotInfo'));

  Future<Map<String, dynamic>> giftCardCheck(String code) async =>
      _map(await _post('$_user/gift-card/check', {'code': code}));

  Future<Map<String, dynamic>> giftCardRedeem(String code) async =>
      _map(await _post('$_user/gift-card/redeem', {'code': code}));

  Future<XbPage> giftCardHistory({int page = 1, int pageSize = 15}) async {
    final raw = _map(
      await client.call(
        'GET',
        '$_user/gift-card/history',
        shape: ApiShape.raw,
        query: {'page': page, 'per_page': pageSize.clamp(1, 100)},
      ),
    );
    return XbPage.fromJson({
      'data': raw['data'],
      'total': _map(raw['pagination'])['total'],
    });
  }

  Future<Map<String, dynamic>> giftCardDetail(int id) async =>
      _map(await _get('$_user/gift-card/detail', {'id': id}));

  Future<Map<String, dynamic>> giftCardTypes() async =>
      _map(await _get('$_user/gift-card/types'));

  Future<void> changePassword(String oldPassword, String newPassword) async {
    await _post('$_user/changePassword', {
      'old_password': oldPassword,
      'new_password': newPassword,
    });
  }

  /// Resets node credentials; the returned URL is discarded. Sync afterwards.
  Future<void> resetSecurity() async {
    await _get('$_user/resetSecurity');
  }

  Future<void> updateRemind({bool? expire, bool? traffic}) async {
    await _post('$_user/update', {
      if (expire != null) 'remind_expire': expire ? 1 : 0,
      if (traffic != null) 'remind_traffic': traffic ? 1 : 0,
    });
  }

  Future<XbPage> notices({int page = 1}) async {
    final data = await client.call(
      'GET',
      '$_user/notice/fetch',
      shape: ApiShape.raw,
      query: {'current': page},
    );
    return XbPage.fromJson(data);
  }

  /// The panel lists only articles matching the requested language.
  Future<Map<String, List<Map<String, dynamic>>>> knowledge({
    String language = 'zh-CN',
    String? keyword,
  }) async {
    final data = await _get('$_user/knowledge/fetch', {
      'language': language,
      if (keyword != null && keyword.isNotEmpty) 'keyword': keyword,
    });
    if (data is! Map) return {};
    return {
      for (final MapEntry(:key, :value) in data.entries) '$key': _list(value),
    };
  }

  /// Redacts subscription URLs the panel may embed in article bodies.
  Future<Map<String, dynamic>> knowledgeArticle(
    int id, {
    String language = 'zh-CN',
  }) async {
    final article = Map<String, dynamic>.of(
      _map(
        await _get('$_user/knowledge/fetch', {'id': id, 'language': language}),
      ),
    );
    final body = article['body'];
    if (body is String) {
      article['body'] = await _redact(body);
    }
    return article;
  }

  static const redactedText = '（已隐藏）';

  Future<String> _redact(String text) async {
    try {
      final raw = _map(await _get('$_user/getSubscribe'));
      var result = text;
      for (final secret in [raw['subscribe_url'], raw['token']]) {
        if (secret is String && secret.length >= 8) {
          result = result.replaceAll(secret, redactedText);
        }
      }
      return result.replaceAll(
        RegExp(r'https?://[^\s"<>]*[?&]token=[A-Za-z0-9]+'),
        redactedText,
      );
    } on XbApiException {
      return text.replaceAll(
        RegExp(r'https?://[^\s"<>]*[?&]token=[A-Za-z0-9]+'),
        redactedText,
      );
    }
  }

  Future<List<Map<String, dynamic>>> plans() async =>
      _list(await _get('$_user/plan/fetch'));

  Future<Map<String, dynamic>> plan(int id) async =>
      _map(await _get('$_user/plan/fetch', {'id': id}));

  Future<Map<String, dynamic>> checkCoupon({
    required String code,
    required int planId,
    required String period,
  }) async => _map(
    await _post('$_user/coupon/check', {
      'code': code,
      'plan_id': planId,
      'period': period,
    }),
  );

  /// The panel spends account balance before external payment.
  Future<String> saveOrder({
    required int planId,
    required String period,
    String? couponCode,
  }) async {
    final data = await _post('$_user/order/save', {
      'plan_id': planId,
      'period': period,
      if (couponCode != null && couponCode.isNotEmpty)
        'coupon_code': couponCode,
    });
    if (data is! String || data.isEmpty) {
      throw const XbApiException(XbErrorKind.badResponse, message: 'trade_no');
    }
    return data;
  }

  Future<XbCheckoutResult> checkout({
    required String tradeNo,
    int? method,
  }) async {
    final data = await client.call(
      'POST',
      '$_user/order/checkout',
      shape: ApiShape.raw,
      headers: {'referer': ?_checkoutReferer},
      form: {'trade_no': tradeNo, 'method': ?method},
      idempotent: false,
    );
    if (data is! Map) {
      throw const XbApiException(XbErrorKind.badResponse);
    }
    final type = data['type'];
    return XbCheckoutResult(type is num ? type.toInt() : 1, data['data']);
  }

  Future<int> checkOrder(String tradeNo) async {
    final data = await _get('$_user/order/check', {'trade_no': tradeNo});
    return data is num ? data.toInt() : int.tryParse('$data') ?? -1;
  }

  Future<Map<String, dynamic>> orderDetail(String tradeNo) async =>
      _map(await _get('$_user/order/detail', {'trade_no': tradeNo}));

  Future<List<Map<String, dynamic>>> orders({int? status}) async =>
      _list(await _get('$_user/order/fetch', {'status': status}));

  Future<void> cancelOrder(String tradeNo) async {
    await _post('$_user/order/cancel', {'trade_no': tradeNo});
  }

  Future<List<Map<String, dynamic>>> paymentMethods() async =>
      _list(await _get('$_user/order/getPaymentMethod'));

  Future<void> createInviteCode() async {
    await _get('$_user/invite/save');
  }

  Future<Map<String, dynamic>> invites() async =>
      _map(await _get('$_user/invite/fetch'));

  Future<XbPage> inviteDetails({int page = 1, int pageSize = 10}) async {
    final data = await client.call(
      'GET',
      '$_user/invite/details',
      shape: ApiShape.raw,
      query: {'current': page, 'page_size': pageSize < 10 ? 10 : pageSize},
    );
    return XbPage.fromJson(data);
  }

  Future<void> transferCommission(int amountCents) async {
    await _post('$_user/transfer', {'transfer_amount': amountCents});
  }

  Future<void> withdrawCommission({
    required String method,
    required String account,
  }) async {
    await _post('$_user/ticket/withdraw', {
      'withdraw_method': method,
      'withdraw_account': account,
    });
  }

  Future<List<Map<String, dynamic>>> tickets() async =>
      _list(await _get('$_user/ticket/fetch'));

  Future<Map<String, dynamic>> ticket(int id) async =>
      _map(await _get('$_user/ticket/fetch', {'id': id}));

  Future<void> createTicket({
    required String subject,
    required int level,
    required String message,
  }) async {
    await _post('$_user/ticket/save', {
      'subject': subject,
      'level': level,
      'message': message,
    });
  }

  Future<void> replyTicket(int id, String message) async {
    await _post('$_user/ticket/reply', {'id': id, 'message': message});
  }

  Future<void> closeTicket(int id) async {
    await _post('$_user/ticket/close', {'id': id});
  }

  Future<List<Map<String, dynamic>>> trafficLog() async =>
      _list(await _get('$_user/stat/getTrafficLog'));

  Future<XbPage?> loginLog({int page = 1, int pageSize = 15}) async {
    try {
      final data = await client.call(
        'GET',
        '$_user/loginLog/fetch',
        shape: ApiShape.raw,
        query: {'current': page, 'page_size': pageSize},
      );
      return XbPage.fromJson(data);
    } on XbApiException catch (e) {
      if (e.kind == XbErrorKind.notFound) return null;
      rethrow;
    }
  }

  Future<Map<String, dynamic>?> trafficCycle({
    int historyPage = 1,
    int historySize = 10,
    int eventsSize = 20,
  }) async {
    try {
      return _map(
        await _get('$_user/trafficCycle/fetch', {
          'history_page': historyPage,
          'history_size': historySize,
          'events_size': eventsSize,
        }),
      );
    } on XbApiException catch (e) {
      if (e.kind == XbErrorKind.notFound) return null;
      rethrow;
    }
  }

  /// Available before registration so users can free a device slot.
  Future<List<Map<String, dynamic>>> devices() async => _list(
    await client.call(
      'GET',
      '$_plugin/devices',
      shape: ApiShape.plugin,
      device: true,
    ),
  );

  Future<void> revokeDevice(String deviceId) async {
    await client.call(
      'POST',
      '$_plugin/devices/revoke',
      shape: ApiShape.plugin,
      device: true,
      json: {'device_id': deviceId},
      idempotent: true,
    );
  }

  Future<Map<String, dynamic>> ping() async => _map(
    await client.call(
      'GET',
      '$_plugin/ping',
      shape: ApiShape.plugin,
      auth: false,
    ),
  );
}
