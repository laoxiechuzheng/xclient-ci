import 'dart:convert';
import 'dart:typed_data';

import 'api_exception.dart';
import 'endpoint_pool.dart';
import 'transport.dart';

/// `X-XClient-Seq: b=<boot_seq>;p=<policy_seq>` (DESIGN §1, §6).
class XClientSeq {
  final int? boot;
  final int? policy;

  const XClientSeq({this.boot, this.policy});

  static XClientSeq? parse(String? header) {
    if (header == null || header.isEmpty) return null;
    int? boot;
    int? policy;
    for (final part in header.split(';')) {
      final eq = part.indexOf('=');
      if (eq == -1) continue;
      final key = part.substring(0, eq).trim().toLowerCase();
      final value = int.tryParse(part.substring(eq + 1).trim());
      if (key == 'b') boot = value;
      if (key == 'p') policy = value;
    }
    if (boot == null && policy == null) return null;
    return XClientSeq(boot: boot, policy: policy);
  }

  @override
  String toString() => 'XClientSeq(b=$boot;p=$policy)';
}

class ApiResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Uint8List body;
  final String endpoint;
  final int? authorizationGeneration;

  const ApiResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.endpoint,
    this.authorizationGeneration,
  });

  String? header(String name) => headers[name.toLowerCase()];

  /// The decoded JSON body, or null when the body is empty or not JSON.
  Object? get json {
    if (body.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(body));
    } on FormatException {
      return null;
    }
  }
}

/// Response body shapes.
enum ApiShape {
  /// Xboard's `{status, message, data, error}`; yields `data`.
  standard,

  /// The plugin's `{ok, data}` / `{ok:false, error, message}`; yields `data`.
  plugin,

  /// A top-level object that is the result itself (`order/checkout`,
  /// `notice/fetch`, `invite/details`, `loginLog/fetch`, …).
  raw,
}

typedef SeqListener = void Function(XClientSeq seq);
typedef ApiErrorListener = void Function(XbApiException error);

/// HTTPS client of the panel: one endpoint pool, the brand User-Agent, the
/// session's Authorization and device headers, typed errors.
class ApiClient {
  final HttpTransport transport;
  final EndpointPool pool;
  String userAgent;
  String language;

  /// `Bearer …` as Xboard's login returns it, or null when logged out.
  String? _authorization;
  int _authorizationGeneration = 0;
  String? get authorization => _authorization;
  int get authorizationGeneration => _authorizationGeneration;
  set authorization(String? value) {
    _authorization = value;
    _authorizationGeneration++;
  }

  String? deviceId;

  final _seqListeners = <SeqListener>[];
  final _errorListeners = <ApiErrorListener>[];
  final DateTime Function() _now;

  ApiClient({
    required this.transport,
    required this.pool,
    required this.userAgent,
    this.language = 'zh-CN',
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  void addSeqListener(SeqListener listener) => _seqListeners.add(listener);

  void removeSeqListener(SeqListener listener) =>
      _seqListeners.remove(listener);

  /// Sees errors from the current authorization epoch; the session handles
  /// `unauthorized` and `deviceRevoked`.
  void addErrorListener(ApiErrorListener listener) =>
      _errorListeners.add(listener);

  void removeErrorListener(ApiErrorListener listener) =>
      _errorListeners.remove(listener);

  Map<String, String> _headers({
    required bool auth,
    required bool device,
    Map<String, String>? extra,
    String? contentType,
  }) {
    return {
      'user-agent': userAgent,
      'accept': 'application/json',
      'content-language': language,
      'content-type': ?contentType,
      'authorization': ?(auth ? authorization : null),
      'x-xclient-device': ?(device ? deviceId : null),
      ...?extra,
    };
  }

  static String formEncode(Map<String, Object?> fields) {
    String text(Object value) => switch (value) {
      true => '1',
      false => '0',
      _ => '$value',
    };
    return [
      for (final MapEntry(:key, :value) in fields.entries)
        if (value != null)
          [key, text(value)].map(Uri.encodeQueryComponent).join('='),
    ].join('&');
  }

  /// Sends one request, trying the next endpoint when the current one gives
  /// no answer or a 5xx. Requests that may have reached the server are only
  /// tried again when [idempotent].
  Future<ApiResponse> send(
    String method,
    String path, {
    Map<String, Object?>? query,
    Map<String, Object?>? json,
    Map<String, Object?>? form,
    bool auth = true,
    bool device = false,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
    bool? idempotent,
    int maxAttempts = 3,
  }) async {
    final authorizationGeneration = _authorizationGeneration;
    final attempts = pool.attemptOrder();
    if (attempts.isEmpty) {
      throw const XbApiException(XbErrorKind.network, message: 'no endpoint');
    }
    final retrySent = idempotent ?? (method == 'GET' || method == 'HEAD');
    List<int>? body;
    String? contentType;
    if (json != null) {
      body = utf8.encode(jsonEncode(json));
      contentType = 'application/json';
    } else if (form != null) {
      body = utf8.encode(formEncode(form));
      contentType = 'application/x-www-form-urlencoded';
    }
    final requestHeaders = _headers(
      auth: auth,
      device: device,
      extra: headers,
      contentType: contentType,
    );
    XbApiException? last;
    final limit = attempts.length < maxAttempts ? attempts.length : maxAttempts;
    for (var i = 0; i < limit; i++) {
      final endpoint = attempts[i];
      final uri = _uri(endpoint.url, path, query);
      final started = _now();
      try {
        final response = await transport.send(
          TransportRequest(
            method: method,
            uri: uri,
            headers: requestHeaders,
            body: body,
            timeout: timeout,
          ),
        );
        final result = ApiResponse(
          statusCode: response.statusCode,
          headers: response.headers,
          body: response.body,
          endpoint: endpoint.url,
          authorizationGeneration: authorizationGeneration,
        );
        _notifySeq(result);
        if (response.statusCode >= 500) {
          pool.reportFailure(endpoint.url);
          last = _errorFor(result);
          if (retrySent) continue;
          break;
        }
        pool.reportSuccess(endpoint.url, _now().difference(started));
        return result;
      } on TransportException catch (e) {
        pool.reportFailure(endpoint.url);
        last = _transportError(e);
        if (e.beforeSend || retrySent) continue;
        break;
      }
    }
    final error = last!;
    _notifyError(error, generation: authorizationGeneration);
    throw error;
  }

  Uri _uri(String base, String path, Map<String, Object?>? query) {
    final clean = path.startsWith('/') ? path : '/$path';
    final uri = Uri.parse('$base$clean');
    if (query == null || query.isEmpty) return uri;
    return uri.replace(
      queryParameters: {
        for (final MapEntry(:key, :value) in query.entries)
          if (value != null) key: '$value',
      },
    );
  }

  /// [send] then unwraps the body by [shape], mapping refusals to
  /// [XbApiException]. 304 yields null.
  Future<Object?> call(
    String method,
    String path, {
    ApiShape shape = ApiShape.standard,
    Map<String, Object?>? query,
    Map<String, Object?>? json,
    Map<String, Object?>? form,
    bool auth = true,
    bool device = false,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
    bool? idempotent,
  }) async {
    final response = await send(
      method,
      path,
      query: query,
      json: json,
      form: form,
      auth: auth,
      device: device,
      headers: headers,
      timeout: timeout,
      idempotent: idempotent,
    );
    return unwrap(response, shape);
  }

  Object? unwrap(ApiResponse response, ApiShape shape) {
    if (response.statusCode == 304) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final error = _errorFor(response);
      _notifyError(error, generation: response.authorizationGeneration);
      throw error;
    }
    final body = response.json;
    switch (shape) {
      case ApiShape.raw:
        if (body == null) {
          throw const XbApiException(
            XbErrorKind.badResponse,
            message: 'not json',
          );
        }
        return body;
      case ApiShape.standard:
        if (body is Map && body.containsKey('data')) {
          if (body['status'] == 'fail') {
            throw _errorFor(response);
          }
          return body['data'];
        }
        throw const XbApiException(XbErrorKind.badResponse);
      case ApiShape.plugin:
        if (body is Map && body['ok'] == true) return body['data'];
        if (body is Map && body['ok'] == false) throw _errorFor(response);
        throw const XbApiException(XbErrorKind.badResponse);
    }
  }

  void _notifySeq(ApiResponse response) {
    final seq = XClientSeq.parse(response.header('x-xclient-seq'));
    if (seq == null) return;
    for (final listener in List.of(_seqListeners)) {
      listener(seq);
    }
  }

  void _notifyError(XbApiException error, {int? generation}) {
    if (generation != null && generation != _authorizationGeneration) return;
    for (final listener in List.of(_errorListeners)) {
      listener(error);
    }
  }

  static XbApiException _transportError(TransportException e) {
    return XbApiException(switch (e.kind) {
      TransportFailure.tls => XbErrorKind.tls,
      TransportFailure.pin => XbErrorKind.pinMismatch,
      TransportFailure.insecure => XbErrorKind.badResponse,
      _ => XbErrorKind.network,
    }, message: e.kind.name);
  }

  static const _notLoggedInMarkers = [
    '未登录',
    '登陆已过期',
    '登录已过期',
    'not logged in',
    'login has expired',
    'unauthenticated',
  ];

  /// Maps an HTTP refusal: plugin `{ok:false,error,message}`, Xboard
  /// `{status:'fail',message}`, Laravel 422 `{message, errors}`, or a bare
  /// `{message}`.
  static XbApiException errorFor(ApiResponse response) => _errorFor(response);

  static XbApiException _errorFor(ApiResponse response) {
    final status = response.statusCode;
    final body = response.json;
    String? code;
    var message = '';
    var errors = const <String, List<String>>{};
    if (body is Map) {
      if (body['error'] is String) code = body['error'] as String;
      final rawMessage = body['message'];
      if (rawMessage is String) {
        message = rawMessage;
      } else if (rawMessage is List && rawMessage.isNotEmpty) {
        message = '${rawMessage.last}';
      }
      final rawErrors = body['errors'];
      if (rawErrors is Map) {
        errors = {
          for (final MapEntry(:key, :value) in rawErrors.entries)
            '$key': [
              if (value is List)
                for (final item in value) '$item'
              else
                '$value',
            ],
        };
      }
    }
    final lower = message.toLowerCase();
    final notLoggedIn = _notLoggedInMarkers.any(lower.contains);
    final kind = switch (status) {
      401 => XbErrorKind.unauthorized,
      403 when code == 'device_revoked' => XbErrorKind.deviceRevoked,
      403 when code == 'device_limit' => XbErrorKind.deviceLimit,
      403 when notLoggedIn => XbErrorKind.unauthorized,
      404 => XbErrorKind.notFound,
      409 when code == 'replay' => XbErrorKind.replay,
      409 => XbErrorKind.deviceUnknown,
      422 => XbErrorKind.validation,
      429 => XbErrorKind.rateLimited,
      >= 500 => XbErrorKind.server,
      _ => XbErrorKind.failed,
    };
    final retryAfter = int.tryParse(response.header('retry-after') ?? '');
    return XbApiException(
      kind,
      status: status,
      code: code,
      message: message,
      errors: errors,
      retryAfter: retryAfter == null ? null : Duration(seconds: retryAfter),
    );
  }
}
