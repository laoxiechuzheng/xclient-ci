import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'spki.dart';
import 'strict_http_client.dart';
import 'direct_socket_connector.dart';

export 'strict_http_client.dart' show PinReport;

enum TransportFailure { insecure, connect, tls, pin, timeout, io, tooLarge }

/// Only [beforeSend] failures permit replaying non-idempotent requests.
class TransportException implements Exception {
  final TransportFailure kind;
  final bool beforeSend;
  final String message;

  const TransportException(
    this.kind, {
    this.beforeSend = false,
    this.message = '',
  });

  @override
  String toString() => 'TransportException(${kind.name}, $message)';
}

class TransportRequest {
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
  final Duration timeout;

  const TransportRequest({
    required this.method,
    required this.uri,
    this.headers = const {},
    this.body,
    this.timeout = const Duration(seconds: 20),
  });
}

class TransportResponse {
  final int statusCode;

  /// Lower-cased names; repeated headers joined with `,`.
  final Map<String, String> headers;
  final Uint8List body;

  const TransportResponse({
    required this.statusCode,
    this.headers = const {},
    required this.body,
  });

  String? header(String name) => headers[name.toLowerCase()];
}

abstract class HttpTransport {
  Future<TransportResponse> send(TransportRequest request);

  void close();
}

/// Plain overrides bypass FlClash's global proxy/certificate overrides.
class IoHttpTransport implements HttpTransport {
  final PinPolicy Function() _pins;
  final PinReport? _onPinReport;
  final Duration connectTimeout;
  final int maxBodyBytes;
  final DirectSocketConnector? connector;

  HttpClient? _plain;
  HttpClient? _pinned;
  bool _closed = false;
  String? _pinIdentity;
  int _pinEpoch = 0;
  int? _directGeneration;

  IoHttpTransport({
    PinPolicy Function()? pins,
    PinReport? onPinReport,
    this.connectTimeout = const Duration(seconds: 8),
    this.maxBodyBytes = 32 * 1024 * 1024,
    this.connector,
  }) : _pins = pins ?? (() => const PinPolicy()),
       _onPinReport = onPinReport;

  StrictHttpClientFactory get _factory => StrictHttpClientFactory(
    pins: _pins,
    onPinReport: _onPinReport,
    connectTimeout: connectTimeout,
    connector: connector,
  );

  HttpClient createClient({bool pin = true}) => _factory.create(pin: pin);

  HttpClient get _plainClient => _plain ??= createClient(pin: false);

  HttpClient get _pinnedClient => _pinned ??= createClient();

  PinPolicy _syncPinPolicy() {
    final policy = _pins();
    final hosts =
        policy.hosts.keys
            .where((host) => policy.hosts[host]!.mode != PinMode.off)
            .toList()
          ..sort();
    final identity = jsonEncode([
      for (final host in hosts)
        [
          host,
          policy.hosts[host]!.mode.name,
          policy.hosts[host]!.spki.toList()..sort(),
        ],
    ]);
    if (_pinIdentity != identity ||
        _directGeneration != connector?.generation) {
      _pinIdentity = identity;
      _directGeneration = connector?.generation;
      _pinEpoch++;
      _resetClients();
    }
    return policy;
  }

  void _resetClients() {
    _plain?.close(force: true);
    _pinned?.close(force: true);
    _plain = null;
    _pinned = null;
  }

  @override
  Future<TransportResponse> send(TransportRequest request) async {
    if (_closed) {
      throw const TransportException(TransportFailure.io, beforeSend: true);
    }
    final uri = request.uri;
    if (uri.scheme != 'https' || uri.host.isEmpty) {
      throw const TransportException(
        TransportFailure.insecure,
        beforeSend: true,
      );
    }
    final policy = _syncPinPolicy();
    final pinEpoch = _pinEpoch;
    final directGeneration = connector?.generation;
    final client = policy.forHost(uri.host) == null
        ? _plainClient
        : _pinnedClient;
    // ignore: close_sinks
    HttpClientRequest? httpRequest;
    var sent = false;
    var cancelled = false;
    Future<TransportResponse> run() async {
      httpRequest = await client.openUrl(request.method, uri);
      final req = httpRequest!;
      if (cancelled || _closed) {
        req.abort();
        throw TransportException(
          cancelled ? TransportFailure.timeout : TransportFailure.io,
          beforeSend: true,
        );
      }
      if (directGeneration != connector?.generation) {
        req.abort();
        throw const TransportException(
          TransportFailure.connect,
          beforeSend: true,
        );
      }
      _syncPinPolicy();
      if (pinEpoch != _pinEpoch) {
        req.abort();
        throw const TransportException(TransportFailure.pin, beforeSend: true);
      }
      req.followRedirects = false;
      req.persistentConnection = true;
      request.headers.forEach(req.headers.set);
      final body = request.body;
      if (body != null) {
        req.contentLength = body.length;
        req.add(body);
      }
      sent = true;
      final response = await req.close();
      final headers = <String, String>{};
      response.headers.forEach((name, values) {
        headers[name.toLowerCase()] = values.join(',');
      });
      final builder = BytesBuilder(copy: false);
      await for (final chunk in response) {
        builder.add(chunk);
        if (builder.length > maxBodyBytes) {
          throw const TransportException(TransportFailure.tooLarge);
        }
      }
      return TransportResponse(
        statusCode: response.statusCode,
        headers: headers,
        body: builder.takeBytes(),
      );
    }

    try {
      return await run().timeout(request.timeout);
    } on TimeoutException {
      cancelled = true;
      httpRequest?.abort();
      throw TransportException(TransportFailure.timeout, beforeSend: !sent);
    } on StrictPinMismatch {
      throw const TransportException(TransportFailure.pin, beforeSend: true);
    } on HandshakeException catch (e) {
      throw TransportException(
        TransportFailure.tls,
        beforeSend: !sent,
        message: e.message,
      );
    } on TlsException catch (e) {
      throw TransportException(
        TransportFailure.tls,
        beforeSend: !sent,
        message: e.message,
      );
    } on SocketException catch (e) {
      throw TransportException(
        sent ? TransportFailure.io : TransportFailure.connect,
        beforeSend: !sent,
        message: e.message,
      );
    } on HttpException catch (e) {
      throw TransportException(
        TransportFailure.io,
        beforeSend: !sent,
        message: e.message,
      );
    }
  }

  @override
  void close() {
    _closed = true;
    _resetClients();
  }
}
