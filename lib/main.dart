import 'dart:async';
import 'dart:io';

import 'package:fl_clash/enum/enum.dart';
import 'package:fl_clash/pages/error.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:rust_api/rust_api.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'application.dart';
import 'bootstrap.dart';
import 'common/app_data.dart';
import 'common/common.dart';
import 'common/preferences_store.dart';
import 'common/window.dart';

void main(List<String> args) {
  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      _startupStage('bindingReady');
      if (Platform.isWindows || Platform.isLinux) {
        SharedPreferencesStorePlatform.instance = AtomicFilePreferencesStore(
          appPath.sharedPreferencesPath,
        );
      }
      if (Platform.isLinux) {
        linkManager.seedInitialLink(args);
      }
      FlutterError.onError = (details) {
        Future.microtask(() {
          commonPrint.log(
            'exception: ${details.exception} stack: ${details.stack}',
            logLevel: LogLevel.warning,
          );
        });
      };
      try {
        final rustObservation = _observeRustStartup();
        try {
          await RustLib.init();
        } finally {
          rustObservation?.cancel();
        }
        _startupStage('rustReady');
        final version = await system.init();
        _startupStage('platformReady');
        final container = await bootstrap.init(version);
        _startupStage('bootstrapReady');
        await FlClashHttpOverrides.trustCoreRoots();
        _startupStage('trustReady');
        HttpOverrides.global = FlClashHttpOverrides(container);
        request.attach(container.read);
        runApp(
          UncontrolledProviderScope(
            container: container,
            child: const Application(),
          ),
        );
        _startupStage('runApp');
      } catch (e, s) {
        _startupStage('initError');
        runApp(
          InitErrorApp(
            error: e,
            stack: s,
            onClearData: clearAppData,
            onExit: _exitAfterInitFailure,
          ),
        );
        unawaited(window?.showInitFailure(onExit: _exitAfterInitFailure));
      }
    },
    (error, stack) {
      _startupStage('zoneError');
      FlutterError.reportError(
        FlutterErrorDetails(exception: error, stack: stack),
      );
    },
  );
}

Timer? _observeRustStartup() {
  if (const bool.fromEnvironment('SAFE_MODE') &&
      const bool.fromEnvironment('XC_STARTUP_QA')) {
    return Timer(const Duration(seconds: 2), () {
      _startupStage(
        isRustLibInitialized ? 'rustEntrypointReady' : 'rustEntrypointPending',
      );
    });
  }
  return null;
}

void _startupStage(String stage) {
  if (const bool.fromEnvironment('SAFE_MODE') &&
      const bool.fromEnvironment('XC_STARTUP_QA')) {
    debugPrint('[xclient-startup] $stage');
  }
}

Future<void> _exitAfterInitFailure() async {
  await system.exit();
  window?.forceExit();
}
