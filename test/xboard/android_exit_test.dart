import 'dart:async';

import 'package:fl_clash/xboard/lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

class _ExitFixture {
  final calls = <String>[];
  Completer<bool>? stopGate;
  bool stopResult = true;
  bool cleanupFails = false;
  bool releaseFails = false;
  bool abortResult = true;
  bool abortThrows = false;
  Duration stopTimeout = const Duration(seconds: 30);
  late final coordinator = ManagedAndroidExitCoordinator(
    begin: () async {
      calls.add('begin');
      return 7;
    },
    stop: () async {
      calls.add('stop');
      return await stopGate?.future ?? stopResult;
    },
    abort: (generation) async {
      calls.add('abort:$generation');
      if (abortThrows) throw StateError('abort');
      return abortResult;
    },
    complete: (generation) async {
      calls.add('complete:$generation');
      return true;
    },
    release: () async {
      calls.add('release');
      if (releaseFails) throw StateError('release');
    },
    closeCore: () async => calls.add('core'),
    setClosing: (value) => calls.add('closing:$value'),
    stopTimeout: stopTimeout,
  );
  Future<void> cleanup() async {
    calls.add('cleanup');
    if (cleanupFails) throw StateError('cleanup');
  }
}

void main() {
  for (final throws in [false, true]) {
    test(
      'an unconfirmed abort retains the native barrier and allows Quit retry throws=$throws',
      () async {
        final fixture = _ExitFixture()
          ..stopResult = false
          ..abortResult = false
          ..abortThrows = throws;
        await expectLater(
          fixture.coordinator.exit(cleanup: fixture.cleanup),
          throwsStateError,
        );
        expect(fixture.calls, ['closing:true', 'begin', 'stop', 'abort:7']);
        fixture.stopResult = true;
        await fixture.coordinator.exit(cleanup: fixture.cleanup);
        expect(fixture.calls.last, 'complete:7');
        expect(fixture.calls, isNot(contains('closing:false')));
      },
    );
  }

  test(
    'stop timeout preserves runtime and ignores a late stop result',
    () async {
      final fixture = _ExitFixture()
        ..stopGate = Completer<bool>()
        ..stopTimeout = const Duration(milliseconds: 5);
      await expectLater(
        fixture.coordinator.exit(cleanup: fixture.cleanup),
        throwsA(isA<TimeoutException>()),
      );
      fixture.stopGate!.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.calls, [
        'closing:true',
        'begin',
        'stop',
        'abort:7',
        'closing:false',
      ]);
    },
  );
  test(
    'managed Quit waits for confirmed stop before all terminal cleanup',
    () async {
      final fixture = _ExitFixture()..stopGate = Completer<bool>();
      final first = fixture.coordinator.exit(cleanup: fixture.cleanup);
      final second = fixture.coordinator.exit(
        cleanup: () async => fail('duplicate cleanup'),
      );
      expect(identical(first, second), isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(fixture.calls, ['closing:true', 'begin', 'stop']);
      fixture.stopGate!.complete(true);
      await first;
      expect(fixture.calls, [
        'closing:true',
        'begin',
        'stop',
        'cleanup',
        'release',
        'core',
        'complete:7',
      ]);
      await fixture.coordinator.exit(
        cleanup: () async => fail('terminal reactivation'),
      );
      expect(fixture.calls.where((call) => call == 'release'), hasLength(1));
    },
  );

  test(
    'unconfirmed native stop aborts before runtime and Core disposal',
    () async {
      final fixture = _ExitFixture()..stopResult = false;
      await expectLater(
        fixture.coordinator.exit(cleanup: fixture.cleanup),
        throwsStateError,
      );
      expect(fixture.calls, [
        'closing:true',
        'begin',
        'stop',
        'abort:7',
        'closing:false',
      ]);
      fixture.stopResult = true;
      await fixture.coordinator.exit(cleanup: fixture.cleanup);
      expect(fixture.calls.where((call) => call == 'release'), hasLength(1));
    },
  );

  for (final failRelease in [false, true]) {
    test(
      'failure after terminal barrier finishes all teardown release=$failRelease',
      () async {
        final fixture = _ExitFixture()
          ..cleanupFails = !failRelease
          ..releaseFails = failRelease;
        await expectLater(
          fixture.coordinator.exit(cleanup: fixture.cleanup),
          throwsStateError,
        );
        expect(fixture.calls, [
          'closing:true',
          'begin',
          'stop',
          'cleanup',
          'release',
          'core',
          'complete:7',
        ]);
        expect(fixture.calls, isNot(contains('closing:false')));
        expect(fixture.calls, isNot(contains('abort:7')));
      },
    );
  }
}
