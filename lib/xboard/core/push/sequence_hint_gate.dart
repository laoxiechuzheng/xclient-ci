import '../net/api_client.dart';

class SequenceHintGate {
  SequenceHintGate({required this.now, this.gap = const Duration(seconds: 10)});

  final DateTime Function() now;
  final Duration gap;
  DateTime? _bootReaction;
  DateTime? _policyReaction;

  ({bool boot, bool policy}) react(
    XClientSeq seq, {
    required int bootFloor,
    required int policyFloor,
  }) {
    final date = now();
    final boot =
        seq.boot != null &&
        seq.boot! >= 0 &&
        seq.boot! > bootFloor &&
        (_bootReaction == null || date.difference(_bootReaction!) >= gap);
    final policy =
        seq.policy != null &&
        seq.policy! >= 0 &&
        seq.policy! > policyFloor &&
        (_policyReaction == null || date.difference(_policyReaction!) >= gap);
    if (boot) _bootReaction = date;
    if (policy) _policyReaction = date;
    return (boot: boot, policy: policy);
  }
}
