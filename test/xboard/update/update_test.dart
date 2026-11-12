import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:fl_clash/xboard/brand/brand_config.dart';
import 'package:fl_clash/xboard/core/crypto/b64u.dart';
import 'package:fl_clash/xboard/core/crypto/signed_doc.dart';
import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:fl_clash/xboard/core/ua.dart';
import 'package:fl_clash/xboard/update/download.dart';
import 'package:fl_clash/xboard/update/install/installer.dart';
import 'package:fl_clash/xboard/update/install/macos_installer.dart';
import 'package:fl_clash/xboard/update/install/windows_installer.dart';
import 'package:fl_clash/xboard/update/release_fetch.dart';
import 'package:fl_clash/xboard/update/update_exception.dart';
import 'package:fl_clash/xboard/update/update_http.dart';
import 'package:fl_clash/xboard/update/update_manager.dart';
import 'package:fl_clash/xboard/update/update_policy.dart';
import 'package:fl_clash/xboard/update/version.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeHttp implements UpdateHttp {
  final Future<UpdateHttpResponse> Function(Uri) handle;
  final requests = <Uri>[];
  FakeHttp(this.handle);
  @override
  Future<UpdateHttpResponse> get(Uri uri) {
    requests.add(uri);
    return handle(uri);
  }

  @override
  void close() {}
}

class FakeInstaller implements XcPlatformInstaller {
  int installs = 0;
  @override
  String get extension => 'apk';
  @override
  Future<bool> canInstall() async => true;
  @override
  Future<bool> requestInstallPermission() async => true;
  @override
  Future<InstallOutcome> install(
    File file, {
    required ReleaseManifest manifest,
    InstallStageListener? onStage,
  }) async {
    installs++;
    return InstallOutcome.installed;
  }
}

XcPolicy policy({String latest = '2.0.0', bool force = false, int seq = 1}) =>
    XcPolicy(
      brand: 'example',
      seq: seq,
      latest: latest,
      minSupported: '1.0.0',
      force: force,
      releaseUrls: const ['https://releases.example/manifest.json'],
    );

Future<({TrustedKeys keys, Map<String, dynamic> doc})> signedRelease({
  String version = '2.0.0',
  String brand = 'example',
}) async {
  final pair = await Ed25519().newKeyPairFromSeed(List.filled(32, 42));
  final pub = await pair.extractPublicKey();
  final payload = b64uEncode(
    utf8.encode(
      jsonEncode({
        'brand': brand,
        'version': version,
        'build': 2,
        'published_at': 1,
        'assets': {
          'android-arm64-v8a': {
            'urls': ['https://releases.example/app.apk'],
            'sha256': sha256.convert([1, 2, 3]).toString(),
            'size': 3,
          },
        },
      }),
    ),
  );
  final signature = await Ed25519().sign(
    utf8.encode('${SignedDocKind.release}$payload'),
    keyPair: pair,
  );
  return (
    keys: TrustedKeys({'rel-test': pub.bytes}),
    doc: {
      'v': 1,
      'kid': 'rel-test',
      'payload': payload,
      'sig': b64uEncode(signature.bytes),
    },
  );
}

UpdateHttpResponse bytesResponse(List<int> bytes) => UpdateHttpResponse(
  statusCode: 200,
  contentLength: bytes.length,
  body: Stream.value(bytes),
);

void main() {
  group('version and policy', () {
    test('semver prerelease order and explicit build order', () {
      for (final (a, b) in [
        ('1.0.0-alpha.2', '1.0.0-alpha.10'),
        ('1.0.0-rc.1', '1.0.0'),
        ('1.0.0+1', '1.0.0+2'),
      ]) {
        expect(
          AppVersion.tryParse(a)!.compareTo(AppVersion.tryParse(b)!),
          lessThan(0),
        );
      }
      expect(
        AppVersion.tryParse(
          '1.0.0',
        )!.compareTo(AppVersion.tryParse('1.0.0+4')!),
        0,
      );
      expect(AppVersion.tryParse('invalid'), isNull);
    });
    test('notify, force, minimum supported and current', () {
      const current = AppVersion(1, 0, 0);
      expect(decideUpdate(policy(), current).mode, UpdateMode.notify);
      expect(decideUpdate(policy(force: true), current).mode, UpdateMode.force);
      expect(decideUpdate(policy(latest: '1.0.0'), current).hasUpdate, isFalse);
      expect(
        decideUpdate(
          const XcPolicy(
            brand: 'example',
            seq: 1,
            latest: '2.0.0',
            minSupported: '1.1.0',
          ),
          current,
        ).isForced,
        isTrue,
      );
    });
    test('notification is quiet for 24 hours per version', () async {
      var now = DateTime.utc(2026, 11, 4);
      final throttle = UpdateNoticeThrottle(
        MemoryUpdateNoticeStore(),
        now: () => now,
      );
      expect(await throttle.shouldNotify('2.0.0'), isTrue);
      await throttle.markNotified('2.0.0');
      expect(await throttle.shouldNotify('2.0.0'), isFalse);
      expect(await throttle.shouldNotify('2.1.0'), isTrue);
      now = now.add(const Duration(hours: 24));
      expect(await throttle.shouldNotify('2.0.0'), isTrue);
    });

    for (final (minimum, current, blocked) in [
      ('1.0.0-pre.1+10000402', '1.0.0-pre.1+10000401', true),
      ('1.0.0-pre.1+10000401', '1.0.0-pre.1+10000401', false),
      ('1.0.0-pre.1+10000400', '1.0.0-pre.1+10000401', false),
      ('1.0.0-pre.1', '1.0.0-pre.1+10000401', false),
      ('1.0.0-pre.1+10000402', '1.0.0-pre.1', false),
      ('1.0.1-pre.1+1', '1.0.0-pre.1+10000401', true),
      ('0.9.9+999999999', '1.0.0-pre.1+10000401', false),
    ]) {
      test(
        'minimum $minimum against logical $current preserves build-aware admission',
        () {
          final decision = decideUpdate(
            XcPolicy(
              brand: 'example',
              seq: 1,
              latest: '2.0.0',
              minSupported: minimum,
            ),
            AppVersion.tryParse(current)!,
          );
          expect(decision.isForced, blocked);
          expect(decision.belowMinSupported, blocked);
        },
      );
    }
  });

  group('signed release', () {
    test('falls back over unavailable and invalid URLs', () async {
      final signed = await signedRelease();
      final http = FakeHttp(
        (uri) async => uri.path == '/bad'
            ? bytesResponse(utf8.encode('{}'))
            : bytesResponse(utf8.encode(jsonEncode(signed.doc))),
      );
      final manifest = await fetchReleaseManifest(
        urls: ['https://releases.example/bad', 'https://releases.example/good'],
        http: http,
        relKeys: signed.keys,
        brandId: 'example',
        expectedVersion: '2.0.0',
      );
      expect(manifest.version, '2.0.0');
      expect(http.requests.length, 2);
    });
    test('rejects wrong brand and bad signature', () async {
      for (final wrongBrand in [false, true]) {
        final signed = await signedRelease(
          brand: wrongBrand ? 'other' : 'example',
        );
        final doc = {...signed.doc};
        if (!wrongBrand) doc['sig'] = b64uEncode(List.filled(64, 0));
        final http = FakeHttp(
          (_) async => bytesResponse(utf8.encode(jsonEncode(doc))),
        );
        await expectLater(
          fetchReleaseManifest(
            urls: ['https://releases.example/doc'],
            http: http,
            relKeys: signed.keys,
            brandId: 'example',
            expectedVersion: '2.0.0',
          ),
          throwsA(isA<XcUpdateException>()),
        );
      }
    });
    test('binds prerelease and build exactly to policy', () async {
      final signed = await signedRelease(version: '2.0.0-beta.1');
      final http = FakeHttp(
        (_) async => bytesResponse(utf8.encode(jsonEncode(signed.doc))),
      );
      await expectLater(
        fetchReleaseManifest(
          urls: ['https://releases.example/doc'],
          http: http,
          relKeys: signed.keys,
          brandId: 'example',
          expectedVersion: '2.0.0',
        ),
        throwsA(isA<XcUpdateException>()),
      );
    });
  });

  group('download and policy replacement', () {
    late Directory dir;
    setUp(
      () async =>
          dir = await Directory.systemTemp.createTemp('xc-update-test-'),
    );
    tearDown(() => dir.delete(recursive: true));
    test('checksum failure is deleted; next URL succeeds', () async {
      final target = File('${dir.path}/app.apk');
      final http = FakeHttp(
        (uri) async =>
            bytesResponse(uri.path == '/bad' ? [3, 2, 1] : [1, 2, 3]),
      );
      await downloadVerified(
        asset: ReleaseAsset(
          urls: const [
            'https://releases.example/bad',
            'https://releases.example/good',
          ],
          sha256: sha256.convert([1, 2, 3]).toString(),
          size: 3,
        ),
        target: target,
        http: http,
      );
      expect(await target.readAsBytes(), [1, 2, 3]);
      expect(await File('${target.path}.part').exists(), isFalse);
      expect(http.requests.length, 2);
    });
    test(
      'revoked policy never installs an already downloading package',
      () async {
        final signed = await signedRelease();
        final downloading = Completer<void>();
        final body = StreamController<List<int>>();
        final installer = FakeInstaller();
        final manager = XcUpdateManager(
          brand: BrandConfig(
            brandId: 'example',
            displayName: 'Example',
            relPubKeys: {
              for (final kid in signed.keys.kids)
                kid: b64uEncode(signed.keys[kid]!),
            },
          ),
          current: const AppVersion(1, 0, 0),
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          http: FakeHttp((uri) async {
            if (uri.path.endsWith('.json')) {
              return bytesResponse(utf8.encode(jsonEncode(signed.doc)));
            }
            downloading.complete();
            return UpdateHttpResponse(
              statusCode: 200,
              contentLength: 3,
              body: body.stream,
            );
          }),
          installer: installer,
          throttle: UpdateNoticeThrottle(MemoryUpdateNoticeStore()),
          workDir: () async => dir,
        );
        await manager.onPolicy(policy());
        final running = manager.start();
        await downloading.future;
        await manager.onPolicy(policy(latest: '1.0.0', seq: 2));
        body.add([1, 2, 3]);
        await body.close();
        await running;
        expect(installer.installs, 0);
        manager.dispose();
      },
    );
    test(
      'forced gate survives download failure and dismissed notice',
      () async {
        final manager = XcUpdateManager(
          brand: const BrandConfig(brandId: 'example', displayName: 'Example'),
          current: const AppVersion(1, 0, 0),
          platform: XcPlatform.android,
          arch: 'arm64-v8a',
          http: FakeHttp((_) async => throw const SocketException('offline')),
          installer: FakeInstaller(),
          throttle: UpdateNoticeThrottle(MemoryUpdateNoticeStore()),
          workDir: () async => dir,
        );
        await manager.onPolicy(policy(force: true));
        await manager.start();
        await manager.noticeShown();
        expect(manager.state.phase, XcUpdatePhase.failed);
        expect(manager.forceActive, isTrue);
        manager.dispose();
      },
    );
  });

  test('macOS aborts replacement if old app refuses to exit', () {
    final script = macosSwapScript(
      appPath: '/Applications/X.app',
      newAppPath: '/Applications/.X.update/X.app',
      stagingDir: '/Applications/.X.update',
      appPid: 123,
      logPath: '/tmp/update.log',
    );
    expect(script, isNot(contains('swapping anyway')));
    expect(script, contains('exit 1'));
    expect(shQuote("a'b"), "'a'\\''b'");
  });
  test('ad-hoc signatures bind identifier and rely on release digest', () {
    const old = CodesignInfo(
      identifier: 'com.example.x',
      adhoc: true,
      cdhash: 'old',
    );
    expect(
      signingIdentityMatches(
        old,
        const CodesignInfo(
          identifier: 'com.example.x',
          adhoc: true,
          cdhash: 'new',
        ),
      ),
      isTrue,
    );
    expect(
      signingIdentityMatches(
        old,
        const CodesignInfo(identifier: 'com.other.x', adhoc: true),
      ),
      isFalse,
    );
    expect(
      windowsUpdateScript(
        setupPath: "C:\\a'b\\setup.exe",
        appPath: 'C:\\app.exe',
        appPid: 123,
        logPath: 'C:\\log',
      ),
      contains("a''b"),
    );
  });
}
