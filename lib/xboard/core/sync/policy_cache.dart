import 'dart:convert';
import 'dart:io';

import '../crypto/crypto_exception.dart';
import '../crypto/signed_doc.dart';
import 'update_docs.dart';

abstract class PolicyCache {
  Future<String?> read();
  Future<void> write(String content);
}

class MemoryPolicyCache implements PolicyCache {
  String? content;
  MemoryPolicyCache([this.content]);
  @override
  Future<String?> read() async => content;
  @override
  Future<void> write(String content) async => this.content = content;
}

class FilePolicyCache implements PolicyCache {
  static final _operations = <String, Future<void>>{};
  final String path;
  const FilePolicyCache(this.path);

  Future<T> _serialized<T>(Future<T> Function() action) {
    final key = File(path).absolute.path;
    final running = (_operations[key] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = running.then<void>((_) {}, onError: (Object _) {});
    _operations[key] = settled;
    settled.whenComplete(() {
      if (identical(_operations[key], settled)) _operations.remove(key);
    });
    return running;
  }

  @override
  Future<String?> read() => _serialized(() async {
    final file = File(path);
    return await file.exists() ? file.readAsString() : null;
  });

  @override
  Future<void> write(String content) => _serialized(() async {
    final file = File(path);
    await file.parent.create(recursive: true);
    final temp = File('$path.tmp');
    await temp.writeAsString(content, flush: true);
    await temp.rename(path);
  });
}

class PolicyDocument {
  final Map<String, dynamic> raw;
  final XcPolicy policy;
  final String content;
  final int? expiresAt;
  const PolicyDocument(this.raw, this.policy, this.content, this.expiresAt);
  bool expired(DateTime now) =>
      expiresAt != null && now.millisecondsSinceEpoch ~/ 1000 >= expiresAt!;

  static Future<PolicyDocument> verify(
    Map<String, dynamic> raw, {
    required TrustedKeys keys,
    required String brandId,
    required DateTime now,
    bool allowExpired = false,
  }) async {
    final verified = await verifySignedDoc(
      raw,
      prefix: SignedDocKind.policy,
      keys: keys,
    );
    final payload = verified.payload;
    if (payload['brand'] != brandId) {
      throw const XcCryptoException(XcCryptoException.brand);
    }
    if (payload['seq'] is! int ||
        (payload['seq'] as int) < 0 ||
        payload['force'] is! bool) {
      throw const XcCryptoException(
        XcCryptoException.badFormat,
        'policy fields',
      );
    }
    for (final field in ['latest', 'min_supported']) {
      final value = payload[field];
      if (value != null && (value is! String || !_version(value))) {
        throw const XcCryptoException(
          XcCryptoException.badFormat,
          'policy version',
        );
      }
    }
    if (payload['notes'] is! String || payload['release_urls'] is! List) {
      throw const XcCryptoException(
        XcCryptoException.badFormat,
        'policy fields',
      );
    }
    for (final value in payload['release_urls'] as List) {
      final url = value is String ? Uri.tryParse(value) : null;
      if (url == null ||
          url.scheme != 'https' ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.hasFragment) {
        throw const XcCryptoException(XcCryptoException.insecureUrl);
      }
    }
    for (final field in ['issued_at', 'expires_at']) {
      if (payload.containsKey(field) &&
          (payload[field] is! int || (payload[field] as int) < 0)) {
        throw const XcCryptoException(
          XcCryptoException.badFormat,
          'policy time',
        );
      }
    }
    final issued = payload['issued_at'] as int?;
    final expiry = payload['expires_at'] as int?;
    if (issued != null && expiry != null && expiry <= issued) {
      throw const XcCryptoException(
        XcCryptoException.badFormat,
        'policy lifetime',
      );
    }
    final sec = now.millisecondsSinceEpoch ~/ 1000;
    if (issued != null && issued > sec + 60) {
      throw const XcCryptoException(XcCryptoException.notYetValid);
    }
    if (!allowExpired && expiry != null && expiry <= sec) {
      throw const XcCryptoException(XcCryptoException.expired);
    }
    final body = Map<String, dynamic>.of(payload)
      ..remove('issued_at')
      ..remove('expires_at');
    return PolicyDocument(
      Map.of(raw),
      XcPolicy.fromPayload(payload, brandId),
      jsonEncode(_sorted(body)),
      expiry,
    );
  }

  static bool _version(String value) =>
      value.isEmpty ||
      RegExp(
        r'^v?\d+(?:\.\d+)?(?:\.\d+)?(?:-[0-9A-Za-z.-]+)?(?:\+\d+)?$',
      ).hasMatch(value.trim());

  static Object? _sorted(Object? value) {
    if (value is Map<String, dynamic>) {
      final keys = value.keys.toList()..sort();
      return {for (final key in keys) key: _sorted(value[key])};
    }
    if (value is List) return value.map(_sorted).toList();
    return value;
  }
}
