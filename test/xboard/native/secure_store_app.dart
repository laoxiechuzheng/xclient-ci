import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:fl_clash/ui/shape.dart';
import 'package:fl_clash/ui/typography.dart';
import 'package:fl_clash/xboard/core/auth/secure_store.dart';
import 'package:fl_clash/xboard/core/client_info.dart';
import 'package:fl_clash/xboard/core/log.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:window/window.dart';

class NativeStoreQaResult {
  final checks = <String, bool>{};
  final errors = <String>{};
  bool get success =>
      checks.isNotEmpty &&
      checks.values.every((value) => value) &&
      errors.isEmpty;
  Map<String, Object> get json => {
    'success': success,
    ...checks,
    'error_classes': errors.toList()..sort(),
  };
}

class _QaFailure implements Exception {
  final String code;
  const _QaFailure(this.code);
}

void _require(bool value, String code) {
  if (!value) throw _QaFailure(code);
}

String _classify(Object error) => switch (error) {
  _QaFailure(:final code) => code,
  TimeoutException() => 'operation_timeout',
  MissingPluginException() => 'plugin_missing',
  PlatformException() => 'native_storage_error',
  FormatException() => 'identity_invalid',
  FileSystemException() => 'receipt_or_capture_io_error',
  _ => 'unexpected_error',
};

Future<NativeStoreQaResult> runNativeStoreQa({
  required String nonce,
  required SecureStore Function(String) storeFor,
  required Future<ClientInfo> Function() detect,
  required String version,
  required String build,
}) async {
  final result = NativeStoreQaResult();
  for (final key in [
    'canonical_identity',
    'write_read',
    'reopen',
    'replace',
    'namespace_isolation',
    'individual_delete',
    'cleanup_attempted',
    'cleanup_verified',
  ]) {
    result.checks[key] = false;
  }
  final brands = [
    for (final suffix in ['a', 'b', 'c']) 'q${nonce.substring(0, 12)}$suffix',
  ];
  final stores = [for (final brand in brands) storeFor(brand)];
  final owned = <int>{};
  final key = 'qa.$nonce.sample';
  final values = [
    for (final suffix in ['a', 'b', 'c']) 'synthetic-$nonce-$suffix',
  ];
  var readFailed = false;
  var timedOut = false;
  final previousLog = xcLogSink;
  xcLogSink = (message, {required warn}) {
    if (message.contains('secure read failed')) readFailed = true;
  };
  Future<T> bounded<T>(Future<T> value) async {
    try {
      return await value.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      timedOut = true;
      rethrow;
    }
  }

  Future<String?> read(SecureStore store) async {
    final value = await bounded(store.read(key));
    _require(!readFailed, 'native_read_failed');
    return value;
  }

  try {
    final identity = await bounded(detect());
    _require(
      identity.appVersion == version &&
          identity.build == build &&
          version.isNotEmpty &&
          build.isNotEmpty,
      'canonical_identity_mismatch',
    );
    result.checks['canonical_identity'] = true;
    for (var i = 0; i < stores.length; i++) {
      _require(await read(stores[i]) == null, 'synthetic_key_collision');
      owned.add(i);
    }
    await bounded(stores[0].write(key, values[0]));
    _require(await read(stores[0]) == values[0], 'write_read_mismatch');
    result.checks['write_read'] = true;
    _require(await read(storeFor(brands[0])) == values[0], 'reopen_mismatch');
    result.checks['reopen'] = true;
    _require(
      await read(stores[1]) == null && await read(stores[2]) == null,
      'namespace_leak',
    );
    for (var i = 1; i < stores.length; i++) {
      await bounded(stores[i].write(key, values[i]));
    }
    for (var i = 0; i < stores.length; i++) {
      _require(await read(stores[i]) == values[i], 'namespace_leak');
    }
    result.checks['namespace_isolation'] = true;
    await bounded(stores[0].write(key, 'synthetic-$nonce-replaced'));
    _require(
      await read(stores[0]) == 'synthetic-$nonce-replaced' &&
          await read(stores[1]) == values[1] &&
          await read(stores[2]) == values[2],
      'replacement_mismatch',
    );
    result.checks['replace'] = true;
    await bounded(stores[0].delete(key));
    _require(
      await read(stores[0]) == null &&
          await read(stores[1]) == values[1] &&
          await read(stores[2]) == values[2],
      'individual_delete_mismatch',
    );
    result.checks['individual_delete'] = true;
  } catch (error) {
    result.errors.add(_classify(error));
  } finally {
    result.checks['cleanup_attempted'] = true;
    var clean = owned.length == stores.length;
    for (final index in owned) {
      try {
        await bounded(stores[index].delete(key));
      } catch (error) {
        clean = false;
        result.errors.add(_classify(error));
      }
    }
    for (final index in owned) {
      try {
        clean = (await read(stores[index]) == null) && clean;
      } catch (error) {
        clean = false;
        result.errors.add(_classify(error));
      }
    }
    result.checks['cleanup_verified'] = clean && !timedOut;
    xcLogSink = previousLog;
  }
  return result;
}

Future<Directory> _ciOutput() async {
  const safe = bool.fromEnvironment('SAFE_MODE');
  const enabled = bool.fromEnvironment('XC_NATIVE_STORE_QA');
  const brand = String.fromEnvironment('XC_BRAND_ID');
  const nonce = String.fromEnvironment('XC_NATIVE_STORE_QA_NONCE');
  const job = String.fromEnvironment('XC_NATIVE_STORE_QA_JOB');
  const output = String.fromEnvironment('XC_NATIVE_STORE_QA_OUTPUT');
  final env = Platform.environment;
  _require(
    safe && enabled && brand == 'example' && env['GITHUB_ACTIONS'] == 'true',
    'qa_compile_or_ci_gate_rejected',
  );
  _require(Platform.isWindows || Platform.isMacOS, 'native_desktop_required');
  _require(
    env['RUNNER_OS'] == (Platform.isWindows ? 'Windows' : 'macOS'),
    'runner_platform_mismatch',
  );
  _require(
    nonce.length == 32 && RegExp(r'^[a-f0-9]{32}$').hasMatch(nonce),
    'nonce_invalid',
  );
  final identity =
      '${env['GITHUB_RUN_ID']}:${env['GITHUB_RUN_ATTEMPT']}:${env['GITHUB_JOB']}:${env['GITHUB_SHA']}';
  _require(
    job == identity && env['XCLIENT_NATIVE_STORE_QA_OUTPUT'] == output,
    'job_or_output_mismatch',
  );
  final workspace = await Directory(
    env['GITHUB_WORKSPACE'] ?? '',
  ).resolveSymbolicLinks();
  final directory = Directory(output);
  _require(
    p.isWithin(p.join(workspace, 'out'), output) &&
        await FileSystemEntity.type(output, followLinks: false) ==
            FileSystemEntityType.directory,
    'output_scope_rejected',
  );
  _require(
    p.equals(await directory.resolveSymbolicLinks(), output),
    'output_symlink_rejected',
  );
  _require(
    await File(p.join(output, '.native-store-owned')).readAsString() == nonce,
    'output_marker_mismatch',
  );
  final launch = File(p.join(output, 'launch.json'));
  for (var i = 0; i < 50 && !await launch.exists(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  _require(
    await FileSystemEntity.type(launch.path, followLinks: false) ==
        FileSystemEntityType.file,
    'launcher_receipt_missing',
  );
  final data = jsonDecode(await launch.readAsString()) as Map;
  _require(
    data['nonce'] == nonce && data['job'] == job && data['pid'] == pid,
    'launcher_owner_mismatch',
  );
  _require(
    p.equals(
      data['executable'] as String,
      await File(Platform.resolvedExecutable).resolveSymbolicLinks(),
    ),
    'launcher_executable_mismatch',
  );
  return directory;
}

class NativeStoreQaView extends StatelessWidget {
  const NativeStoreQaView({
    super.key,
    required this.state,
    required this.boundaryKey,
  });
  final ValueListenable<NativeStoreQaResult> state;
  final GlobalKey boundaryKey;
  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(fontFamily: 'Arial').withAppTypography.withAppShapes,
    home: RepaintBoundary(
      key: boundaryKey,
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ValueListenableBuilder(
                valueListenable: state,
                builder: (context, result, _) => ListView(
                  shrinkWrap: true,
                  children: [
                    Text(
                      'XClient native storage QA',
                      style: AppTextStyle.title1.of(context),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Synthetic values only · Core and VPN are never started',
                    ),
                    const SizedBox(height: 16),
                    for (final check in result.checks.entries)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Text(
                          '${check.value ? "PASS" : "WAIT / FAIL"}  ${check.key}',
                        ),
                      ),
                    for (final error in result.errors) Text(error),
                    const SizedBox(height: 12),
                    Text(
                      result.success
                          ? 'All native checks passed'
                          : 'Waiting or failed; see safe receipt',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = ValueNotifier(NativeStoreQaResult());
  final boundary = GlobalKey();
  runApp(NativeStoreQaView(state: state, boundaryKey: boundary));
  Directory? output;
  var result = NativeStoreQaResult();
  try {
    output = await _ciOutput();
    final window = DesktopWindow.instance;
    await window.ensureInitialized().timeout(const Duration(seconds: 5));
    await window.setSize(const Size(900, 650));
    await window.show();
    _require(await window.isVisible(), 'native_window_not_visible');
    result = await runNativeStoreQa(
      nonce: const String.fromEnvironment('XC_NATIVE_STORE_QA_NONCE'),
      storeFor: (brand) => PlatformSecureStore(brandId: brand),
      detect: ClientInfo.detect,
      version: const String.fromEnvironment('XC_VERSION_NAME'),
      build: const String.fromEnvironment('XC_BUILD_NUMBER'),
    );
    result.checks['native_window_visible'] = true;
  } catch (error) {
    result.errors.add(_classify(error));
  }
  state.value = result;
  if (output != null) {
    try {
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 5),
      );
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final frame = await render
          .toImage(pixelRatio: 1)
          .timeout(const Duration(seconds: 5));
      final bytes = await frame.toByteData(format: ui.ImageByteFormat.png);
      _require(
        bytes != null && frame.width >= 300 && frame.height >= 200,
        'frame_invalid',
      );
      await File(
        p.join(output.path, 'qa.png'),
      ).writeAsBytes(bytes!.buffer.asUint8List(), flush: true);
      frame.dispose();
      result.checks['native_flutter_frame_saved'] = true;
    } catch (error) {
      result.errors.add(_classify(error));
    }
    try {
      final target = File(p.join(output.path, 'result.json'));
      _require(!await target.exists(), 'result_already_exists');
      final temporary = File('${target.path}.next');
      await temporary.writeAsString(jsonEncode(result.json), flush: true);
      await temporary.rename(target.path);
    } catch (error) {
      result.errors.add(_classify(error));
    }
  }
  stdout.writeln(jsonEncode(result.json));
  exit(result.success ? 0 : 1);
}
