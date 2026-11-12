import 'dart:convert';

enum AndroidUpdateQaAction { prepare, install }

enum AndroidUpdateQaFailure {
  configuration,
  nativeIdentity,
  payload,
  lease,
  staleLease,
}

class AndroidUpdateQaRefused implements Exception {
  const AndroidUpdateQaRefused(this.reason);
  final AndroidUpdateQaFailure reason;

  @override
  String toString() => 'AndroidUpdateQaRefused: ${reason.name}';
}

class AndroidUpdateQaContract {
  const AndroidUpdateQaContract({
    required this.fixtureId,
    required this.sourceSha,
    required this.runId,
    required this.runAttempt,
    required this.stage,
    required this.v2Sha256,
    required this.v2Bytes,
  });

  final String fixtureId;
  final String sourceSha;
  final String runId;
  final String runAttempt;
  final String stage;
  final String v2Sha256;
  final int v2Bytes;

  static void _require(bool allowed, AndroidUpdateQaFailure reason) {
    if (!allowed) throw AndroidUpdateQaRefused(reason);
  }

  String get namespace {
    validateConfiguration();
    return 'q${fixtureId.substring(0, 12)}';
  }

  String get scopeName {
    validateConfiguration();
    return 'xclient-update-qa-$fixtureId';
  }

  String get version {
    validateConfiguration();
    return '1.0.0-pre.$stage';
  }

  int get buildNumber {
    validateConfiguration();
    return 10000400 + int.parse(stage);
  }

  void validateConfiguration() {
    final validArtifact = stage == '1'
        ? RegExp(r'^[0-9a-f]{64}$').hasMatch(v2Sha256) &&
              v2Bytes > 0 &&
              v2Bytes <= 512 * 1024 * 1024
        : v2Sha256.isEmpty && v2Bytes == 0;
    _require(
      RegExp(r'^[0-9a-f]{32}$').hasMatch(fixtureId) &&
          RegExp(r'^[0-9a-f]{40}$').hasMatch(sourceSha) &&
          RegExp(r'^[1-9][0-9]*$').hasMatch(runId) &&
          RegExp(r'^[1-9][0-9]*$').hasMatch(runAttempt) &&
          (stage == '1' || stage == '2') &&
          validArtifact,
      AndroidUpdateQaFailure.configuration,
    );
  }

  void validateNative({
    required bool safeMode,
    required bool isAndroid,
    required String brandId,
    required String packageName,
    required String nativeVersion,
    required String nativeBuild,
    required String canonicalVersion,
    required String canonicalBuild,
  }) {
    validateConfiguration();
    _require(
      safeMode &&
          isAndroid &&
          brandId == 'example' &&
          packageName == 'com.xclient.example' &&
          nativeVersion == version &&
          nativeBuild == '$buildNumber' &&
          canonicalVersion == version &&
          canonicalBuild == '$buildNumber',
      AndroidUpdateQaFailure.nativeIdentity,
    );
  }

  Map<String, Object?> decode(String value) {
    _require(
      utf8.encode(value).length <= 16 * 1024,
      AndroidUpdateQaFailure.payload,
    );
    try {
      final parsed = jsonDecode(value);
      _require(
        parsed is Map && parsed.keys.every((key) => key is String),
        AndroidUpdateQaFailure.payload,
      );
      return Map<String, Object?>.from(parsed as Map);
    } on AndroidUpdateQaRefused {
      rethrow;
    } on Object {
      throw const AndroidUpdateQaRefused(AndroidUpdateQaFailure.payload);
    }
  }

  void validateLease(
    Map<String, Object?> value, {
    required int pid,
    required AndroidUpdateQaAction action,
    required DateTime started,
    required DateTime modified,
    required DateTime now,
  }) {
    validateConfiguration();
    const fields = {
      'schema',
      'fixture_id',
      'source_sha',
      'run_id',
      'run_attempt',
      'stage',
      'pid',
      'action',
    };
    _require(
      value.length == fields.length &&
          value.keys.every(fields.contains) &&
          value['schema'] is int &&
          value['schema'] == 1 &&
          value['fixture_id'] == fixtureId &&
          value['source_sha'] == sourceSha &&
          value['run_id'] == runId &&
          value['run_attempt'] == runAttempt &&
          value['stage'] == stage &&
          pid > 0 &&
          pid <= 0x7fffffff &&
          value['pid'] is int &&
          value['pid'] == pid &&
          value['action'] == action.name &&
          (action != AndroidUpdateQaAction.install || stage == '1'),
      AndroidUpdateQaFailure.lease,
    );
    const tolerance = Duration(seconds: 2);
    _require(
      !now.isBefore(started) &&
          !modified.isBefore(started.subtract(tolerance)) &&
          !modified.isAfter(now.add(tolerance)) &&
          now.difference(modified) <= const Duration(seconds: 120),
      AndroidUpdateQaFailure.staleLease,
    );
  }
}
