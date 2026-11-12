#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import socket
import struct
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import android_lifecycle_probe as lifecycle_probe
import android_startup_probe as startup_probe

ROOT = Path(__file__).resolve().parents[3]
IMAGE = 'system-images;android-35;google_apis;x86_64'
PACKAGE = lifecycle_probe.PACKAGE
ACTIVITY = 'com.follow.clash.MainActivity'
PRODUCER_JOB = 'android-apk'
CONSUMER_JOB = 'android-emulator'
TRANSFER_CHECKS = {'safe_mode': True, 'native_hooks_enabled': True, 'apk_metadata': True, 'native_elf_abi': True}
MAX_APK_BYTES = 512 * 1024 * 1024
EMULATOR_IMAGES = {'launcher': 'emulator/emulator', 'qemuX64': 'emulator/qemu/linux-x86_64/qemu-system-x86_64', 'qemuX64Headless': 'emulator/qemu/linux-x86_64/qemu-system-x86_64-headless'}
SOURCE_FILES = ('lib/main.dart', 'lib/common/constant.dart', 'android/app/build.gradle.kts', 'android/app/src/main/AndroidManifest.xml', 'pubspec.yaml', 'pubspec.lock', 'tool/xclient/ci/android_emulator_smoke.py', 'tool/xclient/ci/android_lifecycle_probe.py', 'tool/xclient/ci/android_startup_probe.py', 'android/app/src/main/kotlin/com/follow/clash/MainActivity.kt', 'android/app/src/main/kotlin/com/follow/clash/ManagedFlutterEngineOwner.kt', 'android/app/src/main/kotlin/com/follow/clash/ManagedEngineLifecycle.kt', 'android/app/src/main/kotlin/com/follow/clash/ServiceState.kt', 'lib/bootstrap.dart', 'lib/xboard/lifecycle.dart', 'lib/providers/actions/system.dart', 'lib/xboard/ui/common/exit_action.dart', 'lib/xboard/ui/login.dart', 'lib/xboard/app_host.dart', 'tool/xclient/ci/android_update_component.py', 'test/xboard/native/android_update_app.dart', 'test/xboard/native/android_update_contract.dart', 'test/xboard/native/update_store_observer.dart', 'test/xboard/native/update_qa_contract.dart', 'lib/xboard/update/install/android_installer.dart', 'lib/xboard/update/install/installer.dart', 'lib/xboard/core/auth/secure_store.dart', 'lib/xboard/core/client_info.dart', 'android/app/src/main/kotlin/com/follow/clash/xclient/UpdatePlugin.kt')


if __name__ == '__main__':
    sys.modules['android_emulator_smoke'] = sys.modules[__name__]


class Refused(Exception):
    def __init__(self, code, exit_code=None, error_class=None):
        super().__init__(code)
        self.exit_code, self.error_class = exit_code, error_class


def require(condition, code):
    if not condition:
        raise Refused(code)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    require(not path.exists() and not path.is_symlink(), 'new_receipt_required')
    with path.open('x', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, sort_keys=True)


def ci_identity():
    env = os.environ
    require(env.get('GITHUB_ACTIONS') == 'true' and env.get('RUNNER_ENVIRONMENT') == 'github-hosted', 'github_hosted_ci_required')
    require(sys.platform == 'linux' and env.get('RUNNER_OS') == 'Linux', 'linux_runner_required')
    require(env.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and env.get('XCLIENT_ANDROID_QA') == 'official-safe-x86_64-v1', 'manual_safe_job_required')
    require(Path(env.get('GITHUB_WORKSPACE', '')).resolve() == ROOT, 'workspace_mismatch')
    require(all(re.fullmatch(pattern, env.get(key, '')) for key, pattern in [('GITHUB_RUN_ID', r'\d+'), ('GITHUB_RUN_ATTEMPT', r'\d+'), ('GITHUB_JOB', r'[A-Za-z0-9_-]+'), ('GITHUB_SHA', r'[a-fA-F0-9]{40}')]), 'job_identity_required')
    return ':'.join(env[key] for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'GITHUB_SHA'))


def scoped(path):
    path = Path(path).absolute()
    require(path.resolve() == path and path.is_relative_to(ROOT / 'out') and path != ROOT / 'out', 'output_scope_rejected')
    return path


def sources():
    return {name: sha(ROOT / name) for name in SOURCE_FILES}


def apk_filename(mode):
    require(mode in ('debug', 'profile'), 'safe_build_mode_required')
    return 'app-' + mode + '.apk'


def package_for_mode(mode):
    apk_filename(mode)
    return PACKAGE if mode == 'debug' else lifecycle_probe.PROFILE_PACKAGE


def qa_purpose(state=None):
    purpose = os.environ.get('XCLIENT_ANDROID_QA_PURPOSE', 'lifecycle')
    require(purpose in ('lifecycle', 'update-component'), 'known_android_purpose_required')
    if state is not None:
        require(state.get('purpose', 'lifecycle') == purpose, 'prepared_purpose_mismatch')
    return purpose


def load_state(file):
    job = ci_identity()
    file = scoped(file)
    state = json.loads(file.read_text(encoding='utf-8'))
    apk_filename(state['build_mode'])
    purpose = qa_purpose(state)
    require(purpose != 'update-component' or state['build_mode'] == 'profile', 'component_profile_purpose_required')
    output = scoped(state['output'])
    require(file == output / 'private/state.json' and state['job'] == job and state['image'] == IMAGE, 'prepared_identity_mismatch')
    require(re.fullmatch(r'[a-f0-9]{32}', state['nonce']) and (output / '.android-emulator-owned').read_text(encoding='utf-8') == state['nonce'], 'owned_marker_mismatch')
    require(0 <= time.time_ns() - state['prepared_ns'] <= 10800 * 10**9, 'stale_build_marker')
    require(sources() == state['sources'] and sha(output / 'private/defines.json') == state['defines_sha256'], 'prepared_source_changed')
    return state, output


def sdk_tool(sdk, relative):
    path = sdk / relative
    require(path.is_file() and path.resolve().is_relative_to(sdk), 'official_sdk_tool_missing')
    return path.resolve()


def snapshot_emulator_images(sdk):
    images = {}
    for name, relative in EMULATOR_IMAGES.items():
        path = sdk / relative
        require(not path.is_symlink() and (not path.exists() or (path.is_file() and path.resolve() == path)), 'regular_official_emulator_required')
        images[name] = sha(path) if path.is_file() else None
    require(images['launcher'] is not None, 'official_emulator_launcher_required')
    return images


def command(argv, *, env=None, timeout=60, data=None):
    result = subprocess.run([str(value) for value in argv], cwd=ROOT, env=env, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout)
    if result.returncode != 0:
        raise Refused('owned_command_failed', result.returncode)
    return result.stdout


def prepare(args):
    job = ci_identity()
    require(os.environ.get('GITHUB_JOB') in (PRODUCER_JOB, CONSUMER_JOB), 'android_qa_role_required')
    purpose = qa_purpose()
    require(getattr(args, 'purpose', 'lifecycle') == purpose, 'prepared_purpose_mismatch')
    require(purpose != 'update-component' or args.build_mode == 'profile', 'component_profile_purpose_required')
    output = scoped(args.output)
    require(not output.exists(), 'new_output_required')
    sdk = Path(os.environ.get('ANDROID_HOME', '')).resolve()
    require(sdk.is_dir() and sdk == Path(os.environ.get('ANDROID_SDK_ROOT', str(sdk))).resolve(), 'sdk_root_mismatch')
    sdk_tool(sdk, 'cmdline-tools/latest/bin/sdkmanager')
    defines = json.loads((ROOT / 'xclient_defines.json').read_text(encoding='utf-8'))
    require(defines.get('XC_BRAND_ID') == 'example' and defines.get('XC_VERSION_NAME') == '1.0.0-pre.1' and defines.get('XC_BUILD_NUMBER') == '10000401', 'example_canonical_identity_required')
    require((ROOT / 'pubspec.yaml').read_text().count('build_assets: true') == 2, 'native_build_hooks_required')
    defines.update(SAFE_MODE='true', APP_ENV='dev', XC_STARTUP_QA='true')
    nonce = secrets.token_hex(16)
    output.mkdir(parents=True, mode=0o700)
    for name in ('private', 'receipts', 'private/avd', 'private/android-user'):
        (output / name).mkdir(mode=0o700)
    (output / '.android-emulator-owned').write_text(nonce, encoding='utf-8')
    write_json(output / 'private/defines.json', defines)
    write_json(output / 'private/state.json', {'job': job, 'purpose': purpose, 'build_mode': args.build_mode, 'output': str(output), 'sdk': str(sdk), 'image': IMAGE, 'nonce': nonce, 'prepared_ns': time.time_ns(), 'sources': sources(), 'defines_sha256': sha(output / 'private/defines.json')})
    print(json.dumps({'prepared': True, 'image': IMAGE}))


def private_env(output):
    return dict(os.environ, ANDROID_AVD_HOME=str(output / 'private/avd'), ANDROID_USER_HOME=str(output / 'private/android-user'), ANDROID_EMULATOR_HOME=str(output / 'private/android-user'), ADB_VENDOR_KEYS=str(output / 'private/android-user'))


def sdk_failure_class(data):
    text = data.decode('utf-8', errors='replace').lower()
    for fragments, name in [(('no space left', 'not enough space'), 'storage'), (('license not accepted', 'licenses have not been accepted'), 'license'), (('failed to find package', 'package not found'), 'packageUnavailable'), (('permission denied',), 'permissions'), (('failed to download', 'could not resolve', 'connection refused', 'connection timed out', 'sslhandshakeexception'), 'network')]:
        if any(fragment in text for fragment in fragments):
            return name
    return 'unknown'


def install_tools(args):
    state, output = load_state(args.state)
    require(os.environ.get('GITHUB_JOB') == CONSUMER_JOB, 'artifact_consumer_required')
    built = json.loads((output / 'private/build.json').read_text(encoding='utf-8'))
    validate_staged_apk(state, output, built)
    sdk = Path(state['sdk'])
    env = private_env(output)
    manager = sdk_tool(sdk, 'cmdline-tools/latest/bin/sdkmanager')
    result = subprocess.run([str(manager), '--sdk_root=' + str(sdk), '--install', 'emulator', IMAGE], cwd=ROOT, env=env, timeout=900, input=b'y\n' * 40, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode != 0:
        raise Refused('official_sdkmanager_install_failed', result.returncode, sdk_failure_class(result.stdout + result.stderr))
    emulator = sdk_tool(sdk, 'emulator/emulator')
    metadata = sdk / 'system-images/android-35/google_apis/x86_64/source.properties'
    properties = metadata.read_text(encoding='utf-8')
    require(re.search(r'^AndroidVersion.ApiLevel\s*=\s*35\s*$', properties, re.M) and re.search(r'^SystemImage.Abi\s*=\s*x86_64\s*$', properties, re.M), 'official_image_identity_mismatch')
    package = (sdk / 'emulator/source.properties').read_text(encoding='utf-8')
    revision = re.search(r'^Pkg\.Revision\s*=\s*([0-9]+(?:\.[0-9]+){1,3})\s*$', package, re.M)
    write_json(output / 'private/tools.json', {'emulator': str(emulator), 'emulator_sha256': sha(emulator), 'emulator_images': snapshot_emulator_images(sdk), 'emulator_package_revision': revision.group(1) if revision else 'unknown', 'image_properties_sha256': sha(metadata)})
    print(json.dumps({'official_tools_installed': True, 'image': IMAGE}))


def validate_badging(text, mode='debug'):
    require(re.search(r"^package: name='" + re.escape(package_for_mode(mode)) + r"' versionCode='10000401'", text, re.M), 'apk_example_identity_required')
    require(re.search(r"^launchable-activity: name='com\.follow\.clash\.MainActivity'", text, re.M), 'apk_activity_mismatch')
    require(re.search(r'^application-debuggable\s*$', text, re.M), 'apk_debug_required')


def apk_metadata(text, mode):
    require(len(text) <= 128 * 1024, 'bounded_apk_metadata_required')
    matches = re.findall(r"^package: name='([^'\r\n]{1,256})' versionCode='(\d{1,10})'", text, re.M)
    package, version = matches[0] if len(matches) == 1 else ('unknown', None)
    return {'build_mode': mode, 'expected_package': package_for_mode(mode), 'package': package if package in lifecycle_probe.SAFE_PACKAGES else 'other', 'version_code': int(version) if version is not None else None, 'debuggable': re.search(r'^application-debuggable\s*$', text, re.M) is not None, 'expected_activity': re.search(r"^launchable-activity: name='com\.follow\.clash\.MainActivity'", text, re.M) is not None}


def validate_apk(path, mode='debug'):
    apk_filename(mode)
    with zipfile.ZipFile(path) as archive:
        entries = set(archive.namelist())
        require(('assets/flutter_assets/kernel_blob.bin' in entries) == (mode == 'debug') and ('lib/x86_64/libapp.so' in entries) == (mode == 'profile'), 'expected_dart_payload_required')
        for library in ('libflutter.so', 'libclash.so') + (('libapp.so',) if mode == 'profile' else ()):
            require('lib/x86_64/' + library in entries, 'x64_runtime_library_required')
            with archive.open('lib/x86_64/' + library) as binary:
                header = binary.read(20)
                require(header[:6] == b'\x7fELF\x02\x01' and len(header) == 20 and struct.unpack('<H', header[18:20])[0] == 62, 'actual_x64_elf_required')
        require(all(not entry.startswith(('lib/arm64-v8a/libflutter.so', 'lib/armeabi-v7a/libflutter.so')) for entry in entries), 'single_x64_flutter_target_required')


def aapt_tool(sdk):
    versions = [path for path in (sdk / 'build-tools').iterdir() if re.fullmatch(r'\d+\.\d+\.\d+', path.name) and (path / 'aapt2').is_file()]
    require(bool(versions), 'build_tools_required')
    return sdk_tool(sdk, str(max(versions, key=lambda path: tuple(map(int, path.name.split('.')))).relative_to(sdk) / 'aapt2'))


def stage_apk(state, output, source, *, started_ns):
    require(source == ROOT / 'build/app/outputs/flutter-apk' / apk_filename(state['build_mode']) and source.is_file() and source.resolve() == source and source.stat().st_mtime_ns > started_ns, 'fresh_build_apk_required')
    destination = scoped(output / 'private' / apk_filename(state['build_mode']))
    require(not destination.exists() and not destination.is_symlink(), 'new_staged_apk_required')
    source_hash = sha(source)
    with source.open('rb') as reader, destination.open('xb') as writer:
        shutil.copyfileobj(reader, writer, 1024 * 1024)
    destination.chmod(0o600)
    require(sha(destination) == source_hash and sha(source) == source_hash, 'staged_apk_hash_mismatch')
    now = time.time_ns()
    return {'origin': 'local-build', 'job': state['job'], 'nonce': state['nonce'], 'source_hashes': state['sources'], 'source_apk': str(source), 'source_apk_sha256': source_hash, 'apk': str(destination), 'apk_sha256': source_hash, 'apk_size': destination.stat().st_size, 'built_ns': now, 'staged_ns': now, 'defines_sha256': state['defines_sha256'], 'native_hooks_enabled': True, 'target': 'android-x64', 'safe_mode': True, 'build_mode': state['build_mode']}


def validate_staged_apk(state, output, built):
    if state.get('purpose', 'lifecycle') == 'update-component':
        import android_update_component
        return android_update_component.validate_staged(state, output, built)
    apk = scoped(output / 'private' / apk_filename(state['build_mode']))
    require(built['job'] == state['job'] and built['nonce'] == state['nonce'] and built['source_hashes'] == state['sources'], 'staged_apk_owner_mismatch')
    require(built['apk'] == str(apk) and built['defines_sha256'] == state['defines_sha256'] and built['native_hooks_enabled'] is True and built['safe_mode'] is True and built['target'] == 'android-x64' and built['build_mode'] == state['build_mode'], 'safe_build_receipt_mismatch')
    require(state['prepared_ns'] <= built['staged_ns'] <= time.time_ns() and 0 < built['built_ns'] <= built['staged_ns'], 'build_timestamp_mismatch')
    if built.get('origin') == 'local-build':
        require(built['source_apk'] == str(ROOT / 'build/app/outputs/flutter-apk' / apk_filename(state['build_mode'])) and built['built_ns'] >= state['prepared_ns'], 'staged_apk_owner_mismatch')
    elif built.get('origin') == 'same-run-artifact':
        require(os.environ.get('GITHUB_JOB') == CONSUMER_JOB and built['source_apk'] == str(output / 'incoming' / apk_filename(state['build_mode'])), 'artifact_consumer_required')
        validate_provenance(state, built['provenance'])
        require(built['artifact_id'] == artifact_id() and built['built_ns'] == built['provenance']['built_ns'] and built['apk_sha256'] == built['provenance']['apk_sha256'] and built['apk_size'] == built['provenance']['apk_size'], 'artifact_build_binding_mismatch')
    else:
        raise Refused('known_build_origin_required')
    require(apk.is_file() and not apk.is_symlink() and apk.stat().st_size == built['apk_size'] and sha(apk) == built['apk_sha256'] == built['source_apk_sha256'], 'staged_apk_hash_mismatch')
    validate_apk(apk, state['build_mode'])
    return apk


def transfer_context():
    fields = {'repository': 'GITHUB_REPOSITORY', 'run_id': 'GITHUB_RUN_ID', 'run_attempt': 'GITHUB_RUN_ATTEMPT', 'sha': 'GITHUB_SHA'}
    context = {key: os.environ.get(variable, '') for key, variable in fields.items()}
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', context['repository']) and re.fullmatch(r'\d+', context['run_id']) and re.fullmatch(r'\d+', context['run_attempt']) and re.fullmatch(r'[a-fA-F0-9]{40}', context['sha']), 'artifact_run_identity_required')
    return context


def artifact_id():
    value = os.environ.get('XCLIENT_ANDROID_APK_ARTIFACT_ID', '')
    require(re.fullmatch(r'[1-9]\d*', value) is not None, 'producer_artifact_id_required')
    return value


def validate_provenance(state, receipt):
    fields = {'schema', 'repository', 'run_id', 'run_attempt', 'sha', 'producer_job', 'source_hashes', 'defines_sha256', 'apk_sha256', 'apk_size', 'built_ns', 'brand', 'version', 'build_number', 'package', 'target', 'build_mode', 'checks'}
    require(isinstance(receipt, dict) and set(receipt) == fields and type(receipt['schema']) is int and receipt['schema'] == 2, 'artifact_receipt_schema_required')
    require(all(receipt[key] == value for key, value in transfer_context().items()) and receipt['producer_job'] == PRODUCER_JOB, 'same_run_producer_required')
    require(receipt['source_hashes'] == state['sources'] and receipt['defines_sha256'] == state['defines_sha256'], 'artifact_source_or_defines_mismatch')
    require(receipt['brand'] == 'example' and receipt['version'] == '1.0.0-pre.1' and receipt['build_number'] == '10000401' and receipt['package'] == package_for_mode(state['build_mode']) and receipt['target'] == 'android-x64' and receipt['build_mode'] == state['build_mode'], 'artifact_example_identity_required')
    require(receipt['checks'] == TRANSFER_CHECKS and all(value is True for value in receipt['checks'].values()), 'artifact_build_checks_required')
    require(isinstance(receipt['apk_sha256'], str) and re.fullmatch(r'[a-f0-9]{64}', receipt['apk_sha256']) and type(receipt['apk_size']) is int and 0 < receipt['apk_size'] <= MAX_APK_BYTES and type(receipt['built_ns']) is int and 0 < receipt['built_ns'] <= time.time_ns(), 'artifact_hash_size_time_required')


def transfer_files(directory, mode):
    filename = apk_filename(mode)
    directory = scoped(directory)
    require(directory.is_dir() and {path.name for path in directory.iterdir()} == {filename, 'build-receipt.json'}, 'artifact_file_allowlist_required')
    require(all(path.is_file() and not path.is_symlink() and path.resolve() == path for path in directory.iterdir()), 'regular_artifact_files_required')
    require((directory / 'build-receipt.json').stat().st_size <= 65536 and (directory / filename).stat().st_size <= MAX_APK_BYTES, 'artifact_file_size_rejected')
    return directory


def export_apk(args):
    state, output = load_state(args.state)
    require(qa_purpose(state) == 'lifecycle', 'lifecycle_build_purpose_required')
    require(os.environ.get('GITHUB_JOB') == PRODUCER_JOB, 'artifact_producer_required')
    built = json.loads((output / 'private/build.json').read_text(encoding='utf-8'))
    source = validate_staged_apk(state, output, built)
    require(built['origin'] == 'local-build', 'native_build_export_required')
    receipt = {'schema': 2, 'build_mode': state['build_mode'], **transfer_context(), 'producer_job': PRODUCER_JOB, 'source_hashes': state['sources'], 'defines_sha256': state['defines_sha256'], 'apk_sha256': built['apk_sha256'], 'apk_size': built['apk_size'], 'built_ns': built['built_ns'], 'brand': 'example', 'version': '1.0.0-pre.1', 'build_number': '10000401', 'package': package_for_mode(state['build_mode']), 'target': 'android-x64', 'checks': dict(TRANSFER_CHECKS)}
    validate_provenance(state, receipt)
    exported = scoped(output / 'export')
    require(not exported.exists(), 'new_export_directory_required')
    exported.mkdir(mode=0o700)
    with source.open('rb') as reader, (exported / apk_filename(state['build_mode'])).open('xb') as writer:
        shutil.copyfileobj(reader, writer, 1024 * 1024)
    require(sha(exported / apk_filename(state['build_mode'])) == built['apk_sha256'] and sha(source) == built['apk_sha256'], 'exported_apk_hash_mismatch')
    write_json(exported / 'build-receipt.json', receipt)
    transfer_files(exported, state['build_mode'])
    print(json.dumps({'exported': True, 'apk_sha256': built['apk_sha256']}))


def import_apk(args):
    state, output = load_state(args.state)
    require(qa_purpose(state) == 'lifecycle', 'lifecycle_build_purpose_required')
    require(os.environ.get('GITHUB_JOB') == CONSUMER_JOB, 'artifact_consumer_required')
    identity = artifact_id()
    incoming = transfer_files(output / 'incoming', state['build_mode'])
    receipt = json.loads((incoming / 'build-receipt.json').read_text(encoding='utf-8'))
    validate_provenance(state, receipt)
    source = incoming / apk_filename(state['build_mode'])
    require(source.stat().st_size == receipt['apk_size'] and sha(source) == receipt['apk_sha256'], 'artifact_apk_hash_mismatch')
    validate_apk(source, state['build_mode'])
    destination = scoped(output / 'private' / apk_filename(state['build_mode']))
    require(not destination.exists() and not destination.is_symlink() and not (output / 'private/build.json').exists(), 'new_staged_apk_required')
    with source.open('rb') as reader, destination.open('xb') as writer:
        shutil.copyfileobj(reader, writer, 1024 * 1024)
    destination.chmod(0o600)
    require(sha(destination) == receipt['apk_sha256'] and sha(source) == receipt['apk_sha256'], 'imported_apk_hash_mismatch')
    built = {'origin': 'same-run-artifact', 'artifact_id': identity, 'provenance': receipt, 'job': state['job'], 'nonce': state['nonce'], 'source_hashes': state['sources'], 'source_apk': str(source), 'source_apk_sha256': receipt['apk_sha256'], 'apk': str(destination), 'apk_sha256': receipt['apk_sha256'], 'apk_size': receipt['apk_size'], 'built_ns': receipt['built_ns'], 'staged_ns': time.time_ns(), 'defines_sha256': state['defines_sha256'], 'native_hooks_enabled': True, 'target': 'android-x64', 'safe_mode': True, 'build_mode': state['build_mode']}
    validate_staged_apk(state, output, built)
    write_json(output / 'private/build.json', built)
    write_json(output / 'receipts/build-origin.json', {'artifact_id': identity, **receipt})
    print(json.dumps({'imported': True, 'same_run_producer': True, 'apk_sha256': receipt['apk_sha256']}))


def build(args):
    state, output = load_state(args.state)
    require(qa_purpose(state) == 'lifecycle', 'lifecycle_build_purpose_required')
    require(os.environ.get('GITHUB_JOB') == PRODUCER_JOB, 'native_build_producer_required')
    require(os.environ.get('XCLIENT_BRAND') == 'example', 'example_native_brand_required')
    version = json.loads(command(['flutter', '--version', '--machine'], timeout=120))
    require(version.get('frameworkVersion') == '3.47.6' and version.get('dartSdkVersion', '').split()[0] == '3.13.5', 'pinned_flutter_sdk_required')
    started = time.time_ns()
    result = subprocess.run(['flutter', 'build', 'apk', '--' + state['build_mode'], '--target-platform', 'android-x64', '--dart-define-from-file=' + str(output / 'private/defines.json')], cwd=ROOT, timeout=4800)
    require(result.returncode == 0, 'safe_android_build_failed')
    load_state(args.state)
    apk = ROOT / 'build/app/outputs/flutter-apk' / apk_filename(state['build_mode'])
    require(apk.is_file() and apk.resolve() == apk and apk.stat().st_mtime_ns > started, 'fresh_build_apk_required')
    validate_apk(apk, state['build_mode'])
    badging = command([aapt_tool(Path(state['sdk'])), 'dump', 'badging', apk]).decode('utf-8')
    write_json(output / 'receipts/apk-metadata.json', apk_metadata(badging, state['build_mode']))
    validate_badging(badging, state['build_mode'])
    built = stage_apk(state, output, apk, started_ns=started)
    validate_staged_apk(state, output, built)
    write_json(output / 'private/build.json', built)
    print(json.dumps({'safe_x64_build': True, 'owned_apk_staged': True, 'apk_sha256': built['apk_sha256']}))


def process_stat(pid):
    stat = (Path('/proc') / str(pid) / 'stat').read_text()
    fields = stat[stat.rfind(')') + 2:].split()
    return {'pid': pid, 'start': fields[19], 'ppid': int(fields[1])}


def process_identity(pid):
    before = process_stat(pid)
    executable = str((Path('/proc') / str(pid) / 'exe').resolve(strict=True))
    require(process_stat(pid) == before, 'process_birth_changed_during_read')
    return dict(before, exe=executable)


def process_matches(identity):
    try:
        return process_identity(identity['pid']) == identity
    except (OSError, Refused):
        return False


def stop_owned(process, identity, *, verify=None):
    if process is None:
        return True
    if process.poll() is not None:
        return True
    if identity is None or not (verify() if verify else process_matches(identity)):
        return False
    process.terminate()
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        if not (verify() if verify else process_matches(identity)):
            return False
        process.kill()
        process.wait(timeout=10)
    return process.poll() is not None


def emulator_observation(identity, child_pid, birth, images, sdk, parent_pid):
    current_birth = {key: identity[key] for key in ('pid', 'start', 'ppid')}
    birth = current_birth if birth is None else birth
    name = next((name for name, relative in EMULATOR_IMAGES.items() if identity['exe'] == str(sdk / relative)), 'unknown')
    basenames = {Path(relative).name for relative in EMULATOR_IMAGES.values()}
    basename = Path(identity['exe']).name
    hash_matches = False
    if name != 'unknown' and images.get(name) is not None:
        path = sdk / EMULATOR_IMAGES[name]
        try:
            hash_matches = path.is_file() and not path.is_symlink() and path.resolve() == path and sha(path) == images[name]
        except OSError:
            pass
    report = {'image_class': name, 'observed_basename': basename if basename in basenames else 'unknown', 'pid_matches': identity['pid'] == child_pid, 'parent_matches': identity['ppid'] == parent_pid, 'birth_matches': current_birth == birth, 'candidate_hash_matches': hash_matches}
    status = 'verified'
    for condition, failure in ((report['pid_matches'], 'pidMismatch'), (report['parent_matches'], 'parentMismatch'), (report['birth_matches'], 'birthChanged'), (name != 'unknown', 'unknownImage'), (hash_matches, 'imageChanged')):
        if not condition:
            status = failure
            break
    report['status'] = status
    return birth, identity if status == 'verified' else None, report


def observe_emulator(process, birth, images, sdk):
    try:
        return emulator_observation(process_identity(process.pid), process.pid, birth, images, sdk, os.getpid())
    except (OSError, Refused):
        return birth, None, {'status': 'statUnavailable', 'image_class': 'unknown', 'observed_basename': 'unknown', 'pid_matches': False, 'parent_matches': False, 'birth_matches': False, 'candidate_hash_matches': False}


def free_port():
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        return reservation.getsockname()[1]


def require_emulator_ports_free():
    reservations = []
    try:
        for port in (5554, 5555):
            reservation = socket.socket()
            reservations.append(reservation)
            try:
                reservation.bind(('127.0.0.1', port))
            except OSError:
                raise Refused('emulator_ports_already_in_use') from None
    finally:
        for reservation in reservations:
            reservation.close()


def network_hash():
    value = {'interfaces': sorted(socket.if_nameindex()), 'route': Path('/proc/net/route').read_text(), 'proxy': {key: os.environ.get(key) for key in ('http_proxy', 'https_proxy', 'HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY')}}
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


def parse_ui(data):
    require(len(data) < 1024 * 1024, 'ui_capture_too_large')
    start = data.find(b'<?xml')
    require(start >= 0, 'ui_xml_required')
    return ET.fromstring(data[start:])


def ui_label(node):
    return node.get('text', '') or node.get('content-desc', '')


def labelled_nodes(tree, label):
    return [node for node in tree.iter('node') if ui_label(node).strip() == label and node.get('enabled') == 'true']


def visible_anr_owner(tree):
    for node in tree.iter('node'):
        if node.get('package') != 'android' or node.get('class') != 'android.widget.TextView':
            continue
        title = ui_label(node).strip()
        for ending in (" isn't responding", ' is not responding'):
            if title.endswith(ending):
                label = title[:-len(ending)]
                return {'Pixel Launcher': 'launcher', 'ExampleClient': 'example'}.get(label, 'other')
    return None


def launcher_observation(tree, activities, boot_animation):
    require(isinstance(activities, bytes) and len(activities) <= 2 * 1024 * 1024, 'bounded_launcher_observation_required')
    package = 'com.google.android.apps.nexuslauncher'
    resumed = re.search(r'(?:mResumedActivity:|topResumedActivity=)\s*ActivityRecord\{[0-9a-f]+\s+u\d+\s+' + re.escape(package) + r'/[A-Za-z0-9_.$]+\s+t\d+\}', activities.decode('utf-8', errors='replace')) is not None
    return {'boot_animation_stopped': boot_animation.strip() == b'stopped', 'launcher_resumed': resumed, 'launcher_ui_visible': any(node.get('package') == package and node.get('enabled') == 'true' for node in tree.iter('node')), 'visible_anr_owner': visible_anr_owner(tree)}


def anr_observation(activity, logcat, package):
    require(package in lifecycle_probe.SAFE_PACKAGES, 'owned_example_package_required')
    require(isinstance(activity, bytes) and len(activity) <= 2 * 1024 * 1024 and isinstance(logcat, bytes) and len(logcat) <= 256 * 1024, 'bounded_anr_observation_required')
    state, log = activity.decode('utf-8', errors='replace'), logcat.decode('utf-8', errors='replace')
    names = re.findall(r'^ANR in ([A-Za-z0-9_.:]+)(?:\s|$)', log, re.M)
    owners = sorted({('example' if name == package or name.startswith(package + ':') else 'launcher' if name == 'com.google.android.apps.nexuslauncher' else 'system' if name == 'system_server' else 'other') for name in names})
    header = 'ACTIVITY MANAGER LAST ANR (dumpsys activity lastanr)'
    empty = re.fullmatch(re.escape(header) + r'\s+<no ANR has occurred since boot>\s*', state) is not None
    return {'last_anr_query_recognized': state.startswith(header), 'no_anr_since_boot_marker': empty, 'recent_anr_owners': owners, 'input_dispatch_timeout': 'Input dispatching timed out' in state, 'no_focused_window': 'does not have a focused window' in state}


def node_center(node):
    bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', node.get('bounds', ''))
    require(bounds is not None, 'ui_bounds_required')
    left, top, right, bottom = map(int, bounds.groups())
    require(0 <= left < right <= 4096 and 0 <= top < bottom <= 4096, 'ui_bounds_rejected')
    return ((left + right) // 2, (top + bottom) // 2)


def validate_png(data):
    require(24 <= len(data) < 16 * 1024 * 1024 and data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', 'native_png_required')
    width, height = struct.unpack('>II', data[16:24])
    require(300 <= width <= 4096 and 300 <= height <= 4096, 'native_png_size_rejected')
    return {'width': width, 'height': height, 'sha256': hashlib.sha256(data).hexdigest()}


def successful_install(data):
    lines = data.decode('utf-8', errors='replace').strip().splitlines()
    return bool(lines) and lines[-1] == 'Success' and not any('Failure' in line for line in lines)


def cleanup_guest_app(device, attempted):
    require(device.package in lifecycle_probe.SAFE_PACKAGES and type(attempted) is bool, 'owned_example_package_required')
    if attempted:
        device.call('shell', 'am', 'force-stop', device.package)
        require(device.call('uninstall', device.package).strip() == b'Success', 'owned_app_uninstall_unconfirmed')
        return {'app_uninstalled': True, 'app_absent_without_install': False}
    raw = device.call('shell', 'pm', 'list', 'packages', device.package)
    require(isinstance(raw, bytes) and len(raw) <= 8192 and raw.isascii(), 'bounded_package_absence_required')
    rows = raw.decode().strip().splitlines()
    require(all(re.fullmatch(r'package:[A-Za-z0-9_.]+', row) is not None for row in rows), 'package_absence_unconfirmed')
    require('package:' + device.package not in rows, 'unexpected_preexisting_example_package')
    return {'app_uninstalled': False, 'app_absent_without_install': True}


def installed_base_apk(data, package=PACKAGE):
    require(isinstance(data, bytes) and len(data) < 1024 and data.isascii(), 'installed_apk_path_unconfirmed')
    token = r'([A-Za-z0-9_-]{22}==)'
    pattern = r'package:(/data/app/(?:~~' + token + r'/)?' + re.escape(package) + '-' + token + r'/base\.apk)\r?\n?'
    match = re.fullmatch(pattern, data.decode('ascii'))
    require(match is not None, 'installed_apk_path_unconfirmed')
    for value in (match[2], match[3]):
        if value is not None:
            require(base64.urlsafe_b64encode(base64.urlsafe_b64decode(value)).decode() == value, 'installed_apk_path_unconfirmed')
    return match[1], 'nestedRandom' if match[2] else 'flatRandom'


def launch_observation(data):
    require(isinstance(data, bytes) and len(data) <= 128 * 1024, 'bounded_launch_result_required')
    text = data.decode('utf-8', errors='replace')
    status = re.findall(r'^Status: (ok|timeout)\s*$', text, re.M)
    errors = re.findall(r'^Error type (\d+)\s*$', text, re.M)
    vocabulary = set('error activity class does not exist unable resolve intent permission denial start started launch timeout exception process crashed closed has been delivered currently running topmost instance warning task brought front'.split())
    result = {'status': status[0] if len(status) == 1 else 'unknown', 'error_type': int(errors[0]) if len(errors) == 1 else None, 'message_words': [word for word in re.findall('[a-z]+', text.lower()) if word in vocabulary][:48]}
    for name, key in (('WaitTime', 'wait_time_ms'), ('TotalTime', 'total_time_ms'), ('ThisTime', 'this_time_ms')):
        times = re.findall(r'^' + name + r': (\d{1,7})\s*$', text, re.M)
        result[key] = int(times[0]) if len(times) == 1 else None
    return result


def startup_observation(data):
    require(isinstance(data, bytes) and len(data) <= 256 * 1024, 'bounded_startup_result_required')
    text = data.decode('utf-8', errors='replace')
    stages = ('bindingReady', 'rustEntrypointReady', 'rustEntrypointPending', 'rustReady', 'platformReady', 'bootstrapReady', 'trustReady', 'runApp', 'initError', 'zoneError')
    seen = re.findall(r'^\[xclient-startup\] ([A-Za-z]+)\s*$', text, re.M)
    return {'stages': list(dict.fromkeys(stage for stage in seen if stage in stages)), 'vm_service_announced': 'Dart VM service is listening on ' in text}


def native_stack_observation(data):
    require(isinstance(data, bytes) and len(data) <= 256 * 1024, 'bounded_native_stack_required')
    text = data.decode('utf-8', errors='replace')
    libraries = ('libgojni.so', 'librust_api.so', 'libflutter.so', 'libc.so', 'libart.so', 'libandroid_runtime.so', 'libdl.so', 'libutils.so', 'libnativehelper.so', 'libbinder.so')
    frames = []
    for line in text.splitlines():
        match = re.search(r'#(\d+)\s+pc\s+[0-9a-f]+\s+[^\s]*/([^/\s]+)(?:\s+\(([^\r\n]{0,180})\))?', line)
        if match and match[2] in libraries:
            symbol = match[3] or ''
            frames.append({'index': int(match[1]), 'library': match[2], 'symbol': symbol if re.fullmatch(r'[A-Za-z0-9_$:<>~.*&,+() \-]*', symbol) else 'unknown'})
    return {'recognized_frames': frames[:48], 'available': bool(frames)}


def link_observation(text):
    require(isinstance(text, str) and len(text) <= 128 * 1024, 'bounded_guest_links_required')
    interfaces = []
    for line in text.splitlines():
        match = re.match(r'\d+: ([A-Za-z0-9_.@-]+): <([A-Z_,\-]+)> mtu (\d+) .*?\bstate ([A-Z]+)\b', line)
        require(match is not None, 'guest_link_format_unconfirmed')
        name = match[1]
        known = re.fullmatch(r'(?:lo|(?:eth|wlan|dummy|rmnet|bond|sit|ip6tnl|tun|utun|ppp)\d+)(?:@[A-Za-z0-9_.-]+)?', name)
        interfaces.append({'name': name if known else 'other', 'name_sha256': hashlib.sha256(name.encode()).hexdigest(), 'flags': match[2].split(','), 'mtu': int(match[3]), 'state': match[4]})
    require(0 < len(interfaces) <= 64, 'bounded_guest_interfaces_required')
    return interfaces


def crash_observation(data, package=PACKAGE):
    require(isinstance(data, bytes) and len(data) <= 256 * 1024, 'bounded_crash_result_required')
    text = data.decode('utf-8', errors='replace')
    blocks = re.split(r'(?=^.*FATAL EXCEPTION:)', text, flags=re.M)
    owned = [block for block in blocks if 'Process: ' + package + ',' in block]
    text = '\n'.join(owned)
    own = bool(owned)
    classes = re.findall(r'\b((?:java|android|kotlin|com\.follow\.clash|io\.flutter)\.[A-Za-z0-9_.$]*(?:Exception|Error))\b', text) if own else []
    frames = re.findall(r'\bat ((?:com\.follow\.clash|io\.flutter)\.[A-Za-z0-9_.$]+)\(([A-Za-z0-9_]+\.(?:kt|java)):(\d+)\)', text) if own else []
    return {'owned_process_crash_seen': own, 'exception_classes': list(dict.fromkeys(classes))[:12], 'owned_frames': [{'method': method, 'file': file, 'line': int(line)} for method, file, line in frames[:16]]}


class Device:
    package = PACKAGE

    def __init__(self, adb, port, serial, env, output, avd_name, *, package=PACKAGE):
        require(package in lifecycle_probe.SAFE_PACKAGES, 'owned_example_package_required')
        self.package = package
        self.adb, self.port, self.serial, self.env, self.output, self.avd_name = adb, port, serial, env, output, avd_name

    def call(self, *argv, timeout=45, data=None):
        return command([self.adb, '-P', self.port, '-s', self.serial, *argv], env=self.env, timeout=timeout, data=data)

    def verify_owned(self):
        inventory = command([self.adb, '-P', self.port, 'devices'], env=self.env).decode().strip().splitlines()[1:]
        require(inventory == [self.serial + '\tdevice'], 'unexpected_adb_inventory')
        name = self.call('emu', 'avd', 'name').decode().strip().splitlines()
        require(name == [self.avd_name, 'OK'], 'emulator_avd_ownership_mismatch')

    def ui(self):
        require(re.fullmatch(r'xc_safe_[0-9a-f]{32}', self.avd_name) is not None, 'owned_ui_dump_nonce_required')
        metrics = getattr(self, 'ui_metrics', None)
        if metrics is None:
            metrics = self.ui_metrics = {'samples': 0, 'dump_attempts': 0, 'unconfirmed_attempts': 0, 'max_ms': 0}
        started, confirmed = time.monotonic(), False
        try:
            for attempt in range(3):
                self.ui_sequence = getattr(self, 'ui_sequence', 0) + 1
                remote = '/data/local/tmp/xclient-' + self.avd_name + '-' + str(self.ui_sequence) + '.xml'
                metrics['dump_attempts'] += 1
                marker = self.call('shell', 'uiautomator', 'dump', remote).strip()
                expected = [('UI ' + spelling + ' dumped to: ' + remote).encode() for spelling in ('hierchary', 'hierarchy')]
                if marker not in expected:
                    metrics['unconfirmed_attempts'] += 1
                    if not marker and attempt < 2:
                        time.sleep(0.5)
                        continue
                require(marker in expected, 'fresh_ui_dump_unconfirmed')
                tree = parse_ui(self.call('exec-out', 'cat', remote))
                confirmed = True
                return tree
            raise Refused('fresh_ui_dump_unconfirmed')
        finally:
            elapsed = int((time.monotonic() - started) * 1000)
            metrics.update(samples=metrics['samples'] + 1, last_ms=elapsed, max_ms=max(metrics['max_ms'], elapsed), last_success=confirmed)

    def tap(self, node):
        require(node.get('package') == self.package, 'owned_app_ui_node_required')
        self.call('shell', 'input', 'tap', *node_center(node))

    def wait_label(self, label, timeout=40):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            tree = self.ui()
            found = labelled_nodes(tree, label)
            if len(found) == 1:
                return tree, found[0]
            time.sleep(1)
        raise Refused('expected_native_ui_missing')

    def wait_empty_validation(self):
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            text = '\n'.join(ui_label(node) for node in self.ui().iter('node'))
            if '请输入邮箱' in text and '请输入密码' in text:
                return
            time.sleep(1)
        raise Refused('empty_login_validation_missing')

    def capture(self, name):
        metadata = self.native_capture(name)
        tree = self.ui()
        for node in tree.iter('node'):
            if node.get('class') == 'android.widget.EditText' or node.get('password') == 'true':
                for attribute in ('text', 'content-desc'):
                    if node.get(attribute):
                        node.set(attribute, '[redacted]')
        ET.ElementTree(tree).write(self.output / 'receipts' / (name + '.xml'), encoding='utf-8', xml_declaration=True)
        return metadata

    def native_capture(self, name):
        image = self.call('exec-out', 'screencap', '-p')
        metadata = validate_png(image)
        (self.output / 'receipts' / (name + '.png')).write_bytes(image)
        return metadata

    def guest_network(self):
        links = self.call('shell', 'ip', '-o', 'link').decode()
        require(re.search(r'\b(?:tun\d*|utun\d*|ppp\d*)[:@]', links) is None, 'unexpected_guest_tun')
        proxy = self.call('shell', 'settings', 'get', 'global', 'http_proxy').decode().strip()
        require(proxy in ('null', ':0', ''), 'unexpected_guest_proxy')
        return {'links_sha256': hashlib.sha256(links.encode()).hexdigest(), 'proxy_sha256': hashlib.sha256(proxy.encode()).hexdigest(), 'interfaces': link_observation(links)}

    def observe_anr(self):
        return anr_observation(self.call('shell', 'dumpsys', 'activity', 'lastanr'), self.call('logcat', '-d', '-v', 'raw', '-t', '200', 'ActivityManager:E', '*:S'), self.package)

    def await_launcher(self, verify_emulator):
        started = time.monotonic()
        deadline, quiet_since, consecutive = started + 120, None, 0
        self.launcher_readiness = {'ready': False, 'snapshots': 0}
        while time.monotonic() < deadline:
            require(verify_emulator(), 'owned_emulator_identity_unconfirmed')
            self.verify_owned()
            report = self.observe_anr()
            self.launcher_readiness['anr'] = report
            require(report['last_anr_query_recognized'], 'system_anr_state_unconfirmed')
            require(report['no_anr_since_boot_marker'] and not report['recent_anr_owners'], 'preexisting_system_anr')
            tree = self.ui()
            observed = launcher_observation(tree, self.call('shell', 'dumpsys', 'activity', 'activities'), self.call('shell', 'getprop', 'init.svc.bootanim'))
            self.launcher_readiness.update(last_snapshot=observed, snapshots=self.launcher_readiness['snapshots'] + 1)
            require(observed['visible_anr_owner'] is None, 'visible_' + str(observed['visible_anr_owner']) + '_anr')
            if all(observed[key] for key in ('boot_animation_stopped', 'launcher_resumed', 'launcher_ui_visible')):
                quiet_since = time.monotonic() if quiet_since is None else quiet_since
                consecutive += 1
                if consecutive >= 3 and time.monotonic() - quiet_since >= 8:
                    require(time.monotonic() < deadline, 'launcher_ui_readiness_unconfirmed')
                    self.launcher_readiness.update(ready=True, consecutive_healthy=consecutive, quiet_ms=int((time.monotonic() - quiet_since) * 1000), elapsed_ms=int((time.monotonic() - started) * 1000))
                    return self.launcher_readiness
            else:
                quiet_since, consecutive = None, 0
            time.sleep(2)
        raise Refused('launcher_ui_readiness_unconfirmed')

    def await_network(self, verify_emulator):
        deadline = time.monotonic() + 90
        previous, identical = None, 0
        self.network_readiness = {'snapshots': 0}
        while time.monotonic() < deadline:
            require(verify_emulator(), 'owned_emulator_identity_unconfirmed')
            self.verify_owned()
            snapshot = self.guest_network()
            links = [item for item in snapshot['interfaces'] if item['name'] in ('eth0', 'wlan0')]
            ready = {item['name'] for item in links} == {'eth0', 'wlan0'} and all(item['state'] == 'UP' and {'UP', 'LOWER_UP'}.issubset(item['flags']) for item in links)
            identical = identical + 1 if ready and previous == snapshot else 1 if ready else 0
            self.network_readiness.update(snapshots=self.network_readiness['snapshots'] + 1, ready=ready, consecutive_identical=identical, last_snapshot=snapshot)
            if identical >= 3:
                return snapshot
            previous = snapshot
            time.sleep(2)
        raise Refused('guest_network_readiness_unconfirmed')

    def start(self):
        self.verify_owned()
        result = self.call('shell', 'am', 'start', '-W', '-n', self.package + '/' + ACTIVITY).decode()
        report = launch_observation(result.encode('utf-8'))
        if not getattr(self, '_initial_launch_recorded', False):
            write_json(self.output / 'receipts/initial-launch.json', report)
            self._initial_launch_recorded = True
        if report['status'] != 'ok':
            try:
                report['crash'] = crash_observation(self.call('logcat', '-b', 'crash', '-d', '-t', '100'), package=self.package)
            except Exception:
                report['crash_diagnostic_unavailable'] = True
            try:
                report['capture'] = self.native_capture('launch-failure')
            except Exception:
                report['capture_unavailable'] = True
            try:
                guest = lifecycle_probe.guest_identity(self)
                messages = self.call('logcat', '-d', '--pid=' + str(guest['pid']), '-v', 'raw', '-t', '500', 'DartVM:I', 'flutter:I', '*:S')
                require(lifecycle_probe.guest_identity(self) == guest, 'startup_guest_changed')
                report['startup'] = startup_observation(messages)
                report['vm_startup'] = startup_probe.observe(self, guest, messages)
                time.sleep(12)
                require(lifecycle_probe.guest_identity(self) == guest, 'startup_guest_changed')
                late_messages = self.call('logcat', '-d', '--pid=' + str(guest['pid']), '-v', 'raw', '-t', '500', 'DartVM:I', 'flutter:I', '*:S')
                require(lifecycle_probe.guest_identity(self) == guest, 'startup_guest_changed')
                report['late_startup'] = startup_observation(late_messages)
                report['late_vm_startup'] = startup_probe.observe(self, guest, late_messages)
                report['late_capture'] = self.native_capture('launch-failure-late')
                try:
                    report['late_login_visible'] = len(labelled_nodes(self.ui(), '登录')) == 1
                except Exception:
                    report['late_login_observation_unavailable'] = True
                try:
                    require(lifecycle_probe.guest_identity(self) == guest, 'startup_guest_changed')
                    trace = self.call('shell', 'run-as', self.package, 'debuggerd', '-b', str(guest['pid']), timeout=10)
                    require(lifecycle_probe.guest_identity(self) == guest, 'startup_guest_changed')
                    report['native_stack'] = native_stack_observation(trace)
                except Refused as error:
                    report['native_stack'] = {'available': False, 'command_exit_code': error.exit_code, 'error_class': str(error)}
                except Exception:
                    report['native_stack'] = {'available': False, 'error_class': 'owned_native_stack_unavailable'}
            except Exception:
                report['startup_diagnostic_incomplete'] = True
            write_json(self.output / 'receipts/launch-failure.json', report)
            raise Refused('app_launch_unconfirmed')

    def consent_field(self):
        def inputs(tree):
            anr = visible_anr_owner(tree)
            require(anr is None, 'visible_' + str(anr) + '_anr')
            found = [node for node in tree.iter('node') if node.get('package') == self.package and node.get('class') == 'android.widget.EditText' and node.get('enabled') == 'true']
            require(len(found) <= 1, 'owned_consent_input_required')
            return found

        def scroller(tree):
            anr = visible_anr_owner(tree)
            require(anr is None, 'visible_' + str(anr) + '_anr')
            nodes = [node for node in tree.iter('node') if node.get('package') == self.package]
            require(all(sum(ui_label(node).strip() == label for node in nodes) == 1 for label in ('Restate the statement', 'Cancel', 'Confirm')), 'owned_consent_dialog_required')
            scrolls = [node for node in nodes if node.get('class') == 'android.widget.ScrollView' and node.get('scrollable') == 'true' and node.get('enabled') == 'true']
            require(len(scrolls) == 1, 'owned_consent_scrollview_required')
            return scrolls[0]

        for _ in range(5):
            self.verify_owned()
            tree = self.ui()
            found = inputs(tree)
            if found:
                return found[0]
            scroller(tree)
            count = getattr(self, 'consent_scroll_attempts', 0)
            require(count < 4, 'visible_consent_input_unconfirmed')
            self.consent_scroll_attempts = count + 1
            capture = self.native_capture('01-restate-scroll-' + str(count))
            self.verify_owned()
            tree = self.ui()
            found = inputs(tree)
            if found:
                return found[0]
            scroll = scroller(tree)
            node_center(scroll)
            left, top, right, bottom = map(int, re.findall(r'\d+', scroll.get('bounds', '')))
            require(right <= capture['width'] and bottom <= capture['height'] and bottom - top >= 80, 'visible_consent_scroll_bounds_required')
            x, margin = (left + right) // 2, (bottom - top) // 5
            self.call('shell', 'input', 'swipe', x, bottom - margin, x, top + margin, '350')
            time.sleep(0.2)
        raise Refused('visible_consent_input_unconfirmed')

    def type_consent_statement(self, statement):
        require(statement.isascii() and 0 < len(statement) < 300, 'known_consent_statement_required')
        started = time.monotonic()
        deadline = started + min(600, 30 + 45 * ((len(statement) + 7) // 8))
        progress = self.consent_progress = {'expected_length': len(statement), 'verified_prefix_length': 0, 'chunks_sent': 0, 'complete': False}
        try:
            current = self.consent_field()
            progress['initial_observation_ms'] = int((time.monotonic() - started) * 1000)
            focus_deadline = min(deadline, time.monotonic() + 45)
            while current.get('focused') != 'true':
                require(time.monotonic() < focus_deadline, 'consent_input_focus_unconfirmed')
                time.sleep(0.2)
                current = self.consent_field()
            require(time.monotonic() < focus_deadline, 'consent_input_focus_unconfirmed')
            require(current.get('text', '') == '', 'consent_input_not_empty')
            for start in range(0, len(statement), 8):
                before_read = time.monotonic()
                step_deadline = min(deadline, before_read + 45)
                current = self.consent_field()
                timing = progress['last_chunk'] = {'start': start, 'pre_observation_ms': int((time.monotonic() - before_read) * 1000), 'post_observation_ms': 0, 'post_observations': 0}
                require(time.monotonic() < step_deadline, 'consent_input_progress_unconfirmed')
                require(current.get('focused') == 'true' and current.get('text', '') == statement[:start], 'consent_input_diverged')
                chunk = statement[start:start + 8]
                before_input = time.monotonic()
                self.call('shell', 'input', 'text', shlex.quote(chunk.replace(' ', '%s')))
                timing['input_ms'] = int((time.monotonic() - before_input) * 1000)
                progress['chunks_sent'] += 1
                expected = statement[:start + len(chunk)]
                while True:
                    require(time.monotonic() < step_deadline, 'consent_input_progress_unconfirmed')
                    before_read = time.monotonic()
                    observed = self.consent_field().get('text', '')
                    timing['post_observation_ms'] += int((time.monotonic() - before_read) * 1000)
                    timing['post_observations'] += 1
                    progress.update(input_length=len(observed), matches_statement_prefix=statement.startswith(observed))
                    require(time.monotonic() < step_deadline, 'consent_input_progress_unconfirmed')
                    if observed == expected:
                        progress['verified_prefix_length'] = len(expected)
                        break
                    require(expected.startswith(observed), 'consent_input_diverged')
                    time.sleep(0.2)
            progress['complete'] = True
        finally:
            progress.update(elapsed_ms=int((time.monotonic() - started) * 1000), scroll_attempts=getattr(self, 'consent_scroll_attempts', 0))

    def record_consent_input(self, statement, ime):
        inputs = [node for node in self.ui().iter('node') if node.get('package') == self.package and node.get('class') == 'android.widget.EditText']
        value = inputs[0].get('text', '') if len(inputs) == 1 else None
        visibility = re.findall(rb'(?m)^\s*mInputShown=(true|false)\b', ime)
        window = re.findall(rb'\bmImeWindowVis=(?:0x)?([0-9a-fA-F]{1,8})\b', ime)
        report = {'owned_input_count': len(inputs), 'input_length': len(value) if value is not None else None, 'expected_length': len(statement), 'matches_expected_statement': value == statement, 'matches_expected_prefix': bool(value) and statement.startswith(value), 'input_method_visible': visibility[0] == b'true' if len(visibility) == 1 else None, 'input_method_window_visible': bool(int(window[0], 16) & 2) if len(window) == 1 else None}
        write_json(self.output / 'receipts/consent-input.json', report)
        return report

    def disclaimer(self):
        tree = self.ui()
        agree = labelled_nodes(tree, 'Agree')
        if not agree:
            return False
        require(len(agree) == 1, 'ambiguous_consent_action')
        self.capture('01-disclaimer')
        self.tap(agree[0])
        deadline = time.monotonic() + 25
        while time.monotonic() < deadline:
            tree = self.ui()
            inputs = [node for node in tree.iter('node') if node.get('class') == 'android.widget.EditText' and node.get('enabled') == 'true']
            if len(inputs) == 1:
                statement = json.loads((ROOT / 'arb/intl_en.arb').read_text(encoding='utf-8'))['disclaimerNoServiceStatement']
                require(statement.isascii() and len(statement) < 300, 'known_consent_statement_required')
                self.tap(inputs[0])
                self.type_consent_statement(statement)
                ime = self.call('shell', "dumpsys input_method | sed -n '/^[[:space:]]*mInputShown=/p'")
                require(len(ime) <= 1024, 'bounded_ime_observation_required')
                if self.record_consent_input(statement, ime)['input_method_visible'] is True:
                    self.call('shell', 'input', 'keyevent', 'KEYCODE_BACK')
                _, confirm = self.wait_label('Confirm')
                self.tap(confirm)
                return True
            time.sleep(1)
        raise Refused('consent_restatement_missing')

    def await_login(self):
        deadline = time.monotonic() + 100
        consent = False
        while time.monotonic() < deadline:
            tree = self.ui()
            anr = visible_anr_owner(tree)
            require(anr is None, 'visible_' + str(anr) + '_anr')
            found = labelled_nodes(tree, '登录')
            if len(found) == 1:
                return tree, found[0], consent
            if labelled_nodes(tree, 'Agree'):
                require(not consent, 'consent_reappeared_after_confirmation')
                if self.disclaimer():
                    consent = True
                    # Verified restatement has its own finite input budget.
                    # Start the login transition budget after actual Confirm.
                    deadline = time.monotonic() + 100
            time.sleep(1)
        raise Refused('login_ui_missing')


def initial_start(device):
    try:
        device.start()
        return True
    except Refused as error:
        if str(error) != 'app_launch_unconfirmed':
            raise
        file = device.output / 'receipts/launch-failure.json'
        require(file.is_file() and not file.is_symlink(), 'late_normal_start_unconfirmed')
        report = json.loads(file.read_text(encoding='utf-8'))
        stages = report.get('late_startup', {}).get('stages', [])
        vm = report.get('late_vm_startup', {})
        require(report.get('status') == 'timeout' and report.get('error_type') is None and report.get('crash', {}).get('owned_process_crash_seen') is False and isinstance(stages, list) and all(stage in stages for stage in ('bindingReady', 'rustReady', 'platformReady', 'bootstrapReady', 'trustReady', 'runApp')) and not any(stage in stages for stage in ('initError', 'zoneError')) and all(vm.get(key) is True for key in ('available', 'main_isolate_verified', 'owned_forward_cleanup')), 'late_normal_start_unconfirmed')
        return False


def verify_lifecycle(device, receipt):
    package = device.package
    receipt['checkpoint'] = 'consentAndLogin'
    receipt['initial_activity_wait_confirmed'] = initial_start(device)
    if not receipt['initial_activity_wait_confirmed']:
        receipt['errors'].append('initial_activity_wait_timeout')
    tree, login, receipt['consent_through_ui'] = device.await_login()
    require(len([node for node in tree.iter('node') if node.get('class') == 'android.widget.EditText']) == 2, 'login_fields_missing')
    receipt['captures']['login'] = device.capture('02-login')
    receipt['login_rendered'] = True
    receipt['checkpoint'] = 'emptyValidation'
    device.tap(login)
    device.wait_empty_validation()
    receipt['captures']['empty_validation'] = device.capture('03-empty-validation')
    receipt['empty_form_validation'] = True
    receipt['checkpoint'] = 'homeReopen'
    before_pid = device.call('shell', 'pidof', package).strip()
    require(re.fullmatch(rb'\d+', before_pid) is not None, 'single_app_process_required')
    device.call('shell', 'input', 'keyevent', 'KEYCODE_HOME')
    time.sleep(2)
    device.start()
    device.wait_label('登录')
    receipt['same_process_after_home'] = device.call('shell', 'pidof', package).strip() == before_pid
    require(receipt['same_process_after_home'], 'unexpected_process_restart_after_home')
    receipt['home_reopen'] = True
    receipt['checkpoint'] = 'backReopen'
    device.call('shell', 'input', 'keyevent', 'KEYCODE_BACK')
    time.sleep(2)
    device.start()
    device.wait_label('登录')
    receipt['captures']['reopened'] = device.capture('04-reopened')
    receipt['back_reopen'] = True
    receipt['checkpoint'] = 'activityAndExplicitQuit'
    lifecycle = lifecycle_probe.LifecycleProbe(device).run()
    receipt['activity_destruction_tested'] = len(lifecycle['replacements']) == 2 and all(item['client_destroy_callback_returned'] for item in lifecycle['replacements'])
    receipt['same_ui_isolate_across_activity_replacement'] = receipt['activity_destruction_tested'] and all(item['same_main_isolate'] for item in lifecycle['replacements'])
    receipt['explicit_quit_reopen_verified'] = lifecycle['success']
    receipt['vm_forward_cleanup_verified'] = lifecycle['vm_forward_cleanup']
    require(lifecycle['success'], 'activity_or_explicit_quit_proof_incomplete')


def run(args):
    state, output = load_state(args.state)
    package = package_for_mode(state['build_mode'])
    require(os.environ.get('GITHUB_JOB') == CONSUMER_JOB, 'artifact_consumer_required')
    built = json.loads((output / 'private/build.json').read_text(encoding='utf-8'))
    apk = validate_staged_apk(state, output, built)
    tools = json.loads((output / 'private/tools.json').read_text(encoding='utf-8'))
    sdk = Path(state['sdk'])
    emulator = sdk_tool(sdk, 'emulator/emulator')
    require(str(emulator) == tools['emulator'] and sha(emulator) == tools['emulator_sha256'], 'official_emulator_changed')
    images = snapshot_emulator_images(sdk)
    write_json(output / 'receipts/emulator-images.json', {'package_revision': tools['emulator_package_revision'], 'pinned_images': tools['emulator_images'], 'prelaunch_images_match': images == tools['emulator_images']})
    require(images == tools['emulator_images'], 'official_emulator_images_changed')
    require(sha(sdk / 'system-images/android-35/google_apis/x86_64/source.properties') == tools['image_properties_sha256'], 'official_image_changed')
    require(os.access('/dev/kvm', os.R_OK | os.W_OK), 'kvm_access_required')
    env = private_env(output)
    adb = sdk_tool(sdk, 'platform-tools/adb')
    avdmanager = sdk_tool(sdk, 'cmdline-tools/latest/bin/avdmanager')
    avd_name = 'xc_safe_' + state['nonce']
    command([avdmanager, 'create', 'avd', '--name', avd_name, '--package', IMAGE, '--path', output / 'private/avd/device', '--device', 'pixel_2'], env=env, timeout=120, data=b'no\n')
    port = free_port()
    env.update(ANDROID_ADB_SERVER_PORT=str(port), ADB_SERVER_SOCKET='tcp:127.0.0.1:' + str(port))
    before_network = network_hash()
    adb_child = emulator_child = None
    adb_owner = emulator_owner = None
    emulator_birth = None
    adb_log = emulator_log = None
    receipt = {'success': False, 'checkpoint': 'startAdb', 'purpose': state.get('purpose', 'lifecycle'), 'image': IMAGE, 'safe_mode': True, 'build_mode': state['build_mode'], 'package': package, 'apk_sha256': sha(apk), 'device_verified': False, 'guest_cleanup_authorized': False, 'initial_install': False, 'installed_apk_hash_verified': False, 'login_rendered': False, 'empty_form_validation': False, 'home_reopen': False, 'back_reopen': False, 'same_process_after_home': False, 'activity_destruction_tested': False, 'background_engine_verified': False, 'vpn_or_doze_tested': False, 'guest_network_unchanged': False, 'host_network_unchanged': False, 'owned_emulator_stopped': False, 'owned_adb_stopped': False, 'app_uninstalled': False, 'fatal_crash_count': None, 'emulator_exit_code': None, 'adb_exit_code': None, 'boot_completed_observed': False, 'emulator_identity': {'status': 'notObserved'}, 'emulator_images_seen': [], 'captures': {}, 'errors': []}
    device = None
    guest_before = None
    receipt['app_install_attempted'] = False

    def refresh_emulator_lease():
        nonlocal emulator_birth, emulator_owner
        emulator_birth, emulator_owner, report = observe_emulator(emulator_child, emulator_birth, images, sdk)
        receipt['emulator_identity'] = report
        if report['image_class'] not in receipt['emulator_images_seen']:
            receipt['emulator_images_seen'].append(report['image_class'])
        return emulator_owner is not None
    try:
        adb_log = (output / 'private/adb.log').open('xb')
        adb_child = subprocess.Popen([str(adb), '-P', str(port), 'nodaemon', 'server'], env=env, stdin=subprocess.DEVNULL, stdout=adb_log, stderr=subprocess.STDOUT)
        time.sleep(1)
        require(adb_child.poll() is None, 'private_adb_server_failed')
        adb_owner = process_identity(adb_child.pid)
        require(adb_owner['exe'] == str(adb) and adb_owner['ppid'] == os.getpid(), 'private_adb_identity_mismatch')
        require(len(command([adb, '-P', port, 'devices'], env=env).decode().strip().splitlines()) == 1, 'fresh_adb_server_not_empty')
        receipt['checkpoint'] = 'bootEmulator'
        require_emulator_ports_free()
        emulator_log = (output / 'private/emulator.log').open('xb')
        emulator_child = subprocess.Popen([str(emulator), '-avd', avd_name, '-port', '5554', '-no-window', '-no-audio', '-no-snapshot', '-no-boot-anim', '-gpu', 'swiftshader', '-accel', 'on', '-memory', '2048', '-cores', '2', '-camera-back', 'none', '-camera-front', 'none'], env=env, stdin=subprocess.DEVNULL, stdout=emulator_log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 300
        device = Device(adb, port, 'emulator-5554', env, output, avd_name, package=package)
        while time.monotonic() < deadline:
            require(emulator_child.poll() is None, 'emulator_exited_before_boot')
            require(refresh_emulator_lease(), 'owned_emulator_identity_unconfirmed')
            try:
                if device.call('shell', 'getprop', 'sys.boot_completed', timeout=10).strip() == b'1':
                    receipt['boot_completed_observed'] = True
                    break
            except (Refused, subprocess.TimeoutExpired):
                pass
            time.sleep(2)
        else:
            raise Refused('emulator_boot_timeout')
        require(refresh_emulator_lease(), 'owned_emulator_identity_unconfirmed')
        device.verify_owned()
        receipt['device_verified'] = True
        require(device.call('shell', 'getprop', 'ro.build.version.sdk').strip() == b'35' and device.call('shell', 'getprop', 'ro.product.cpu.abi').strip() == b'x86_64', 'running_image_mismatch')
        locale = device.call('shell', 'getprop', 'persist.sys.locale').strip() or device.call('shell', 'getprop', 'ro.product.locale').strip()
        require(locale.startswith(b'en'), 'english_consent_locale_required')
        device.call('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP')
        device.call('shell', 'input', 'keyevent', 'KEYCODE_MENU')
        receipt['checkpoint'] = 'guestNetworkReady'
        guest_before = device.await_network(refresh_emulator_lease)
        receipt['guest_network_before'] = guest_before
        receipt['checkpoint'] = 'guestUiReady'
        receipt['guest_ui_readiness'] = device.await_launcher(refresh_emulator_lease)
        receipt['checkpoint'] = 'installApk'
        device.verify_owned()
        receipt['app_install_attempted'] = True
        require(successful_install(device.call('install', '--no-streaming', apk, timeout=120)), 'fresh_apk_install_failed')
        receipt['initial_install'] = True
        receipt['checkpoint'] = 'verifyInstalledApk'
        installed, receipt['installed_path_schema'] = installed_base_apk(device.call('shell', 'pm', 'path', package), package=package)
        installed_hash = device.call('shell', 'sha256sum', shlex.quote(installed)).decode().split()[0]
        require(installed_hash == receipt['apk_sha256'], 'installed_apk_hash_mismatch')
        receipt['installed_apk_hash_verified'] = True
        device.call('logcat', '-b', 'crash', '-c')
        if state.get('purpose', 'lifecycle') == 'update-component':
            import android_update_component
            receipt['checkpoint'] = 'nativeUpdateComponent'
            receipt['component'] = android_update_component.run_component(device, state, output, receipt)
        else:
            verify_lifecycle(device, receipt)
        receipt['guest_network_unchanged'] = device.guest_network() == guest_before
        require(receipt['guest_network_unchanged'], 'guest_network_changed')
        crash = device.call('logcat', '-b', 'crash', '-d', '-t', '100').decode(errors='replace')
        receipt['fatal_crash_count'] = crash.count('FATAL EXCEPTION')
        require(receipt['fatal_crash_count'] == 0, 'android_fatal_crash')
        receipt['runtime_anr'] = device.observe_anr()
        receipt['bounded_anr_check_passed'] = receipt['runtime_anr']['last_anr_query_recognized'] and receipt['runtime_anr']['no_anr_since_boot_marker'] and not receipt['runtime_anr']['recent_anr_owners']
        require(receipt['bounded_anr_check_passed'], 'runtime_anr_or_unknown_state')
        receipt['checkpoint'] = 'checksComplete'
    except Exception as error:
        if device is not None and hasattr(device, 'network_readiness'):
            receipt['guest_network_readiness'] = device.network_readiness
        if device is not None and hasattr(device, 'launcher_readiness'):
            receipt['guest_ui_readiness'] = device.launcher_readiness
        receipt['emulator_identity_at_failure'] = dict(receipt['emulator_identity'])
        receipt['errors'].append(str(error) if isinstance(error, Refused) else type(error).__name__)
        receipt['failed_checkpoint'] = receipt['checkpoint']
        try:
            if device is not None and receipt['device_verified'] and emulator_child.poll() is None and refresh_emulator_lease():
                device.verify_owned()
                try:
                    receipt['failure_capture'] = device.capture('failure-ui')
                except Exception:
                    receipt['failure_ui_observation_incomplete'] = True
                try:
                    device.verify_owned()
                    receipt['runtime_anr'] = device.observe_anr()
                except Exception:
                    receipt['failure_anr_observation_incomplete'] = True
        except Exception:
            receipt['failure_ui_observation_incomplete'] = True
    finally:
        if device is not None and hasattr(device, 'consent_progress'):
            receipt['consent_progress'] = device.consent_progress
        if device is not None and hasattr(device, 'ui_metrics'):
            receipt['ui_observations'] = device.ui_metrics
        live_emulator = emulator_child is not None and emulator_child.poll() is None
        verified_emulator = live_emulator and refresh_emulator_lease()
        if device is not None and receipt['device_verified'] and verified_emulator:
            try:
                device.verify_owned()
                guest_after = device.guest_network()
                receipt['guest_network_after'] = guest_after
                receipt['guest_network_unchanged'] = guest_before is not None and guest_after == guest_before
                require(receipt['guest_network_unchanged'], 'guest_network_changed')
            except Exception as error:
                receipt['errors'].append('guest_network_cleanup_unconfirmed')
                if isinstance(error, Refused):
                    receipt['errors'].append(str(error))
            try:
                device.verify_owned()
                receipt['guest_cleanup_authorized'] = True
                receipt.update(cleanup_guest_app(device, receipt['app_install_attempted']))
                device.call('emu', 'kill', timeout=15)
                emulator_child.wait(timeout=20)
            except Exception:
                receipt['errors'].append('guest_cleanup_unconfirmed')
        receipt['owned_emulator_stopped'] = stop_owned(emulator_child, emulator_owner, verify=refresh_emulator_lease)
        receipt['owned_adb_stopped'] = stop_owned(adb_child, adb_owner)
        receipt['emulator_exit_code'] = emulator_child.poll() if emulator_child is not None else None
        receipt['adb_exit_code'] = adb_child.poll() if adb_child is not None else None
        for log in (emulator_log, adb_log):
            if log is not None:
                log.close()
        receipt['host_network_unchanged'] = network_hash() == before_network
        common = receipt.get('guest_ui_readiness', {}).get('ready') is True and all(receipt.get(key) is True for key in ('device_verified', 'guest_cleanup_authorized', 'initial_install', 'installed_apk_hash_verified', 'bounded_anr_check_passed', 'guest_network_unchanged', 'host_network_unchanged', 'owned_emulator_stopped', 'owned_adb_stopped', 'app_uninstalled'))
        if state.get('purpose', 'lifecycle') == 'update-component':
            acceptance = common and receipt.get('component', {}).get('success') is True and receipt.get('component', {}).get('synthetic_cleanup_verified') is True
        else:
            acceptance = common and all(receipt.get(key) is True for key in ('login_rendered', 'empty_form_validation', 'home_reopen', 'back_reopen', 'same_process_after_home', 'activity_destruction_tested', 'same_ui_isolate_across_activity_replacement', 'explicit_quit_reopen_verified', 'vm_forward_cleanup_verified'))
        receipt['ui_lifecycle_acceptance_verified'] = state.get('purpose', 'lifecycle') == 'lifecycle' and acceptance and all(error == 'initial_activity_wait_timeout' for error in receipt['errors'])
        receipt['success'] = not receipt['errors'] and acceptance
        write_json(output / 'receipts/result.json', receipt)
    print(json.dumps({'success': receipt['success'], 'errors': receipt['errors'], **{key: receipt[key] for key in ('failed_checkpoint', 'component_step') if key in receipt}}))
    return 0 if receipt['success'] else 1


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='action', required=True)
    preparing = sub.add_parser('prepare')
    preparing.add_argument('--output', required=True)
    preparing.add_argument('--purpose', choices=['lifecycle', 'update-component'], default='lifecycle')
    preparing.add_argument('--build-mode', choices=['debug', 'profile'], default='debug')
    for name in ('install-tools', 'build', 'run', 'export', 'import'):
        sub.add_parser(name).add_argument('--state', required=True)
    args = parser.parse_args()
    try:
        return {'prepare': prepare, 'install-tools': install_tools, 'build': build, 'run': run, 'export': export_apk, 'import': import_apk}[args.action](args) or 0
    except Exception as error:
        report = {'success': False, 'error': str(error) if isinstance(error, Refused) else type(error).__name__}
        if isinstance(error, Refused) and error.exit_code is not None:
            report.update(checkpoint=args.action, exit_code=error.exit_code)
        if isinstance(error, Refused) and error.error_class is not None:
            report['error_class'] = error.error_class
        print(json.dumps(report))
        return 2


if __name__ == '__main__':
    sys.exit(main())
