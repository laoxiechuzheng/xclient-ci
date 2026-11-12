import 'dart:io';

import 'package:fl_clash/xboard/core/sync/update_docs.dart';
import 'package:fl_clash/xboard/update/install/android_installer.dart';
import 'package:fl_clash/xboard/update/install/installer.dart';
import 'package:fl_clash/xboard/update/update_exception.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

const manifest = ReleaseManifest(
  brand: 'example',
  version: '2.0.0',
  build: 2,
  publishedAt: 1,
  assets: {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(
      AndroidUpdateInstaller.channel,
      null,
    ),
  );

  test('rejects unreadable signer before native install', () async {
    final installer = AndroidUpdateInstaller();
    var installs = 0;
    messenger.setMockMethodCallHandler(AndroidUpdateInstaller.channel, (
      call,
    ) async {
      if (call.method == 'canInstall') return true;
      if (call.method == 'inspectArchive') {
        return {'samePackage': true, 'newerVersion': true};
      }
      installs++;
      return null;
    });
    await expectLater(
      installer.install(File('test.apk'), manifest: manifest),
      throwsA(
        isA<XcUpdateException>().having(
          (e) => e.code,
          'code',
          XcUpdateException.packageMismatch,
        ),
      ),
    );
    expect(installs, 0);
    installer.dispose();
  });

  test(
    'routes early callbacks by session and waits for system success',
    () async {
      final installer = AndroidUpdateInstaller();
      final stages = <InstallStage>[];
      Future<void> status(int session, String value) =>
          messenger.handlePlatformMessage(
            'xclient/update',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onInstallStatus', {
                'sessionId': session,
                'status': value,
              }),
            ),
            (_) {},
          );
      messenger.setMockMethodCallHandler(AndroidUpdateInstaller.channel, (
        call,
      ) async {
        if (call.method == 'canInstall') return true;
        if (call.method == 'inspectArchive') {
          return {
            'samePackage': true,
            'sameSigner': true,
            'newerVersion': true,
          };
        }
        if (call.method == 'install') {
          await status(99, 'failure');
          await status(7, 'pending_user');
          await status(7, 'success');
          return 7;
        }
        return null;
      });
      final outcome = await installer.install(
        File('test.apk'),
        manifest: manifest,
        onStage: stages.add,
      );
      expect(outcome, InstallOutcome.installed);
      expect(stages, contains(InstallStage.awaitingUser));
      installer.dispose();
    },
  );
}
