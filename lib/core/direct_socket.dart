import 'dart:convert';
import 'dart:io';

enum DirectSocketFailure {
  invalidArguments,
  invalidResponse,
  limit,
  unavailable,
}

class DirectSocketException implements Exception {
  const DirectSocketException(this.failure);
  final DirectSocketFailure failure;

  @override
  String toString() => 'DirectSocketException(${failure.name})';
}

List<int>? _decode(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(value)) return null;
  try {
    final bytes = base64Url.decode(
      value.padRight(value.length + (4 - value.length % 4) % 4, '='),
    );
    return base64Url.encode(bytes).replaceAll('=', '') == value ? bytes : null;
  } on FormatException {
    return null;
  }
}

bool isDirectSessionId(String value) =>
    value.length >= 22 &&
    value.length <= 64 &&
    (_decode(value)?.length ?? 0) >= 16;

bool isDirectConnectionId(String value) =>
    value.length == 22 && _decode(value)?.length == 16;

void validateDirectTarget(String sessionId, String host, int port) {
  final label = RegExp(r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$');
  final validHost =
      InternetAddress.tryParse(host) != null ||
      (host.length <= 253 &&
          host.split('.').every((part) => label.hasMatch(part)));
  if (!isDirectSessionId(sessionId) || !validHost || port < 1 || port > 65535) {
    throw const DirectSocketException(DirectSocketFailure.invalidArguments);
  }
}

class DirectSocketLease {
  const DirectSocketLease._(
    this.connectionId,
    this.bridgePort,
    this.ticket,
    this.expiresInMs,
  );
  final String connectionId;
  final int bridgePort;
  final List<int> ticket;
  final int expiresInMs;

  static DirectSocketLease parse(Object? value) {
    if (value is! Map) {
      throw const DirectSocketException(DirectSocketFailure.invalidResponse);
    }
    final id = value['connectionId'];
    final port = value['bridgePort'];
    final encoded = value['ticket'];
    final expires = value['expiresInMs'];
    final ticket = encoded is String && encoded.length == 43
        ? _decode(encoded)
        : null;
    if (id is! String ||
        !isDirectConnectionId(id) ||
        port is! int ||
        port < 1 ||
        port > 65535 ||
        ticket?.length != 32 ||
        expires is! int ||
        expires < 1 ||
        expires > 10000) {
      throw const DirectSocketException(DirectSocketFailure.invalidResponse);
    }
    return DirectSocketLease._(id, port, List.unmodifiable(ticket!), expires);
  }
}

abstract interface class DirectSocketApi {
  Future<DirectSocketLease> openDirectSocket({
    required String sessionId,
    required String host,
    required int port,
  });
  Future<void> closeDirectSocket({
    required String sessionId,
    required String connectionId,
  });
  Future<void> closeDirectSession({required String sessionId});
}
