import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../tool/xclient/collect_artifacts.dart';
import '../../../tool/xclient/src/png.dart';

void main() {
  group('releaseNameFor', () {
    String? name(String platform, String file) => releaseNameFor(
      platform: platform,
      brand: '98k',
      version: '1.0.0',
      fileName: file,
    );

    test('maps flutter_distributor and Gradle outputs to DESIGN names', () {
      expect(
        name('android', '98kClient-1.0.0+1000000-android-arm64-v8a.apk'),
        '98k-android-arm64-v8a-v1.0.0.apk',
      );
      expect(
        name('android', '98k-android-armeabi-v7a-v1.0.0.apk'),
        '98k-android-armeabi-v7a-v1.0.0.apk',
      );
      expect(
        name('android', 'app-x86_64-release.apk'),
        '98k-android-x86_64-v1.0.0.apk',
      );
      expect(
        name('windows', '98kClient-1.0.0+1000000-windows-amd64-setup.exe'),
        '98k-windows-x64-setup-v1.0.0.exe',
      );
      expect(name('windows', '98kClient.exe'), isNull);
      expect(name('android', 'output-metadata.json'), isNull);
      expect(name('macos', 'x.dmg'), '98k-macos-universal-v1.0.0.dmg');
      expect(name('macos', 'x.zip'), '98k-macos-universal-v1.0.0.zip');
    });
  });

  group('collectArtifacts', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('collect_test_');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    void touch(String relative) {
      File(p.join(temp.path, 'dist', relative))
        ..parent.createSync(recursive: true)
        ..writeAsStringSync(relative);
    }

    test('copies every ABI under its release name', () {
      touch('1.0.0/A-1.0.0-android-arm64-v8a.apk');
      touch('1.0.0/A-1.0.0-android-armeabi-v7a.apk');
      touch('1.0.0/A-1.0.0-android-x86_64.apk');
      final copied = collectArtifacts(
        brand: 'mg',
        version: '1.0.0',
        platform: 'android',
        from: p.join(temp.path, 'dist'),
        to: p.join(temp.path, 'out'),
      );
      expect(copied.map(p.basename).toSet(), {
        'mg-android-arm64-v8a-v1.0.0.apk',
        'mg-android-armeabi-v7a-v1.0.0.apk',
        'mg-android-x86_64-v1.0.0.apk',
      });
    });

    test('fails without the arm64 APK or with two candidates', () {
      touch('A-android-x86_64.apk');
      expect(
        () => collectArtifacts(
          brand: 'mg',
          version: '1.0.0',
          platform: 'android',
          from: p.join(temp.path, 'dist'),
          to: p.join(temp.path, 'out'),
        ),
        throwsA(isA<ArtifactException>()),
      );
      touch('A-android-arm64-v8a.apk');
      touch('B-android-arm64-v8a.apk');
      expect(
        () => collectArtifacts(
          brand: 'mg',
          version: '1.0.0',
          platform: 'android',
          from: p.join(temp.path, 'dist'),
          to: p.join(temp.path, 'out'),
        ),
        throwsA(isA<ArtifactException>()),
      );
    });

    for (final abi in ['arm64-v8a', 'armeabi-v7a', 'x86_64']) {
      test('collects a standalone $abi shard', () {
        final input = 'A-android-$abi.apk';
        touch(input);
        touch('output-metadata.json');
        final copied = collectArtifacts(
          brand: 'mg',
          version: '1.0.0',
          platform: 'android',
          from: p.join(temp.path, 'dist'),
          to: p.join(temp.path, 'out'),
          androidAbi: abi,
        );
        expect(copied.map(p.basename), ['mg-android-$abi-v1.0.0.apk']);
        expect(File(copied.single).readAsStringSync(), input);
      });
    }

    test('requires the selected ABI before creating output', () {
      touch('output-metadata.json');
      expect(
        () => collectArtifacts(
          brand: 'mg',
          version: '1.0.0',
          platform: 'android',
          from: p.join(temp.path, 'dist'),
          to: p.join(temp.path, 'out'),
          androidAbi: 'x86_64',
        ),
        throwsA(
          isA<ArtifactException>().having(
            (error) => error.message,
            'message',
            contains('mg-android-x86_64-v1.0.0.apk'),
          ),
        ),
      );
      expect(Directory(p.join(temp.path, 'out')).existsSync(), isFalse);
    });

    for (final extra in [
      'arm64-v8a',
      'x86_64',
      'universal',
      'armeabi-v7a-x86_64',
    ]) {
      test('rejects $extra APKs mixed into the arm32 shard', () {
        touch('A-android-armeabi-v7a.apk');
        touch('B-android-$extra.apk');
        expect(
          () => collectArtifacts(
            brand: 'mg',
            version: '1.0.0',
            platform: 'android',
            from: p.join(temp.path, 'dist'),
            to: p.join(temp.path, 'out'),
            androidAbi: 'armeabi-v7a',
          ),
          throwsA(
            isA<ArtifactException>().having(
              (error) => error.message,
              'message',
              contains('not selected ABI armeabi-v7a'),
            ),
          ),
        );
        expect(Directory(p.join(temp.path, 'out')).existsSync(), isFalse);
      });
    }

    test('rejects an Android ABI on another platform', () {
      touch('A-setup.exe');
      expect(
        () => collectArtifacts(
          brand: 'mg',
          version: '1.0.0',
          platform: 'windows',
          from: p.join(temp.path, 'dist'),
          to: p.join(temp.path, 'out'),
          androidAbi: 'arm64-v8a',
        ),
        throwsA(
          isA<ArtifactException>().having(
            (error) => error.message,
            'message',
            contains('only valid for android'),
          ),
        ),
      );
      expect(Directory(p.join(temp.path, 'out')).existsSync(), isFalse);
    });

    test('rejects an unknown Android ABI', () {
      touch('A-android-arm64-v8a.apk');
      expect(
        () => collectArtifacts(
          brand: 'mg',
          version: '1.0.0',
          platform: 'android',
          from: p.join(temp.path, 'dist'),
          to: p.join(temp.path, 'out'),
          androidAbi: 'mips',
        ),
        throwsA(
          isA<ArtifactException>().having(
            (error) => error.message,
            'message',
            contains('invalid Android ABI'),
          ),
        ),
      );
      expect(Directory(p.join(temp.path, 'out')).existsSync(), isFalse);
    });
  });

  group('placeholder PNG', () {
    test('is a well-formed RGBA PNG of the requested size', () {
      final png = renderPlaceholderIcon(48, background: 0x3F6FD8);
      expect(png.sublist(0, 8), [
        0x89,
        0x50,
        0x4E,
        0x47,
        0x0D,
        0x0A,
        0x1A,
        0x0A,
      ]);
      final header = ByteData.sublistView(png, 16, 29);
      expect(header.getUint32(0), 48);
      expect(header.getUint32(4), 48);
      expect(header.getUint8(8), 8);
      expect(header.getUint8(9), 6);
      final idatLength = ByteData.sublistView(png, 33, 37).getUint32(0);
      final raw = ZLibCodec().decode(png.sublist(41, 41 + idatLength));
      expect(raw, hasLength(48 * (48 * 4 + 1)));
    });
  });
}
