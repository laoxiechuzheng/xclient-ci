import 'dart:async';
import 'dart:io';

import 'spki.dart';
import 'direct_socket_connector.dart';

typedef PinReport = void Function(String host, String spki);

class StrictPinMismatch implements Exception {
  const StrictPinMismatch();
}

class _PlainHttpOverrides extends HttpOverrides {}

class StrictHttpClientFactory {
  StrictHttpClientFactory({
    PinPolicy Function()? pins,
    this.onPinReport,
    this.connectTimeout = const Duration(seconds: 8),
    this.connector,
  }) : pins = pins ?? (() => const PinPolicy());

  final PinPolicy Function() pins;
  final PinReport? onPinReport;
  final Duration connectTimeout;
  final DirectSocketConnector? connector;

  int get generation => connector?.generation ?? 0;

  HttpClient create({bool pin = true}) {
    final client = HttpOverrides.runWithHttpOverrides(
      HttpClient.new,
      _PlainHttpOverrides(),
    );
    client.findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (_, _, _) => false;
    client.connectionTimeout = connectTimeout;
    client.idleTimeout = const Duration(seconds: 15);
    client.userAgent = null;
    client.connectionFactory = (uri, host, port) =>
        _connect(uri, host, port, pin: pin);
    return client;
  }

  Future<ConnectionTask<Socket>> _connect(
    Uri uri,
    String? proxyHost,
    int? proxyPort, {
    required bool pin,
  }) async {
    if (uri.scheme != 'https') throw const HandshakeException('HTTPS required');
    if (proxyHost != null) throw const SocketException('DIRECT proxy refused');
    final bridge = connector;
    final ConnectionTask<Socket> task = bridge == null
        ? await SecureSocket.startConnect(
            uri.host,
            uri.port,
            onBadCertificate: (_) => false,
            supportedProtocols: const ['http/1.1'],
          )
        : await bridge.connect(
            uri,
            secure: (raw) async {
              final SecureSocket socket;
              try {
                socket = await SecureSocket.secure(
                  raw,
                  host: uri.host,
                  onBadCertificate: (_) => false,
                  supportedProtocols: const ['http/1.1'],
                );
              } catch (_) {
                raw.destroy();
                rethrow;
              }
              return _checkPin(socket, uri, pin);
            },
          );
    var cancelled = false;
    Socket? connected;
    void cancel() {
      cancelled = true;
      task.cancel();
      connected?.destroy();
    }

    final socket = task.socket
        .then((socket) async {
          connected = socket;
          if (cancelled) {
            socket.destroy();
            throw const SocketException('DIRECT connection cancelled');
          }
          final checked = bridge == null
              ? await _checkPin(socket as SecureSocket, uri, pin)
              : socket;
          if (cancelled) {
            checked.destroy();
            throw const SocketException('DIRECT connection cancelled');
          }
          return checked;
        })
        .timeout(
          connectTimeout,
          onTimeout: () {
            cancel();
            throw TimeoutException('TLS handshake timed out');
          },
        );
    return ConnectionTask.fromSocket(socket, cancel);
  }

  Future<Socket> _checkPin(SecureSocket socket, Uri uri, bool enabled) async {
    final pin = enabled ? pins().forHost(uri.host) : null;
    if (pin == null) return socket;
    try {
      final certificate = socket.peerCertificate;
      if (certificate == null) throw const StrictPinMismatch();
      final spki = await spkiSha256Base64(certificate.der);
      if (pin.spki.contains(spki)) return socket;
      onPinReport?.call(uri.host, spki);
      if (pin.mode == PinMode.enforce) throw const StrictPinMismatch();
      return socket;
    } catch (_) {
      socket.destroy();
      rethrow;
    }
  }
}
