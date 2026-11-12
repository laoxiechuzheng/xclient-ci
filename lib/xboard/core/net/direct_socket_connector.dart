import 'dart:io';

typedef SocketUpgrade = Future<Socket> Function(Socket socket);

abstract interface class DirectSocketConnector {
  int get generation;
  Future<ConnectionTask<Socket>> connect(
    Uri uri, {
    required SocketUpgrade secure,
  });
  void close();
}
