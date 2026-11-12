enum XbErrorKind {
  /// Xboard may use 403, rather than 401, for an expired login.
  unauthorized,

  deviceRevoked,

  deviceLimit,

  deviceUnknown,

  replay,

  validation,

  rateLimited,

  server,

  network,

  tls,

  pinMismatch,

  notFound,

  badResponse,

  failed,
}

class XbApiException implements Exception {
  final XbErrorKind kind;
  final int? status;

  final String? code;

  /// May reach UI or logs; never include secrets.
  final String message;
  final Map<String, List<String>> errors;
  final Duration? retryAfter;

  const XbApiException(
    this.kind, {
    this.status,
    this.code,
    this.message = '',
    this.errors = const {},
    this.retryAfter,
  });

  bool get isEndpointFailure =>
      kind == XbErrorKind.network ||
      kind == XbErrorKind.tls ||
      kind == XbErrorKind.pinMismatch ||
      kind == XbErrorKind.server;

  bool get endsSession =>
      kind == XbErrorKind.unauthorized || kind == XbErrorKind.deviceRevoked;

  String get displayMessage {
    for (final list in errors.values) {
      if (list.isNotEmpty) return list.first;
    }
    return message;
  }

  @override
  String toString() =>
      'XbApiException(${kind.name}, status: $status, code: $code, $message)';
}
