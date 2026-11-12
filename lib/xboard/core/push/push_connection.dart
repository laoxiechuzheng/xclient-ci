class PushException implements Exception {
  const PushException(this.code);

  final String code;

  @override
  String toString() => 'PushException($code)';
}

class PushConnection {
  const PushConnection({required this.body, required this.cancel});

  final Stream<List<int>> body;
  final void Function() cancel;
}
