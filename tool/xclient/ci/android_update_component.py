"""Owned SAFE Android installer/storage component, separate from normal main."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import android_emulator_smoke as qa
import android_lifecycle_probe as lifecycle

PURPOSE = 'update-component'
TARGET = 'test/xboard/native/android_update_app.dart'
PACKAGE = 'com.xclient.example'
CHECKS = dict(safe_mode=True, native_hooks_enabled=True, apk_metadata=True, native_elf_abi=True, same_signer=True)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True)).encode('utf-8')


def stage_defines(base, fixture, stage, digest='', size=0):
    qa.require(isinstance(fixture, str) and re.fullmatch('[a-f0-9]{32}', fixture) and stage in ('1', '2'), 'component_compiled_identity_required')
    qa.require(type(size) is int and ((stage == '1' and isinstance(digest, str) and re.fullmatch('[a-f0-9]{64}', digest) and 0 < size <= qa.MAX_APK_BYTES) or (stage == '2' and digest == '' and size == 0)), 'component_v2_binding_required')
    context = qa.transfer_context()
    value = dict(base)
    value.pop('XC_STARTUP_QA', None)
    value.update(SAFE_MODE='true', APP_ENV='dev', XC_ANDROID_UPDATE_QA='true', XC_VERSION_NAME='1.0.0-pre.' + stage, XC_BUILD_NUMBER=str(10000400 + int(stage)), XC_ANDROID_UPDATE_FIXTURE=fixture, XC_ANDROID_UPDATE_SOURCE=context['sha'], XC_ANDROID_UPDATE_RUN=context['run_id'], XC_ANDROID_UPDATE_ATTEMPT=context['run_attempt'], XC_ANDROID_UPDATE_STAGE=stage, XC_ANDROID_UPDATE_V2_SHA256=digest, XC_ANDROID_UPDATE_V2_BYTES=str(size))
    return value


def pair_receipt(state, base, fixture, built):
    stages = {}
    for stage in ('1', '2'):
        item = built[stage]
        defines = stage_defines(base, fixture, stage, built['2']['sha256'] if stage == '1' else '', built['2']['size'] if stage == '1' else 0)
        stages[stage] = {**item, 'filename': 'app-v' + stage + '.apk', 'version': '1.0.0-pre.' + stage, 'build': 10000400 + int(stage), 'defines_sha256': hashlib.sha256(encoded(defines)).hexdigest()}
    return {'schema': 1, 'purpose': PURPOSE, **qa.transfer_context(), 'producer_job': qa.PRODUCER_JOB, 'source_hashes': state['sources'], 'baseline_defines_sha256': state['defines_sha256'], 'fixture_id': fixture, 'brand': 'example', 'package': PACKAGE, 'target': TARGET, 'build_mode': 'profile', 'stages': stages, 'checks': dict(CHECKS)}


def validate_pair(state, base, receipt):
    fields = {'schema', 'purpose', 'repository', 'run_id', 'run_attempt', 'sha', 'producer_job', 'source_hashes', 'baseline_defines_sha256', 'fixture_id', 'brand', 'package', 'target', 'build_mode', 'stages', 'checks'}
    qa.require(state.get('purpose') == PURPOSE and state['build_mode'] == 'profile', 'component_profile_purpose_required')
    qa.require(isinstance(receipt, dict) and set(receipt) == fields and type(receipt['schema']) is int and receipt['schema'] == 1, 'component_receipt_schema_required')
    qa.require(all(receipt[key] == value for key, value in qa.transfer_context().items()) and receipt['producer_job'] == qa.PRODUCER_JOB, 'component_same_run_required')
    qa.require(receipt['purpose'] == PURPOSE and receipt['source_hashes'] == state['sources'] and receipt['baseline_defines_sha256'] == state['defines_sha256'] and receipt['brand'] == 'example' and receipt['package'] == PACKAGE and receipt['target'] == TARGET and receipt['build_mode'] == 'profile', 'component_source_identity_required')
    qa.require(receipt['checks'] == CHECKS and all(value is True for value in receipt['checks'].values()), 'component_build_checks_required')
    qa.require(isinstance(receipt['stages'], dict) and set(receipt['stages']) == {'1', '2'}, 'two_component_stages_required')
    stages = receipt['stages']
    for stage, item in stages.items():
        qa.require(isinstance(item, dict) and set(item) == {'sha256', 'size', 'signer_sha256', 'app_label', 'built_ns', 'filename', 'version', 'build', 'defines_sha256'}, 'component_stage_schema_required')
        qa.require(item['filename'] == 'app-v' + stage + '.apk' and item['version'] == '1.0.0-pre.' + stage and type(item['build']) is int and item['build'] == 10000400 + int(stage), 'component_native_version_required')
        qa.require(isinstance(item['sha256'], str) and re.fullmatch('[a-f0-9]{64}', item['sha256']) and isinstance(item['signer_sha256'], str) and re.fullmatch('[a-f0-9]{64}', item['signer_sha256']) and type(item['size']) is int and 0 < item['size'] <= qa.MAX_APK_BYTES and type(item['built_ns']) is int and 0 < item['built_ns'] <= time.time_ns(), 'component_digest_size_time_required')
        qa.require(isinstance(item['app_label'], str) and 0 < len(item['app_label']) <= 100 and not any(ord(c) < 32 or c in "\x7f\r\n" for c in item['app_label']), 'component_app_label_required')
    qa.require(stages['1']['signer_sha256'] == stages['2']['signer_sha256'] and stages['1']['app_label'] == stages['2']['app_label'], 'component_same_signer_label_required')
    for stage in ('1', '2'):
        expected = stage_defines(base, receipt['fixture_id'], stage, stages['2']['sha256'] if stage == '1' else '', stages['2']['size'] if stage == '1' else 0)
        qa.require(stages[stage]['defines_sha256'] == hashlib.sha256(encoded(expected)).hexdigest(), 'component_defines_binding_required')


def control_lease(pair, stage, pid, action):
    qa.require(stage in ('1', '2') and type(pid) is int and 0 < pid <= 0x7fffffff and action in ('prepare', 'install') and (action != 'install' or stage == '1'), 'component_control_lease_required')
    return {'schema': 1, 'fixture_id': pair['fixture_id'], 'source_sha': pair['sha'], 'run_id': pair['run_id'], 'run_attempt': pair['run_attempt'], 'stage': stage, 'pid': pid, 'action': action}


def validate_hello(pair, stage, value, guest):
    expected = control_lease(pair, stage, guest['pid'], 'prepare')
    expected.pop('action')
    expected.update(native_identity=True, native_version=pair['stages'][stage]['version'], native_build=str(pair['stages'][stage]['build']), app_label=pair['stages'][stage]['app_label'])
    qa.require(isinstance(value, dict) and value == expected and type(value.get('schema')) is int and type(value.get('pid')) is int and value.get('native_identity') is True, 'component_native_hello_mismatch')


def resumed_component(activity):
    qa.require(isinstance(activity, bytes) and len(activity) <= 2 * 1024 * 1024, 'bounded_component_activity_required')
    names = set(re.findall(r'(?:mResumedActivity:|topResumedActivity=)\s*ActivityRecord\{[0-9a-f]+\s+u0\s+([A-Za-z0-9_.]+/[A-Za-z0-9_.$]+)\s+t\d+\}', activity.decode('utf-8', errors='strict')))
    qa.require(len(names) == 1, 'single_resumed_system_component_required')
    return names.pop()


def system_action(tree, activity, action, label):
    component = resumed_component(activity)
    package, cls = component.split('/')
    if action == 'permission':
        qa.require(package == 'com.android.settings' and cls in ('.Settings$ManageExternalSourcesActivity', 'com.android.settings.Settings$ManageExternalSourcesActivity'), 'owned_source_settings_required')
    else:
        qa.require(action == 'install' and package in ('com.android.packageinstaller', 'com.google.android.packageinstaller') and cls == 'com.android.packageinstaller.PackageInstallerActivity', 'owned_package_installer_required')
    qa.require(qa.visible_anr_owner(tree) is None, 'component_system_anr_refused')
    nodes = list(tree.iter('node'))
    qa.require(len([n for n in nodes if n.get('package') == package and qa.ui_label(n).strip() == label]) == 1, 'owned_app_system_label_required')
    if action == 'permission':
        qa.require(len([n for n in nodes if n.get('package') == package and qa.ui_label(n).strip() == 'Allow from this source']) == 1, 'source_permission_control_required')
        buttons = [n for n in nodes if n.get('package') == package and n.get('class') in ('android.widget.Switch', 'android.widget.CompoundButton') and n.get('checkable') == 'true' and n.get('checked') == 'false' and n.get('enabled') == 'true' and n.get('resource-id') in ('com.android.settings:id/switch_widget', 'android:id/switch_widget')]
    else:
        qa.require(len([n for n in nodes if n.get('package') == package and n.get('resource-id') == 'android:id/button2' and qa.ui_label(n).strip() == 'Cancel']) == 1, 'installer_cancel_control_required')
        buttons = [n for n in nodes if n.get('package') == package and n.get('resource-id') == 'android:id/button1' and qa.ui_label(n).strip() in ('Update', 'Install') and n.get('enabled') == 'true']
    qa.require(len(buttons) == 1, 'unique_system_action_required')
    return {'package': package, 'component': component, 'center': qa.node_center(buttons[0])}


def load(args, role=None):
    state, output = qa.load_state(args.state)
    qa.require(state.get('purpose') == PURPOSE and state['build_mode'] == 'profile', 'component_profile_purpose_required')
    if role is not None:
        qa.require(os.environ.get('GITHUB_JOB') == role, 'component_job_role_required')
    return state, output


def base_defines(output):
    return json.loads((output / 'private/defines.json').read_text(encoding='utf-8'))


class SignerRefused(qa.Refused):
    def __init__(self, code, diagnostic):
        super().__init__(code)
        self.diagnostic = diagnostic


# apksigner through build-tools 36 prints "Signer #1"; 37 names the scheme
# that verified the APK ("V2 Signer:"), or "Signer #N:" for several signers.
_DIGEST_LINE = re.compile(r'^(.*) certificate SHA-256 digest: (.*?)\s*$', re.M)
_PRIMARY_SIGNER = re.compile(r'Signer #1|(?:V1 |V2 |V3\.0 )?Signer:')


def signer_digest(certs, diagnostic):
    """The one SHA-256 digest of the APK's only signer, from --print-certs."""
    lines = _DIGEST_LINE.findall(certs.decode('utf-8', errors='replace')) if len(certs) <= 32768 else []
    digests = [digest for _, digest in lines if re.fullmatch('[a-f0-9]{64}', digest)]
    primary = [label for label, _ in lines if _PRIMARY_SIGNER.fullmatch(label)]
    if len(certs) > 32768 or len(lines) != 1 or len(digests) != 1 or len(primary) != 1:
        raise SignerRefused('single_component_signer_required', dict(diagnostic, apksigner_exit_code=0, output_bytes=len(certs), digest_lines=len(lines), primary_signer_lines=len(primary), distinct_digests=len(set(digests))))
    return digests[0]


def apk_info(state, path, stage):
    qa.validate_apk(path, 'profile')
    sdk = Path(state['sdk'])
    text = qa.command([qa.aapt_tool(sdk), 'dump', 'badging', path]).decode('utf-8')
    qa.require(len(text) <= 128 * 1024, 'bounded_component_metadata_required')
    expected = r"^package: name='com\.xclient\.example' versionCode='" + str(10000400 + int(stage)) + r"' versionName='1\.0\.0-pre\." + stage + "'"
    qa.require(re.search(expected, text, re.M) and re.search(r"^launchable-activity: name='com\.follow\.clash\.MainActivity'", text, re.M) and re.search(r'^application-debuggable\s*$', text, re.M), 'component_apk_identity_required')
    labels = re.findall(r"^application-label:'([^'\r\n]{1,100})'\s*$", text, re.M)
    qa.require(len(labels) == 1, 'component_apk_label_required')
    signer_tool = qa.aapt_tool(sdk).with_name('apksigner')
    qa.require(signer_tool.is_file() and signer_tool.resolve().is_relative_to(sdk), 'sdk_apksigner_required')
    diagnostic = dict(stage=stage, build_tools=signer_tool.parent.name)
    try:
        certs = qa.command([signer_tool, 'verify', '--print-certs', path])
    except qa.Refused as error:
        raise SignerRefused('component_signer_tool_failed', dict(diagnostic, apksigner_exit_code=error.exit_code)) from None
    return dict(sha256=qa.sha(path), size=path.stat().st_size, signer_sha256=signer_digest(certs, diagnostic), app_label=labels[0])


def read_pair(state, output):
    file = output / 'private/update-pair.json'
    qa.require(file.is_file() and not file.is_symlink() and file.stat().st_size <= 65536, 'owned_component_pair_required')
    pair = json.loads(file.read_text(encoding='utf-8'))
    validate_pair(state, base_defines(output), pair)
    return pair


def validate_staged(state, output, built):
    pair = read_pair(state, output)
    fields = {'origin', 'job', 'nonce', 'artifact_id', 'pair_sha256'}
    qa.require(isinstance(built, dict) and set(built) == fields and built['job'] == state['job'] and built['nonce'] == state['nonce'] and built['pair_sha256'] == qa.sha(output / 'private/update-pair.json'), 'component_build_owner_required')
    if built['origin'] == 'same-run-component':
        qa.require(os.environ.get('GITHUB_JOB') == qa.CONSUMER_JOB and built['artifact_id'] == qa.artifact_id(), 'component_consumer_artifact_required')
    else:
        qa.require(built['origin'] == 'local-component' and os.environ.get('GITHUB_JOB') == qa.PRODUCER_JOB and built['artifact_id'] is None, 'component_producer_required')
    for stage in ('1', '2'):
        path = output / 'private' / pair['stages'][stage]['filename']
        qa.require(path.is_file() and not path.is_symlink() and path.resolve() == path and path.stat().st_size == pair['stages'][stage]['size'] and qa.sha(path) == pair['stages'][stage]['sha256'], 'component_staged_bytes_required')
        qa.validate_apk(path, 'profile')
    return output / 'private/app-v1.apk'


def build(args):
    state, output = load(args, qa.PRODUCER_JOB)
    qa.require(os.environ.get('XCLIENT_BRAND') == 'example', 'example_native_brand_required')
    version = json.loads(qa.command(['flutter', '--version', '--machine'], timeout=120))
    qa.require(version.get('frameworkVersion') == '3.47.6' and version.get('dartSdkVersion', '').split()[0] == '3.13.5', 'pinned_flutter_sdk_required')
    base, fixture, built = base_defines(output), secrets.token_hex(16), {}
    for stage in ('2', '1'):
        defines = stage_defines(base, fixture, stage, built['2']['sha256'] if stage == '1' else '', built['2']['size'] if stage == '1' else 0)
        define_file = output / 'private' / ('v' + stage + '-defines.json')
        qa.write_json(define_file, defines)
        started = time.time_ns()
        result = subprocess.run(['flutter', 'build', 'apk', '--profile', '--target-platform', 'android-x64', '--target=' + TARGET, '--build-name=1.0.0-pre.' + stage, '--build-number=' + str(10000400 + int(stage)), '--dart-define-from-file=' + str(define_file)], cwd=qa.ROOT, timeout=4800)
        qa.require(result.returncode == 0, 'component_native_build_failed')
        load(args, qa.PRODUCER_JOB)
        source = qa.ROOT / 'build/app/outputs/flutter-apk/app-profile.apk'
        qa.require(source.is_file() and source.resolve() == source and source.stat().st_mtime_ns > started, 'fresh_component_apk_required')
        try:
            info = apk_info(state, source, stage)
        except SignerRefused as error:
            qa.write_json(output / 'receipts/component-signer.json', error.diagnostic)
            raise
        destination = output / 'private' / ('app-v' + stage + '.apk')
        with source.open('rb') as reader, destination.open('xb') as writer:
            shutil.copyfileobj(reader, writer, 1024 * 1024)
        destination.chmod(0o600)
        qa.require(qa.sha(destination) == info['sha256'] == qa.sha(source), 'component_staged_bytes_required')
        built[stage] = {**info, 'built_ns': time.time_ns()}
    pair = pair_receipt(state, base, fixture, built)
    validate_pair(state, base, pair)
    qa.write_json(output / 'private/update-pair.json', pair)
    qa.write_json(output / 'private/build.json', dict(origin='local-component', job=state['job'], nonce=state['nonce'], artifact_id=None, pair_sha256=qa.sha(output / 'private/update-pair.json')))
    validate_staged(state, output, json.loads((output / 'private/build.json').read_text()))
    qa.write_json(output / 'receipts/component-build.json', pair)
    print(json.dumps({'component_pair_built': True, 'actual_same_signer': True}))


def pair_files(directory):
    qa.require(directory.is_dir() and {p.name for p in directory.iterdir()} == {'app-v1.apk', 'app-v2.apk', 'build-receipt.json'}, 'component_transfer_allowlist_required')
    for path in directory.iterdir():
        qa.require(path.is_file() and not path.is_symlink() and path.resolve() == path and 0 < path.stat().st_size <= (65536 if path.suffix == '.json' else qa.MAX_APK_BYTES), 'regular_bounded_component_file_required')
    return directory


def export(args):
    state, output = load(args, qa.PRODUCER_JOB)
    pair = read_pair(state, output)
    built = json.loads((output / 'private/build.json').read_text())
    qa.require(built['origin'] == 'local-component', 'component_native_export_required')
    validate_staged(state, output, built)
    directory = qa.scoped(output / 'export')
    directory.mkdir(mode=0o700)
    for stage in ('1', '2'):
        name = pair['stages'][stage]['filename']
        with (output / 'private' / name).open('rb') as reader, (directory / name).open('xb') as writer:
            shutil.copyfileobj(reader, writer, 1024 * 1024)
        qa.require(qa.sha(directory / name) == pair['stages'][stage]['sha256'], 'component_export_bytes_required')
    qa.write_json(directory / 'build-receipt.json', pair)
    pair_files(directory)


def import_pair(args):
    state, output = load(args, qa.CONSUMER_JOB)
    identity = qa.artifact_id()
    incoming = pair_files(qa.scoped(output / 'incoming'))
    pair = json.loads((incoming / 'build-receipt.json').read_text(encoding='utf-8'))
    validate_pair(state, base_defines(output), pair)
    for stage in ('1', '2'):
        item = pair['stages'][stage]
        source = incoming / item['filename']
        actual = apk_info(state, source, stage)
        qa.require(all(actual[key] == item[key] for key in actual), 'component_import_native_bytes_required')
        destination = output / 'private' / item['filename']
        with source.open('rb') as reader, destination.open('xb') as writer:
            shutil.copyfileobj(reader, writer, 1024 * 1024)
        qa.require(qa.sha(destination) == item['sha256'], 'component_import_bytes_required')
    qa.write_json(output / 'private/update-pair.json', pair)
    built = dict(origin='same-run-component', job=state['job'], nonce=state['nonce'], artifact_id=identity, pair_sha256=qa.sha(output / 'private/update-pair.json'))
    qa.write_json(output / 'private/build.json', built)
    validate_staged(state, output, built)
    qa.write_json(output / 'receipts/build-origin.json', {'artifact_id': identity, **pair})


# A receipt the guest renames into place is whole, so an unparsable read is
# retried only a few times before it fails as itself rather than as missing.
INVALID_RECEIPT_READS = 3


class _ReceiptInvalid(Exception):
    def __init__(self, size):
        super().__init__('component_receipt_json_invalid')
        self.size = size


class ComponentDriver:
    def __init__(self, device, state, output):
        self.device, self.state, self.output = device, state, output
        self.pair = read_pair(state, output)
        self.relative = 'cache/xclient-update-qa-' + self.pair['fixture_id']
        self.guest = None
        self.system_owners = {}
        self.report = {'success': False, 'purpose': PURPOSE, 'synthetic_cleanup_verified': False, 'system_actions': [], 'test_driven_v2_reopen': False, 'old_install_future_success_claimed': False}

    def verify(self):
        self.device.verify_owned()
        if self.guest is not None:
            qa.require(lifecycle.guest_identity(self.device) == self.guest, 'component_guest_generation_changed')

    def run_as(self, script, *, data=b'', timeout=45):
        """Runs [script] as the app over the shell protocol.

        exec-out neither forwards stdin nor returns the guest exit status, and
        it mixes stderr into stdout; `shell -T` does all three without a pty.
        """
        return self.device.call('shell', '-T', 'run-as', PACKAGE, 'sh', '-c', shlex.quote(script), data=data, timeout=timeout)

    def read(self, name):
        qa.require(re.fullmatch(r'[A-Za-z0-9-]{1,80}\.json', name), 'component_receipt_name_required')
        self.verify()
        path = self.relative + '/' + name
        script = 'if [ ! -e ' + path + ' ]; then printf missing; elif [ -f ' + path + ' ] && [ ! -L ' + path + ' ] && [ "$(wc -c < ' + path + ')" -le 16384 ]; then cat ' + path + '; else exit 3; fi'
        try:
            raw = self.run_as(script)
        except qa.Refused as error:
            if error.exit_code is None:
                raise
            self.report['receipt_failure'] = {'file': name, 'exit_code': error.exit_code}
            raise qa.Refused('component_receipt_not_regular' if error.exit_code == 3 else 'component_receipt_read_failed') from None
        qa.require(len(raw) <= 16384, 'bounded_component_receipt_required')
        if raw == b'missing':
            return None
        try:
            return json.loads(raw.decode('utf-8'))
        except ValueError:
            raise _ReceiptInvalid(len(raw)) from None

    def wait(self, name, stage, *, timeout=120):
        self.report['step'] = name
        deadline = time.monotonic() + timeout
        invalid = {}

        def refuse_invalid(receipt):
            attempts, size = invalid[receipt]
            self.report['receipt_failure'] = {'file': receipt, 'bytes': size, 'attempts': attempts}
            raise qa.Refused('component_receipt_json_invalid')

        def read(receipt):
            try:
                value = self.read(receipt)
            except _ReceiptInvalid as error:
                invalid[receipt] = (invalid.get(receipt, (0, 0))[0] + 1, error.size)
                self.report['receipt_invalid_reads'] = self.report.get('receipt_invalid_reads', 0) + 1
                if invalid[receipt][0] >= INVALID_RECEIPT_READS or time.monotonic() >= deadline:
                    refuse_invalid(receipt)
                return None
            invalid.pop(receipt, None)
            return value

        while time.monotonic() < deadline:
            failure = read('failure-' + stage + '.json')
            if failure is not None:
                expected = control_lease(self.pair, stage, self.guest['pid'], 'prepare')
                expected.pop('action')
                allowed_phases = {'identity', 'prepareLease', 'initialStore', 'installArm', 'crossStore', 'archive', 'permission', 'install', 'complete'}
                allowed_errors = {'contract.configuration', 'contract.nativeIdentity', 'contract.payload', 'contract.lease', 'contract.staleLease', 'file', 'timeout', 'store', 'archive', 'permission', 'oldVersion', 'platform', 'fileSystem', 'installer', 'unknown'}
                qa.require(isinstance(failure, dict) and set(failure) == set(expected) | {'phase', 'error_class', 'synthetic_cleanup_confirmed'} and all(failure.get(k) == v for k, v in expected.items()) and failure.get('phase') in allowed_phases and failure.get('error_class') in allowed_errors and type(failure.get('synthetic_cleanup_confirmed')) is bool, 'native_component_failure_schema_required')
                self.report['native_failure'] = {k: failure[k] for k in ('phase', 'error_class', 'synthetic_cleanup_confirmed')}
                raise qa.Refused('native_component_stage_failed')
            value = read(name)
            if value is not None:
                qa.require(time.monotonic() < deadline, 'component_receipt_timeout')
                return value
            time.sleep(0.5)
        for receipt in invalid:
            refuse_invalid(receipt)
        raise qa.Refused('component_receipt_timeout')

    def stage_bytes(self, name, data):
        qa.require(name in ('v1.apk', 'v2.apk', 'lease-1.json', 'lease-2.json', 'arm-1.json'), 'component_control_name_required')
        self.report['step'] = name
        self.verify()
        path = self.relative + '/' + name
        script = 'umask 077; test -d ' + self.relative + ' && test ! -L ' + self.relative + ' && test ! -e ' + path + ' && test ! -e ' + path + '.pending && cat > ' + path + '.pending && mv ' + path + '.pending ' + path
        diagnostic = {'step': name, 'bytes': len(data)}

        def refuse(code, **fields):
            self.report['control_failure'] = dict(diagnostic, **fields)
            raise qa.Refused(code)

        try:
            self.run_as(script, data=data, timeout=120)
        except qa.Refused as error:
            if error.exit_code is None:
                raise
            refuse('component_guest_control_write_failed', adb_exit_code=error.exit_code)
        self.verify()
        try:
            raw = self.run_as('wc -c < ' + path + ' && sha256sum ' + path)
        except qa.Refused as error:
            if error.exit_code is None:
                raise
            refuse('component_guest_control_readback_failed', adb_exit_code=error.exit_code)
        lines = raw.decode('ascii', errors='replace').splitlines() if len(raw) <= 1024 else []
        size = lines[0].strip() if lines else ''
        actual = lines[1].split() if len(lines) > 1 else []
        guest_bytes = int(size) if size.isdigit() else None
        matches = len(actual) == 2 and actual[0] == hashlib.sha256(data).hexdigest() and actual[1] == path
        if guest_bytes != len(data) or not matches:
            refuse('component_guest_control_hash_mismatch', adb_exit_code=0, readback_bytes=len(raw), guest_bytes=guest_bytes, guest_empty=guest_bytes == 0, digest_matches=matches)

    def arm(self, stage, action):
        name = ('lease-' if action == 'prepare' else 'arm-') + stage + '.json'
        self.stage_bytes(name, encoded(control_lease(self.pair, stage, self.guest['pid'], action)))

    def proof(self, name, stage, fields):
        value = self.wait(name, stage)
        expected = control_lease(self.pair, stage, self.guest['pid'], 'prepare')
        expected.pop('action')
        qa.require(isinstance(value, dict) and set(value) == set(expected) | set(fields) and all(value.get(key) == val for key, val in expected.items()) and type(value.get('pid')) is int and type(value.get('schema')) is int and all(value.get(key) is True for key in fields), 'component_native_proof_mismatch')
        return {key: True for key in fields}

    def store_proofs(self, stage, operations):
        results = []
        for index, (operation, method) in enumerate(operations, 1):
            for event in ('begin', 'nativeReturn', 'end'):
                name = 'store-' + stage + '-' + str(index).zfill(2) + '-' + event + '.json'
                value = self.wait(name, stage)
                fields = {'stage', 'id', 'operation', 'event', 'outcome', 'started_ms', 'elapsed_ms'} | ({'method', 'late'} if event == 'nativeReturn' else set())
                qa.require(isinstance(value, dict) and set(value) == fields and value.get('stage') == stage and type(value.get('id')) is int and value['id'] == index and value.get('operation') == operation and value.get('event') == event and value.get('outcome') == ('pending' if event == 'begin' else 'success') and type(value.get('started_ms')) is int and value['started_ms'] > 0 and type(value.get('elapsed_ms')) is int and 0 <= value['elapsed_ms'] <= 15000 and (event != 'nativeReturn' or (value.get('method') == method and value.get('late') is False)), 'native_store_proof_mismatch')
                results.append(value)
        qa.write_json(self.output / 'receipts' / ('component-store-' + stage + '.json'), results)

    def attest_system(self, package):
        qa.require(package in ('com.android.settings', 'com.android.packageinstaller', 'com.google.android.packageinstaller'), 'approved_system_package_required')
        self.device.verify_owned()
        raw = self.device.call('shell', 'pm', 'path', package)
        qa.require(len(raw) <= 2048 and raw.isascii(), 'bounded_system_package_path_required')
        match = re.fullmatch(rb'package:(/(?:system|system_ext|product)/(?:priv-app|app)/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.apk)\r?\n?', raw)
        qa.require(match is not None, 'preinstalled_system_package_required')
        path = match[1].decode('ascii')
        actual = self.device.call('shell', 'sha256sum', path).decode('ascii').split()
        qa.require(len(actual) == 2 and re.fullmatch('[a-f0-9]{64}', actual[0]) and actual[1] == path, 'system_package_bytes_unconfirmed')
        owner = {'apk_sha256': actual[0], 'path': path}
        previous = self.system_owners.setdefault(package, owner)
        qa.require(previous == owner, 'system_package_owner_changed')

    def observe_system(self, action):
        tree = self.device.ui()
        activity = self.device.call('shell', 'dumpsys', 'activity', 'activities')
        return system_action(tree, activity, action, self.pair['stages']['1']['app_label'])

    def tap_system(self, action):
        self.report['step'] = 'system-' + action
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            self.verify()
            try:
                observed = self.observe_system(action)
            except qa.Refused:
                time.sleep(1)
                continue
            self.attest_system(observed['package'])
            capture = self.device.capture('component-before-' + action)
            self.verify()
            confirmed = self.observe_system(action)
            qa.require(confirmed == observed and time.monotonic() < deadline, 'system_action_window_changed')
            qa.require(0 < confirmed['center'][0] < capture['width'] and 0 < confirmed['center'][1] < capture['height'], 'visible_system_action_required')
            self.attest_system(confirmed['package'])
            self.device.call('shell', 'input', 'tap', *confirmed['center'])
            self.report['system_actions'].append({'action': action, 'package': observed['package'], 'component': observed['component'], 'system_apk_sha256': self.system_owners[observed['package']]['apk_sha256'], 'owned_app_label_rechecked': True, 'window_rechecked': True})
            return
        raise qa.Refused('owned_system_action_timeout')

    def return_from_permission(self):
        self.verify()
        tree = self.device.ui()
        activity = self.device.call('shell', 'dumpsys', 'activity', 'activities')
        component = resumed_component(activity)
        qa.require(component in ('com.android.settings/.Settings$ManageExternalSourcesActivity', 'com.android.settings/com.android.settings.Settings$ManageExternalSourcesActivity'), 'source_settings_return_owner_required')
        nodes = list(tree.iter('node'))
        qa.require(len([n for n in nodes if n.get('package') == 'com.android.settings' and qa.ui_label(n).strip() == self.pair['stages']['1']['app_label']]) == 1, 'source_settings_app_label_changed')
        qa.require(len([n for n in nodes if n.get('package') == 'com.android.settings' and n.get('checkable') == 'true' and n.get('checked') == 'true' and n.get('resource-id') in ('com.android.settings:id/switch_widget', 'android:id/switch_widget')]) == 1, 'source_settings_permission_not_checked')
        self.attest_system('com.android.settings')
        self.device.capture('component-source-enabled')
        # Back only after the current owned Settings screen is proven, never
        # using the default App-only tap method for a foreign node.
        qa.require(resumed_component(self.device.call('shell', 'dumpsys', 'activity', 'activities')) == component, 'source_settings_return_owner_changed')
        self.device.call('shell', 'input', 'keyevent', 'KEYCODE_BACK')

    def await_v2_bytes(self):
        self.report['step'] = 'v2-installed'
        deadline = time.monotonic() + 180
        while time.monotonic() < deadline:
            self.device.verify_owned()
            raw = self.device.call('shell', 'pm', 'path', PACKAGE)
            if raw.strip():
                path, _ = qa.installed_base_apk(raw, package=PACKAGE)
                actual = self.device.call('shell', 'sha256sum', shlex.quote(path)).decode('ascii').split()
                qa.require(len(actual) == 2 and actual[1] == path, 'installed_component_path_changed')
                if actual[0] == self.pair['stages']['2']['sha256']:
                    qa.require(time.monotonic() < deadline, 'native_component_update_timeout')
                    self.report['installed_v2_bytes_verified'] = True
                    return
                qa.require(actual[0] == self.pair['stages']['1']['sha256'], 'unexpected_installed_component_bytes')
            time.sleep(1)
        raise qa.Refused('native_component_update_timeout')

    def run(self):
        qa.require(self.device.package == PACKAGE, 'component_profile_package_required')
        self.device.start()
        self.guest = lifecycle.guest_identity(self.device)
        hello = self.wait('hello-1.json', '1')
        validate_hello(self.pair, '1', hello, self.guest)
        self.device.capture('component-v1')
        self.arm('1', 'prepare')
        self.report.update(self.proof('ready-1.json', '1', ('synthetic_created_verified',)))
        self.store_proofs('1', (('initialRead', 'read'), ('initialWrite', 'write'), ('initialVerify', 'read')))
        for stage in ('1', '2'):
            path = self.output / 'private' / self.pair['stages'][stage]['filename']
            qa.require(path.is_file() and not path.is_symlink() and path.resolve() == path, 'regular_component_guest_source_required')
            data = path.read_bytes()
            item = self.pair['stages'][stage]
            qa.require(len(data) == item['size'] and hashlib.sha256(data).hexdigest() == item['sha256'], 'component_guest_source_bytes_changed')
            self.stage_bytes('v' + stage + '.apk', data)
        self.arm('1', 'install')
        self.tap_system('permission')
        self.return_from_permission()
        self.report.update(self.proof('archive-1.json', '1', ('old_archive_bound', 'next_archive_bound', 'v2_hash_verified')))
        self.report.update(self.proof('permission-1.json', '1', ('source_permission_verified', 'same_version_refused')))
        self.report.update(self.proof('pending-user-1.json', '1', ('native_pending_user',)))
        self.tap_system('install')
        old = self.guest
        self.await_v2_bytes()
        self.guest = None
        self.device.start()
        self.report['test_driven_v2_reopen'] = True
        self.guest = lifecycle.guest_identity(self.device)
        qa.require(self.guest != old, 'component_old_guest_survived_update')
        validate_hello(self.pair, '2', self.wait('hello-2.json', '2'), self.guest)
        self.report['new_guest_generation_verified'] = True
        self.arm('2', 'prepare')
        self.report.update(self.proof('verified-2.json', '2', ('canonical_identity', 'synthetic_read', 'synthetic_replace', 'synthetic_delete')))
        self.store_proofs('2', (('crossRead', 'read'), ('replacementWrite', 'write'), ('replacementRead', 'read'), ('cleanupDelete', 'delete'), ('cleanupRead', 'read')))
        self.report['synthetic_cleanup_verified'] = self.report['synthetic_delete']
        self.device.capture('component-v2-verified')
        self.verify()
        self.report['success'] = True
        qa.write_json(self.output / 'receipts/component-result.json', self.report)
        return self.report


def run_component(device, state, output, receipt):
    driver = ComponentDriver(device, state, output)
    try:
        return driver.run()
    finally:
        receipt['component_step'] = driver.report.get('step')
        path = output / 'receipts/component-result.json'
        if not path.exists():
            qa.write_json(path, driver.report)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('action', choices=('build', 'export', 'import'))
    parser.add_argument('--state', required=True)
    args = parser.parse_args()
    try:
        {'build': build, 'export': export, 'import': import_pair}[args.action](args)
        return 0
    except Exception as error:
        report = {'success': False, 'error': str(error) if isinstance(error, qa.Refused) else type(error).__name__}
        if isinstance(error, SignerRefused):
            report['signer'] = error.diagnostic
        print(json.dumps(report))
        return 1


if __name__ == '__main__':
    sys.exit(main())
