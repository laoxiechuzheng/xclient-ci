import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:fl_clash/models/models.dart';
import 'package:fl_clash/common/path.dart';
import 'package:fl_clash/core/controller.dart';
import 'package:fl_clash/core/interface.dart';
import 'package:mocktail/mocktail.dart';
import 'package:fl_clash/providers/providers.dart';
import 'package:fl_clash/xboard/core/sync/flclash_profile_sink.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../helpers/test_profiles.dart';
import '../../helpers/app_paths.dart';

class _StopAction extends SetupAction {
  _StopAction(this.calls);
  final List<String> calls;
  @override
  void build() {}
  @override
  Future<bool> setRunning(bool running, {bool initialize = false}) async {
    calls.add('stop');
    throw StateError('stop failed');
  }
}

class _Profiles extends TestProfiles {
  _Profiles(super.initial, this.calls, {this.fail = false});
  final List<String> calls;
  final bool fail;
  @override
  Future<void> del(int id) async {
    calls.add('database');
    if (fail) throw StateError('database unavailable');
    await super.del(id);
  }
}

class _Files extends ProfilesAction {
  _Files(this.file, this.calls);
  final File file;
  final List<String> calls;
  @override
  void build() {}
  @override
  Future<void> clearEffect(int id) async {
    calls.add('file');
    if (await file.exists()) await file.delete();
  }
}

class _Core extends Mock implements CoreHandlerInterface {}

class _ApplyAction extends SetupAction {
  final called = Completer<void>();
  final result = Completer<bool>();
  bool? force;
  bool? silence;
  bool debounced = false;
  @override
  void build() {}
  @override
  Future<bool> applyProfile({
    bool silence = false,
    bool force = false,
    Future<void> Function()? preloadInvoke,
  }) {
    this.force = force;
    this.silence = silence;
    called.complete();
    return result.future;
  }

  @override
  void applyProfileDebounce({bool silence = false, bool force = false}) {
    debounced = true;
    called.complete();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final sinkProvider = Provider<FlClashProfileSink>(FlClashProfileSink.new);

  for (final accepted in [true, false]) {
    test(
      'managed profile awaits core application; accepted=$accepted',
      () async {
        SharedPreferences.setMockInitialValues({});
        final temp = await Directory.systemTemp.createTemp('xclient-apply-');
        addTearDown(() => temp.delete(recursive: true));
        await useAppPaths(temp);
        await Directory(await appPath.profilesPath).create(recursive: true);
        final core = _Core();
        when(() => core.validateConfig(any())).thenAnswer((_) async => '');
        final setup = _ApplyAction();
        final container = ProviderContainer(
          overrides: [
            setupActionProvider.overrideWith(() => setup),
            profilesProvider.overrideWith(TestProfiles.new),
            coreHandlerProvider.overrideWithValue(CoreController.scoped(core)),
          ],
        );
        addTearDown(container.dispose);
        var completed = false;
        final applying = container
            .read(sinkProvider)
            .apply(
              Uint8List.fromList('proxies: []'.codeUnits),
              label: 'Managed',
            )
            .whenComplete(() => completed = true);
        final result = accepted
            ? expectLater(applying, completes)
            : expectLater(applying, throwsStateError);
        await setup.called.future;
        await Future<void>.delayed(Duration.zero);
        try {
          expect(completed, isFalse);
          expect(setup.debounced, isFalse);
          expect(setup.force, isTrue);
          expect(setup.silence, isTrue);
        } finally {
          setup.result.complete(accepted);
          await result;
        }
      },
    );
  }

  for (final databaseFails in [false, true]) {
    test(
      'failed core stop still removes profile data; database failure=$databaseFails',
      () async {
        final profile = Profile.normal(label: 'Managed');
        SharedPreferences.setMockInitialValues({
          FlClashProfileSink.prefsKey: profile.id,
        });
        final temp = await Directory.systemTemp.createTemp('xclient-sink-');
        addTearDown(() => temp.delete(recursive: true));
        final file = File('${temp.path}/profile.yaml');
        await file.writeAsString('sensitive-node-data');
        final calls = <String>[];
        final container = ProviderContainer(
          overrides: [
            setupActionProvider.overrideWith(() => _StopAction(calls)),
            profilesProvider.overrideWith(
              () => _Profiles([profile], calls, fail: databaseFails),
            ),
            profilesActionProvider.overrideWith(() => _Files(file, calls)),
          ],
        );
        addTearDown(container.dispose);
        container.read(currentProfileIdProvider.notifier).value = profile.id;
        await expectLater(
          container.read(sinkProvider).remove(),
          throwsStateError,
        );
        expect(calls, ['stop', 'database', 'file']);
        expect(await file.exists(), isFalse);
        expect(await FlClashProfileSink.managedProfileId(), isNull);
        expect(container.read(currentProfileIdProvider), isNull);
        if (!databaseFails) expect(container.read(profilesProvider), isEmpty);
      },
    );
  }
  test(
    'remembered orphan file is cleaned even when the database row is absent',
    () async {
      const id = 12345;
      SharedPreferences.setMockInitialValues({FlClashProfileSink.prefsKey: id});
      final temp = await Directory.systemTemp.createTemp('xclient-orphan-');
      addTearDown(() => temp.delete(recursive: true));
      final file = File('${temp.path}/profile.yaml');
      await file.writeAsString('sensitive-node-data');
      final calls = <String>[];
      final container = ProviderContainer(
        overrides: [
          setupActionProvider.overrideWith(() => _StopAction(calls)),
          profilesProvider.overrideWith(() => _Profiles([], calls)),
          profilesActionProvider.overrideWith(() => _Files(file, calls)),
        ],
      );
      addTearDown(container.dispose);
      await expectLater(
        container.read(sinkProvider).remove(),
        throwsStateError,
      );
      expect(calls, ['stop', 'file']);
      expect(await file.exists(), isFalse);
      expect(await FlClashProfileSink.managedProfileId(), isNull);
    },
  );
}
