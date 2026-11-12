import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/api/xboard_api.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/auth/session.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:fl_clash/xboard/core/net/api_client.dart';
import 'package:fl_clash/xboard/core/net/api_exception.dart';
import 'package:fl_clash/xboard/core/net/bootstrap.dart';
import 'package:fl_clash/xboard/core/net/endpoint_pool.dart';
import 'package:fl_clash/xboard/core/net/transport.dart';
import 'package:fl_clash/xboard/core/runtime.dart';
import 'package:fl_clash/xboard/core/sync/subscription_sync.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

class _AccountFailure implements Exception {
  const _AccountFailure(this.code);
  final String code;
  @override
  String toString() => 'AccountInstanceFailure($code)';
}

void _require(bool condition, String code) {
  if (!condition) throw _AccountFailure(code);
}

void _event(String name, [Map<String, Object?> fields = const {}]) =>
    stdout.writeln(jsonEncode({'event': name, ...fields}));

Future<void> _until(bool Function() ready, String code) async {
  final deadline = DateTime.now().add(const Duration(seconds: 35));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) throw _AccountFailure(code);
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}

bool _loopback(String host) =>
    host == 'localhost' ||
    (InternetAddress.tryParse(host)?.isLoopback ?? false);

BrandConfig _brand(Map<String, dynamic> config) {
  final endpoint = config['endpoint'];
  _require(endpoint is String, 'missing_loopback_endpoint');
  final uri = Uri.tryParse(endpoint as String);
  _require(
    uri != null &&
        uri.scheme == 'https' &&
        _loopback(uri.host) &&
        uri.userInfo.isEmpty &&
        !uri.hasQuery &&
        !uri.hasFragment,
    'loopback_https_required',
  );
  Map<String, String> keys(Object? value) =>
      value is Map ? value.map((key, value) => MapEntry('$key', '$value')) : {};
  return BrandConfig(
    brandId: config['brand'] as String,
    displayName: 'Account acceptance fixture',
    builtinApiEndpoints: [ApiEndpointSpec(endpoint)],
    ctrlPubKeys: keys(config['ctrl_pub_keys']),
    envPubKeys: keys(config['env_pub_keys']),
    obfKey: config['obf_key'] is String ? config['obf_key'] as String : '',
  );
}

class _AccountSink implements ManagedProfileSink {
  int applied = 0;
  int nodes = 0;
  int entries = 0;
  @override
  Future<void> apply(
    Uint8List bytes, {
    required String label,
    String? subscriptionUserinfo,
  }) async {
    final document = loadYaml(utf8.decode(bytes));
    _require(document is Map, 'subscription_not_map');
    final proxies = (document as Map)['proxies'];
    _require(
      proxies is List && proxies.isNotEmpty,
      'subscription_without_nodes',
    );
    entries = (proxies as List).length;
    nodes = proxies.where((entry) {
      if (entry is! Map) return false;
      final name = entry['name'];
      return name is String && name.contains('JP Account ');
    }).length;
    applied++;
  }

  @override
  Future<void> remove() async => nodes = 0;
}

class _AccountTransport implements HttpTransport {
  _AccountTransport(this.inner);
  final HttpTransport inner;
  @override
  Future<TransportResponse> send(TransportRequest request) async {
    final response = await inner.send(request);
    if (response.statusCode >= 400) {
      Object? body;
      try {
        body = jsonDecode(utf8.decode(response.body));
      } on FormatException {
        body = null;
      }
      _event('ACCOUNT_HTTP_REFUSAL', {
        'path': request.uri.path,
        'status': response.statusCode,
        'shape': body is Map
            ? {
                for (final entry in body.entries)
                  '${entry.key}': entry.value.runtimeType.toString(),
              }
            : body.runtimeType.toString(),
      });
    }
    return response;
  }

  @override
  void close() => inner.close();
}

const _client = ClientInfo(
  platform: XcPlatform.windows,
  arch: 'x64',
  appVersion: '1.0.0',
  build: '1',
  osVersion: '10.0',
  deviceName: 'Isolated account acceptance',
);

Future<void> _runAccountProbe(
  String configPath,
  String fixturePath,
  String certificatePath,
) async {
  var stage = 'config';
  XClientRuntime? runtime;
  final extraSessions = <Session>[];
  final extraTransports = <HttpTransport>[];
  final sink = _AccountSink();
  final previousLog = xcLogSink;
  var warnings = 0;
  xcLogSink = (_, {required warn}) {
    if (warn) warnings++;
  };
  try {
    final config = jsonDecode(await File(configPath).readAsString());
    final fixture = jsonDecode(await File(fixturePath).readAsString());
    _require(config is Map<String, dynamic>, 'bad_test_config');
    _require(
      fixture is Map<String, dynamic> &&
          fixture['owned_account_fixture'] == true &&
          fixture['user_id'] is int &&
          fixture['plan_ids'] is List &&
          (fixture['plan_ids'] as List).length == 3,
      'account_fixture_not_owned',
    );
    final data = fixture as Map<String, dynamic>;
    final email = data['email'] as String;
    final password = data['password'] as String;
    final newPassword = data['new_password'] as String;
    final plans = (data['plan_ids'] as List).cast<int>();
    final expectedNodes = (data['expected_nodes'] as List).cast<int>();
    final brand = _brand(config as Map<String, dynamic>);
    SecurityContext.defaultContext.setTrustedCertificates(certificatePath);
    final client = XClientRuntime(
      brand: brand,
      client: _client,
      store: MemorySecureStore(),
      cache: MemoryBootstrapCache(),
      sink: sink,
      transportFactory: ({pins, onPinReport}) => _AccountTransport(
        IoHttpTransport(pins: pins, onPinReport: onPinReport),
      ),
    );
    runtime = client;
    client.setForeground(false);
    await client.start();
    _require(client.pool.hosts.every(_loopback), 'non_loopback_discovery');
    stage = 'login_and_subscription';
    await client.login(email, password);
    _require(client.session.state.isLoggedIn, 'login_failed');
    _require(client.session.state.deviceRegistered, 'device_not_registered');
    await _until(() => sink.applied > 0, 'initial_subscription_timeout');
    _event('INITIAL_SUBSCRIPTION_OBSERVED', {
      'nodes': sink.nodes,
      'all_entries': sink.entries,
      'phase': client.sync.status.phase.name,
      'expected_nodes': expectedNodes[0],
    });
    _require(
      client.sync.status.phase == SyncPhase.ok &&
          sink.nodes == expectedNodes[0],
      'initial_subscription_mismatch',
    );
    final api = client.xboard;
    _event('ACCOUNT_LOGIN_VERIFIED', {'registered': true, 'nodes': sink.nodes});

    Future<({Session session, XboardApi api})> secondary() async {
      final transport = _AccountTransport(IoHttpTransport());
      extraTransports.add(transport);
      final secondaryClient = ApiClient(
        transport: transport,
        pool: EndpointPool(endpoints: brand.builtinApiEndpoints),
        userAgent: client.userAgent,
      );
      final session = Session(
        api: secondaryClient,
        store: MemorySecureStore(),
        client: _client,
      );
      extraSessions.add(session);
      await session.login(email, password);
      _require(session.state.isLoggedIn, 'secondary_login_failed');
      return (session: session, api: XboardApi(secondaryClient));
    }

    stage = 'user_info';
    final user = await api.userInfo();
    stage = 'subscribe_summary';
    final summary = await api.subscribeSummary();
    stage = 'comm_config';
    final common = await api.commConfig();
    stage = 'guest_config';
    final guest = await api.guestConfig();
    stage = 'account_stat';
    final stat = await api.stat();
    stage = 'plan_list';
    final planList = await api.plans();
    stage = 'plan_detail';
    final plan = await api.plan(plans[1]);
    _require(user['plan_id'] == plans[0], 'user_plan_missing');
    _require(summary['plan_id'] == plans[0], 'summary_plan_missing');
    _require(
      !summary.containsKey('token') && !summary.containsKey('subscribe_url'),
      'summary_secret_exposed',
    );
    _require(
      common['currency'] is String && common['currency_symbol'] is String,
      'currency_config_missing',
    );
    _require(
      guest.isNotEmpty && stat.length == 3,
      'account_config_or_stat_shape',
    );
    _require(stat[1] >= 1 && stat[2] >= 1, 'seeded_account_stat_missing');
    _require(
      plans.every((id) => planList.any((entry) => entry['id'] == id)) &&
          plan['id'] == plans[1] &&
          plan[PlanPeriod.month] == 500 &&
          planList.any(
            (entry) => entry['id'] == plans[2] && entry[PlanPeriod.month] == 0,
          ),
      'plan_api_mismatch',
    );
    final methods = await api.paymentMethods();
    _event('ACCOUNT_READ_VERIFIED', {
      'summary_secrets_redacted': true,
      'stat_fields': stat.length,
      'fixture_plans': plans.length,
      'payment_methods_queried': methods.length,
      'external_payment_started': false,
    });

    stage = 'content';
    final notices = await api.notices();
    final knowledge = await api.knowledge(keyword: 'XClient account');
    final article = await api.knowledgeArticle(data['knowledge_id'] as int);
    _require(
      notices.items.any((notice) => notice['id'] == data['notice_id']),
      'notice_not_returned',
    );
    _require(
      knowledge.values
          .expand((items) => items)
          .any((entry) => entry['id'] == data['knowledge_id']),
      'knowledge_not_returned',
    );
    _require(
      article['body'] is String &&
          (article['body'] as String).contains(XboardApi.redactedText),
      'article_private_link_not_redacted',
    );
    _event('CONTENT_VERIFIED', {
      'notice': true,
      'knowledge': true,
      'redacted': true,
    });

    stage = 'invite_commission';
    await api.createInviteCode();
    final invites = await api.invites();
    final details = await api.inviteDetails();
    _require(
      invites['codes'] is List && (invites['codes'] as List).isNotEmpty,
      'invite_code_missing',
    );
    _require(
      invites['stat'] is List && (invites['stat'] as List).length == 5,
      'invite_stat_shape',
    );
    _require(
      details.total >= 1 && details.items.isNotEmpty,
      'commission_log_missing',
    );
    final balanceBefore = (await api.userInfo())['balance'] as num;
    await api.transferCommission(200);
    final afterTransfer = await api.userInfo();
    _require(
      (afterTransfer['balance'] as num) == balanceBefore + 200,
      'commission_transfer_balance',
    );
    _require(
      afterTransfer['commission_balance'] ==
          (data['initial_commission'] as int) - 200,
      'commission_transfer_debit',
    );
    _event('INVITE_COMMISSION_VERIFIED', {
      'details': details.total,
      'transfer_cents': 200,
    });

    stage = 'traffic_history';
    final traffic = await api.trafficLog();
    final cycles = await api.trafficCycle();
    final logins = await api.loginLog();
    _require(traffic.isNotEmpty, 'traffic_log_missing');
    _require(
      cycles == null ||
          (cycles['current'] is Map &&
              cycles['history'] is List &&
              (cycles['history'] as List).isNotEmpty &&
              (cycles['history_total'] as num) >= 1),
      'cycle_current_or_history_missing',
    );
    _require(
      logins == null || (logins.total >= 1 && logins.items.isNotEmpty),
      'login_log_missing',
    );
    _event('HISTORY_VERIFIED', {
      'traffic_records': traffic.length,
      'cycle_supported': cycles != null,
      'login_log_supported': logins != null,
      'unsupported_404_hidden': cycles == null || logins == null,
    });

    stage = 'tickets';
    var existingOpenRefused = false;
    try {
      await api.createTicket(
        subject: 'XClient duplicate open ticket',
        level: 1,
        message: 'Synthetic guard request',
      );
    } on XbApiException catch (error) {
      existingOpenRefused = error.status == 400;
    }
    _require(existingOpenRefused, 'open_ticket_limit_not_enforced');
    for (final existing in await api.tickets()) {
      if (existing['status'] == 0) await api.closeTicket(existing['id'] as int);
    }
    await api.createTicket(
      subject: 'XClient live account ticket',
      level: 1,
      message: 'Synthetic request',
    );
    final tickets = await api.tickets();
    final ticket = tickets.firstWhere(
      (entry) => entry['subject'] == 'XClient live account ticket',
    );
    final ticketId = ticket['id'] as int;
    await api.replyTicket(ticketId, 'Synthetic follow-up');
    final replied = await api.ticket(ticketId);
    _require(
      replied['message'] is List && (replied['message'] as List).length >= 2,
      'ticket_reply_not_persisted',
    );
    await api.closeTicket(ticketId);
    _require((await api.ticket(ticketId))['status'] == 1, 'ticket_not_closed');
    _event('TICKET_LIFECYCLE_VERIFIED', {
      'created': true,
      'replied': true,
      'closed': true,
    });

    stage = 'sessions_devices';
    final beforeSessions = (await api.activeSessions())
        .map((entry) => entry['id'])
        .toSet();
    final second = await secondary();
    final sessions = await api.activeSessions();
    final added = sessions
        .where((entry) => !beforeSessions.contains(entry['id']))
        .toList();
    _require(added.length == 1, 'secondary_session_not_identified');
    final devices = await api.devices();
    _require(devices.length >= 2, 'secondary_device_missing');
    final deviceId = second.session.state.device?['device_id'];
    _require(deviceId is String, 'secondary_device_id_missing');
    await api.removeActiveSession(added.single['id'] as int);
    var sessionRevoked = false;
    try {
      await second.api.userInfo();
    } on XbApiException catch (error) {
      sessionRevoked = error.endsSession;
    }
    _require(sessionRevoked, 'removed_session_still_authorized');
    await api.revokeDevice(deviceId as String);
    _require(
      !(await api.devices()).any((entry) => entry['device_id'] == deviceId),
      'device_still_active',
    );
    _event('SESSION_DEVICE_VERIFIED', {
      'session_revoked': true,
      'device_revoked': true,
    });

    stage = 'cancel_order';
    final priorBalance = (await api.userInfo())['balance'];
    final cancelled = await api.saveOrder(
      planId: plans[1],
      period: PlanPeriod.month,
    );
    final pending = await api.orderDetail(cancelled);
    _require(
      await api.checkOrder(cancelled) == OrderStatus.pending,
      'order_not_pending',
    );
    _require(
      pending['balance_amount'] == 500 && pending['total_amount'] == 0,
      'balance_not_reserved',
    );
    await api.cancelOrder(cancelled);
    _require(
      await api.checkOrder(cancelled) == OrderStatus.cancelled,
      'order_not_cancelled',
    );
    _require(
      (await api.userInfo())['balance'] == priorBalance,
      'cancel_did_not_refund_balance',
    );
    _event('ORDER_CANCEL_VERIFIED', {
      'pending': true,
      'cancelled': true,
      'balance_refunded': true,
    });

    Future<void> buy(int planId, int nodes, String kind) async {
      final trade = await api.saveOrder(
        planId: planId,
        period: PlanPeriod.month,
      );
      final detail = await api.orderDetail(trade);
      _require(detail['total_amount'] == 0, 'external_payment_forbidden');
      final checkout = await api.checkout(tradeNo: trade);
      _require(checkout.type == -1, 'local_checkout_shape');
      var status = await api.checkOrder(trade);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (status == OrderStatus.pending ||
          status == OrderStatus.processing) {
        if (DateTime.now().isAfter(deadline)) {
          throw const _AccountFailure('order_completion_timeout');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
        status = await api.checkOrder(trade);
      }
      _require(status == OrderStatus.completed, 'order_not_completed');
      final previousApply = sink.applied;
      await client.session.refreshUser();
      _require(
        client.session.state.user?['plan_id'] == planId,
        'completed_plan_not_refreshed',
      );
      await client.sync.syncNow();
      if (sink.applied <= previousApply) {
        client.sync.requestSync(delay: Duration.zero);
      }
      await _until(
        () => sink.applied > previousApply,
        'completed_subscription_refresh_timeout',
      );
      _require(
        client.sync.status.phase == SyncPhase.ok &&
            sink.nodes == nodes &&
            client.sync.status.usage?.total == nodes * 10 * 1024 * 1024 * 1024,
        'completed_nodes_not_refreshed',
      );
      final finalDetail = await api.orderDetail(trade);
      _require(
        finalDetail['status'] == OrderStatus.completed,
        'completed_order_detail_mismatch',
      );
      _event('ORDER_COMPLETED_REFRESH_VERIFIED', {
        'kind': kind,
        'checkout_type': checkout.type,
        'status': status,
        'nodes': nodes,
      });
    }

    stage = 'balance_order';
    await buy(plans[1], expectedNodes[1], 'balance');
    stage = 'free_order';
    await buy(plans[2], expectedNodes[2], 'free');
    _require((await api.orders()).length >= 3, 'order_history_missing');

    stage = 'notification_password';
    await api.updateRemind(expire: false, traffic: true);
    final reminded = await api.userInfo();
    _require(
      reminded['remind_expire'] == false && reminded['remind_traffic'] == true,
      'notification_preferences_not_saved',
    );
    final other = await secondary();
    await api.changePassword(password, newPassword);
    var passwordRevoked = false;
    try {
      await other.api.userInfo();
    } on XbApiException catch (error) {
      passwordRevoked = error.endsSession;
    }
    _require(passwordRevoked, 'password_change_did_not_revoke_other_session');
    _require(
      (await api.userInfo())['plan_id'] == plans[2],
      'password_change_revoked_current_session',
    );
    await client.logout();
    var oldPasswordRefused = false;
    try {
      await client.login(email, password);
    } on XbApiException {
      oldPasswordRefused = !client.session.state.isLoggedIn;
    }
    _require(oldPasswordRefused, 'old_password_still_accepted');
    await client.login(email, newPassword);
    _require(client.session.state.isLoggedIn, 'new_password_login_failed');
    await client.logout();
    _event('SECURITY_SETTINGS_VERIFIED', {
      'notification_saved': true,
      'other_session_revoked': true,
      'current_session_kept': true,
      'old_password_refused': true,
      'new_password_login': true,
    });
    _event('ACCOUNT_PROBE_COMPLETE', {
      'passed': true,
      'subscription_applications': sink.applied,
      'external_payments': 0,
      'sanitized_warnings': warnings,
    });
  } catch (error) {
    final code = error is _AccountFailure
        ? error.code
        : error is XbApiException
        ? error.kind.name
        : error.runtimeType.toString();
    _event('ACCOUNT_PROBE_FAILED', {
      'stage': stage,
      'code': code,
      if (error is XbApiException) 'http_status': error.status,
    });
    throw _AccountFailure('$stage:$code');
  } finally {
    for (final session in extraSessions) {
      if (session.state.isLoggedIn) {
        try {
          await session.logout();
        } on Object {
          _event('ACCOUNT_CLEANUP_WARNING');
        }
      }
      session.dispose();
    }
    for (final transport in extraTransports) {
      transport.close();
    }
    if (runtime != null) {
      try {
        await runtime.logout();
      } on Object {
        _event('ACCOUNT_CLEANUP_WARNING');
      }
      runtime.dispose();
    }
    xcLogSink = previousLog;
  }
}

void main() {
  final config = Platform.environment['XCLIENT_TEST_CONFIG'] ?? '';
  final certificate = Platform.environment['XCLIENT_TEST_CERT'] ?? '';
  final fixture = Platform.environment['XCLIENT_ACCOUNT_FIXTURE'] ?? '';
  test(
    'real isolated account, balance and free-order entitlement lifecycle',
    () => _runAccountProbe(config, fixture, certificate),
    skip: config.isEmpty || certificate.isEmpty || fixture.isEmpty,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
