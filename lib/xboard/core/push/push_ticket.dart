import '../net/api_client.dart';
import '../net/endpoint_pool.dart';
import '../crypto/b64u.dart';
import '../net/transport.dart';
import 'push_connection.dart';

export 'push_connection.dart' show PushException;

class PushTicket {
  const PushTicket({required this.uri, required this.value});

  final Uri uri;
  final String value;
}

abstract class PushTicketIssuer {
  Future<PushTicket> issue();
  void cancel();
}

bool _validTicket(Object? value) {
  if (value is! String || !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) {
    return false;
  }
  try {
    final bytes = b64uDecode(value);
    return bytes.length == 32 && b64uEncode(bytes) == value;
  } on FormatException {
    return false;
  }
}

class ApiPushTicketIssuer implements PushTicketIssuer {
  ApiPushTicketIssuer({required this.api, required this.transportFactory});

  final ApiClient api;
  final HttpTransport Function() transportFactory;
  final Set<HttpTransport> _active = {};
  int _generation = 0;

  @override
  Future<PushTicket> issue() async {
    final generation = _generation;
    final authEpoch = api.authorizationGeneration;
    final auth = api.authorization;
    final device = api.deviceId;
    if (auth == null || device == null) throw const PushException('no_session');
    bool current() =>
        generation == _generation &&
        authEpoch == api.authorizationGeneration &&
        auth == api.authorization &&
        device == api.deviceId;
    final transport = transportFactory();
    _active.add(transport);
    final ticketApi =
        ApiClient(
            transport: transport,
            pool: EndpointPool(
              endpoints: [
                for (final endpoint in api.pool.attemptOrder()) endpoint.spec,
              ],
            ),
            userAgent: api.userAgent,
            language: api.language,
          )
          ..authorization = auth
          ..deviceId = device;
    try {
      final response = await ticketApi.send(
        'POST',
        '/api/v1/xclient/push/ticket',
        device: true,
        json: const {},
        timeout: const Duration(seconds: 15),
      );
      if (!current()) throw const PushException('cancelled');
      final data = api.unwrap(
        ApiResponse(
          statusCode: response.statusCode,
          headers: response.headers,
          body: response.body,
          endpoint: response.endpoint,
          authorizationGeneration: authEpoch,
        ),
        ApiShape.plugin,
      );
      if (data is! Map ||
          !_validTicket(data['ticket']) ||
          data['path'] != '/api/v1/xclient/events' ||
          data['expires_in'] is! int ||
          (data['expires_in'] as int) <= 0 ||
          (data['expires_in'] as int) > 60) {
        throw const PushException('bad_ticket');
      }
      final endpoint = Uri.tryParse(response.endpoint);
      if (endpoint == null ||
          endpoint.scheme != 'https' ||
          endpoint.host.isEmpty ||
          endpoint.userInfo.isNotEmpty ||
          endpoint.hasQuery ||
          endpoint.hasFragment) {
        throw const PushException('bad_endpoint');
      }
      return PushTicket(
        uri: Uri.parse('${response.endpoint}${data['path']}'),
        value: data['ticket'] as String,
      );
    } finally {
      _active.remove(transport);
      transport.close();
    }
  }

  @override
  void cancel() {
    _generation++;
    for (final transport in _active.toList()) {
      transport.close();
    }
    _active.clear();
  }
}
