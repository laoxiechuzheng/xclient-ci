import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../core/log.dart';
import '../core/sync/update_docs.dart';
import 'update_exception.dart';
import 'update_http.dart';

typedef DownloadProgress = void Function(int received, int total);

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Future<String> sha256OfFile(File file) async {
  final sink = _DigestSink();
  final input = sha256.startChunkedConversion(sink);
  await for (final chunk in file.openRead()) {
    input.add(chunk);
  }
  input.close();
  return sink.value.toString();
}

Future<bool> isVerifiedCopy(File file, ReleaseAsset asset) async {
  try {
    if (!await file.exists() || await file.length() != asset.size) {
      return false;
    }
    return await sha256OfFile(file) == asset.sha256;
  } on FileSystemException {
    return false;
  }
}

/// Returns only a package matching the signed size and SHA-256; retries start from zero.
/// Partial or mismatched files are deleted before another URL is tried.
Future<File> downloadVerified({
  required ReleaseAsset asset,
  required File target,
  required UpdateHttp http,
  DownloadProgress? onProgress,
  int rounds = 2,
  Duration idleTimeout = const Duration(seconds: 30),
  bool Function()? isCancelled,
}) async {
  if (await isVerifiedCopy(target, asset)) {
    onProgress?.call(asset.size, asset.size);
    return target;
  }
  await target.parent.create(recursive: true);
  final part = File('${target.path}.part');
  XcUpdateException last = const XcUpdateException(XcUpdateException.download);
  for (var round = 0; round < rounds; round++) {
    for (final url in asset.urls) {
      if (isCancelled?.call() ?? false) {
        throw const XcUpdateException(XcUpdateException.download, 'cancelled');
      }
      final uri = Uri.tryParse(url);
      if (uri == null || uri.scheme != 'https') continue;
      try {
        await _fetchOnce(
          uri: uri,
          asset: asset,
          part: part,
          http: http,
          onProgress: onProgress,
          idleTimeout: idleTimeout,
          isCancelled: isCancelled,
        );
        if (await target.exists()) await target.delete();
        await part.rename(target.path);
        return target;
      } on XcUpdateException catch (error) {
        last = error;
        xcLog(
          'update download refused (${uri.host}): ${error.code}',
          warn: true,
        );
      } catch (error) {
        last = XcUpdateException(
          XcUpdateException.download,
          '${error.runtimeType}',
        );
        xcLog(
          'update download failed (${uri.host}): ${error.runtimeType}',
          warn: true,
        );
      }
      await _deleteQuietly(part);
    }
  }
  throw last;
}

Future<void> _fetchOnce({
  required Uri uri,
  required ReleaseAsset asset,
  required File part,
  required UpdateHttp http,
  required DownloadProgress? onProgress,
  required Duration idleTimeout,
  bool Function()? isCancelled,
}) async {
  final response = await http.get(uri).timeout(idleTimeout);
  if (response.statusCode != 200) {
    response.cancel();
    throw XcUpdateException(
      XcUpdateException.download,
      'HTTP ${response.statusCode}',
    );
  }
  final length = response.contentLength;
  if (length != null && length != asset.size) {
    response.cancel();
    throw XcUpdateException(XcUpdateException.size, 'length $length');
  }
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  final sink = part.openWrite();
  var received = 0;
  try {
    onProgress?.call(0, asset.size);
    await for (final chunk in response.body.timeout(idleTimeout)) {
      if (isCancelled?.call() ?? false) {
        response.cancel();
        throw const XcUpdateException(XcUpdateException.download, 'cancelled');
      }
      received += chunk.length;
      if (received > asset.size) {
        response.cancel();
        throw const XcUpdateException(XcUpdateException.size, 'too long');
      }
      hasher.add(chunk);
      sink.add(chunk);
      onProgress?.call(received, asset.size);
    }
  } finally {
    response.cancel();
    await sink.close();
  }
  hasher.close();
  if (received != asset.size) {
    throw XcUpdateException(XcUpdateException.size, 'got $received');
  }
  if (digest.value.toString() != asset.sha256) {
    throw const XcUpdateException(XcUpdateException.checksum);
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    if (await file.exists()) await file.delete();
  } on FileSystemException {
    // A leftover .part is overwritten by the next attempt.
  }
}
