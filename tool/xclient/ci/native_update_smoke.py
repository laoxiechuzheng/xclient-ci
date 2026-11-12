#!/usr/bin/env python3
import argparse
import ctypes
import hashlib
import http.server
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import threading
import time
import zlib

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_store_smoke as guard
import macos_signing_fixture as mac_signing
import macos_data_keychain as data_keychain
import macos_keychain_confirmation as keychain_confirmation
from macos_signing_fixture import designated_requirement, requirement_diagnostic, requirement_matches, stage_requirement

ROOT = guard.ROOT
TARGET = ROOT / 'test/xboard/native/update_app.dart'
CONTRACT = ROOT / 'test/xboard/native/update_qa_contract.dart'
STORE_OBSERVER = ROOT / 'test/xboard/native/update_store_observer.dart'
GUID = 'F80D284D-D28E-4BE5-902D-97972AB748C7'
SERVICE = 'XClientexampleHelperService'
PACKAGING_FILES = ('windows/packaging/exe/make_config.yaml', 'windows/packaging/exe/inno_setup.iss', 'pubspec.yaml', 'distribute_options.yaml', 'windows/runner/main.cpp')


def identity_query_disappeared(error):
    return (isinstance(error, subprocess.CalledProcessError) and error.returncode == 1) or (isinstance(error, guard.Refused) and str(error) == 'process_identity_unavailable')


class OwnerObservationError(guard.Refused):
    def __init__(self, owner, phase, error, current=None):
        ownership_mismatch = isinstance(error, guard.Refused) and str(error) == 'cleanup_owner_mismatch'
        super().__init__('cleanup_owner_mismatch' if ownership_mismatch else 'owned_process_identity_unavailable')
        self.pid, self.phase, self.kind = owner['pid'], phase, fixture_exception_kind(error)
        matched_pid_start = current is not None and current.get('pid') == owner['pid'] and current.get('started') == owner['started']
        query_disappeared = current is None and identity_query_disappeared(error)
        self.direct_exit_retry = phase in ('observeOwner', 'observeParent') and ((ownership_mismatch and matched_pid_start) or query_disappeared)


def fixture_exception_kind(error):
    if isinstance(error, OwnerObservationError):
        return error.kind
    for kind, name in ((subprocess.CalledProcessError, 'calledProcessError'), (subprocess.TimeoutExpired, 'processTimeout'), (guard.Refused, 'refused'), (FileNotFoundError, 'fileNotFound'), (PermissionError, 'permission'), (OSError, 'osError'), (KeyError, 'keyError'), (TypeError, 'typeError'), (ValueError, 'valueError')):
        if isinstance(error, kind):
            return name
    return 'other'


def validate_stage(stage):
    guard.require(stage in ('1', '2'), 'fixed_upgrade_stage_required')
    return '1.0.0-pre.' + stage, '1000040' + stage


def verify_pair(first, second):
    for field in ('payload_sha256', 'executable_sha256', 'cdhash'):
        if field != 'cdhash' or first.get(field) is not None:
            guard.require(first.get(field) and second.get(field) and first[field] != second[field], 'distinct_native_versions_required')
    return True


def validate_owner(expected, current):
    guard.require(isinstance(expected, dict) and expected == current, 'cleanup_owner_mismatch')
    return True


def executable_kind(expected, observed):
    if not isinstance(observed, str):
        return 'unavailable'
    name = Path(expected).name
    if observed == expected:
        return 'exact'
    if observed == name:
        return 'basename'
    if observed in ('(' + name + ')', '(' + name + ') <defunct>'):
        return 'defunctName'
    return 'sameBasename' if Path(observed).name == name else 'other'


def parse_mac_process_snapshot(owner, raw):
    parts = raw.strip().split(None, 8)
    if len(parts) != 9 or not parts[0].isdigit() or not parts[1].isdigit() or int(parts[0]) != owner['pid']:
        return {'state': 'unavailable'}
    states = {'Z': 'zombie', 'R': 'running', 'S': 'sleeping', 'I': 'idle', 'T': 'stopped', 'U': 'uninterruptible'}
    return {'state': states.get(parts[2][:1], 'other'), 'parent_pid': int(parts[1]), 'snapshot_start_matches': ' '.join(parts[3:8]) == ' '.join(owner['started'].split()), 'snapshot_executable_kind': executable_kind(owner['executable'], parts[8])}


def mac_process_snapshot(owner):
    if sys.platform != 'darwin':
        return {'state': 'unavailable'}
    try:
        process = subprocess.run(['/bin/ps', '-ww', '-p', str(owner['pid']), '-o', 'pid=,ppid=,stat=,lstart=,comm='], capture_output=True, text=True, timeout=2)
        if process.returncode == 1 and not process.stdout.strip():
            return {'state': 'absent'}
        if process.returncode == 0 and len(process.stdout) <= 8192:
            return parse_mac_process_snapshot(owner, process.stdout)
    except Exception:
        pass
    return {'state': 'unavailable'}


def validate_observed_owner(owner, current, phase, mismatch=None):
    try:
        return validate_owner(owner, current)
    except guard.Refused:
        if mismatch is not None:
            try:
                diagnostic = {'phase': phase, 'pid': owner['pid'], 'pid_matches': current.get('pid') == owner['pid'], 'executable_matches': current.get('executable') == owner['executable'], 'started_matches': current.get('started') == owner['started'], 'observed_executable_kind': executable_kind(owner['executable'], current.get('executable')), **mac_process_snapshot(owner)}
                mismatch(diagnostic)
            except Exception:
                pass
        raise


def command(arguments, *, environment=None, timeout=180):
    if str(arguments[0]) == 'dart':
        sdk = Path(os.environ.get('FLUTTER_ROOT', '')) / 'bin/cache/dart-sdk/bin' / ('dart.exe' if sys.platform == 'win32' else 'dart')
        resolved = str(sdk) if sdk.is_file() else shutil.which('dart')
        guard.require(resolved is not None and (sys.platform != 'win32' or Path(resolved).suffix.lower() == '.exe'), 'native_dart_sdk_required')
        arguments = [resolved, *arguments[1:]]
    result = subprocess.run([str(value) for value in arguments], cwd=ROOT, env=environment, capture_output=True, timeout=timeout)
    guard.require(result.returncode == 0, 'fixture_command_failed')
    return result.stdout.decode('utf-8', errors='replace').strip()


def private_path(output, value):
    path = Path(value).absolute()
    guard.require(path == path.resolve() and path.is_relative_to(output / 'private'), 'private_path_rejected')
    return path


def json_file(path):
    guard.require(path.is_file() and not path.is_symlink(), 'regular_json_required')
    value = json.loads(path.read_text(encoding='utf-8'))
    guard.require(isinstance(value, dict), 'json_object_required')
    return value


def load(args):
    job = guard.ci_identity(args.platform)
    file = guard.scoped(args.state)
    state = json_file(file)
    output = guard.scoped(state['output'])
    guard.require(file == output / 'private/state.json' and state['job'] == job and state['platform'] == args.platform, 'prepared_job_mismatch')
    guard.require((output / '.native-update-owned').read_text(encoding='utf-8') == state['nonce'] and re.fullmatch('[0-9a-f]{32}', state['nonce']), 'owned_marker_mismatch')
    guard.require(0 <= time.time_ns() - state['prepared_ns'] < 7200 * 10**9, 'stale_fixture')
    guard.require(guard.digest(TARGET) == state['target_sha256'] and guard.digest(CONTRACT) == state['contract_sha256'] and guard.digest(STORE_OBSERVER) == state['observer_sha256'], 'qa_source_changed')
    mac_signing.validate_mode(args.platform, state['macos_signing'])
    guard.require(guard.digest(mac_signing.SOURCE) == state['signer_source_sha256'], 'signing_source_changed')
    data_keychain.validate_mode(args.platform, state['macos_signing'], state['macos_confirmation'])
    guard.require(state['confirmation_sources'] == data_keychain.source_hashes(), 'confirmation_source_changed')
    return state, output


def generate_fixture_certificate(private):
    openssl = shutil.which('openssl')
    if openssl is None and sys.platform == 'win32':
        candidate = Path(os.environ.get('ProgramFiles', r'C:\Program Files')) / 'Git/usr/bin/openssl.exe'
        openssl = str(candidate) if candidate.is_file() else None
    guard.require(openssl is not None, 'existing_openssl_required')
    names = ('ca.key', 'ca.crt', 'ca.srl', 'server.key', 'server.csr', 'server.crt', 'server-chain.crt', 'request.cnf', 'server-extensions.cnf')
    guard.require(all(not (private / name).exists() and not (private / name).is_symlink() for name in names), 'fresh_certificate_files_required')
    request = private / 'request.cnf'
    with request.open('x', encoding='ascii') as config:
        config.write('[req]\nprompt=no\ndistinguished_name=dn\n[dn]\nCN=XClient CI Test\n[ca_extensions]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
    command([openssl, 'req', '-config', request, '-extensions', 'ca_extensions', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1', '-keyout', private / 'ca.key', '-out', private / 'ca.crt', '-subj', '/CN=XClient CI Test Root'])
    command([openssl, 'req', '-config', request, '-new', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-keyout', private / 'server.key', '-out', private / 'server.csr', '-subj', '/CN=localhost'])
    with (private / 'server-extensions.cnf').open('x', encoding='ascii') as extensions:
        extensions.write('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n')
    command([openssl, 'x509', '-req', '-in', private / 'server.csr', '-CA', private / 'ca.crt', '-CAkey', private / 'ca.key', '-CAcreateserial', '-out', private / 'server.crt', '-days', '1', '-sha256', '-extfile', private / 'server-extensions.cnf'])
    with (private / 'server-chain.crt').open('xb') as chain:
        chain.write((private / 'server.crt').read_bytes() + (private / 'ca.crt').read_bytes())
    return openssl


def prepare(args):
    mac_signing.validate_mode(args.platform, args.macos_signing)
    data_keychain.validate_mode(args.platform, args.macos_signing, args.macos_confirmation)
    job = guard.ci_identity(args.platform)
    output = guard.scoped(args.output)
    guard.require(not output.exists(), 'new_output_required')
    output.mkdir(parents=True, mode=0o700)
    private = output / 'private'
    private.mkdir(mode=0o700)
    (output / 'receipts').mkdir()
    nonce = secrets.token_hex(16)
    (output / '.native-update-owned').write_text(nonce, encoding='utf-8')
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    generate_fixture_certificate(private)
    keys = {kind: json.loads(command(['dart', 'tool/xclient/xsign.dart', 'keygen', 'qa-' + kind, '--out', private / (kind + '.seed')])) for kind in ('ctrl', 'rel')}
    brands = private / 'brands'
    shutil.copytree(ROOT / 'brands/example', brands / 'example')
    brand_file = brands / 'example/brand.json'
    brand = json_file(brand_file)
    brand.update({'builtin_api_endpoints': [{'url': f'https://localhost:{port}', 'weight': 100}], 'bootstrap_sources': [], 'doh_names': [], 'ctrl_pub_keys': {keys['ctrl']['kid']: keys['ctrl']['pub']}, 'rel_pub_keys': {keys['rel']['kid']: keys['rel']['pub']}})
    brand_file.write_text(json.dumps(brand), encoding='utf-8')
    executable = private / ('installed/ExampleClient.exe' if args.platform == 'windows' else 'installed/ExampleClient.app/Contents/MacOS/ExampleClient')
    config = {'nonce': nonce, 'job': job, 'output': str(output), 'installed_executable': str(executable), 'certificate': str(private / 'ca.crt'), 'certificate_sha256': guard.digest(private / 'ca.crt'), 'policy_url': f'https://localhost:{port}/policy.json'}
    guard.write_new(private / 'app-config.json', config)
    state = {**config, 'platform': args.platform, 'port': port, 'prepared_ns': time.time_ns(), 'target_sha256': guard.digest(TARGET), 'contract_sha256': guard.digest(CONTRACT), 'observer_sha256': guard.digest(STORE_OBSERVER), 'macos_signing': args.macos_signing, 'signer_source_sha256': guard.digest(mac_signing.SOURCE), 'macos_confirmation': args.macos_confirmation, 'confirmation_sources': data_keychain.source_hashes()}
    guard.write_new(private / 'state.json', state)
    if args.macos_signing == mac_signing.MODE:
        mac_signing.prepare(output, job, nonce)
    if args.macos_confirmation == data_keychain.MODE:
        data_keychain.prepare(output, job, nonce)
    print(json.dumps({'prepared': True, 'state': str(private / 'state.json'), 'artifact_directory': str(output / 'receipts')}))


def brand_stage(args):
    state, output = load(args)
    version, build = validate_stage(args.stage)
    private = output / 'private'
    command(['dart', 'tool/xclient/brand_apply.dart', 'example', '--brands-dir', private / 'brands', '--version', version])
    defines = json_file(ROOT / 'xclient_defines.json')
    guard.require(defines['XC_BRAND_ID'] == 'example' and defines['XC_VERSION_NAME'] == version and defines['XC_BUILD_NUMBER'] == build, 'canonical_identity_required')
    defines.update({'SAFE_MODE': 'true', 'APP_ENV': 'pre', 'XC_UPDATE_QA': 'true', 'XC_UPDATE_QA_STAGE': args.stage, 'XC_UPDATE_QA_NONCE': state['nonce'], 'XC_UPDATE_QA_JOB': state['job'], 'XC_UPDATE_QA_OUTPUT': str(output), 'XC_UPDATE_QA_CONFIG_SHA256': guard.digest(private / 'app-config.json')})
    guard.write_new(private / ('v' + args.stage + '-defines.json'), defines)
    inputs = packaging_inputs(ROOT, version, build) if args.platform == 'windows' else None
    guard.write_new(private / ('v' + args.stage + '-build.json'), {'prepared_ns': time.time_ns(), 'defines_sha256': guard.digest(private / ('v' + args.stage + '-defines.json')), 'packaging': inputs})
    print(json.dumps({'stage': args.stage, 'defines': str(private / ('v' + args.stage + '-defines.json'))}))


def tree_digest(directory):
    return {str(file.relative_to(directory)).replace('\\', '/'): guard.digest(file) for file in sorted(directory.rglob('*')) if file.is_file() and not file.is_symlink()}


def verify_installed(directory, expected):
    for relative, digest in expected.items():
        file = directory / relative
        guard.require(file.is_file() and file.resolve().is_relative_to(directory.resolve()) and guard.digest(file) == digest, 'installed_file_mismatch')


def yaml_scalar(text, key):
    values = re.findall(r'^' + re.escape(key) + r':[ \t]*(.*)$', text, re.MULTILINE)
    guard.require(len(values) == 1, 'packaging_scalar_missing_or_duplicate')
    value = values[0].strip()
    if value.startswith('"'):
        value = json.loads(value)
    elif value.startswith("'"):
        guard.require(re.fullmatch(r"'(?:[^']|'')*'", value), 'packaging_scalar_invalid')
        value = value[1:-1].replace("''", "'")
    else:
        guard.require(value and value[0] not in '[{&*!>|' and '#' not in value, 'packaging_scalar_invalid')
    guard.require(isinstance(value, str), 'packaging_string_required')
    return value


def ini_value(text, key):
    values = re.findall(r'^' + re.escape(key) + r'=(.*)$', text, re.MULTILINE)
    guard.require(len(values) == 1, 'inno_directive_missing_or_duplicate')
    return values[0].strip()


def packaging_inputs(root, version, build):
    texts, hashes = {}, {}
    for relative in PACKAGING_FILES:
        file = root / relative
        guard.require(file.is_file() and not file.is_symlink() and file.resolve().is_relative_to(root.resolve()), 'packaging_input_scope_rejected')
        texts[relative] = file.read_text(encoding='utf-8')
        hashes[relative] = guard.digest(file)
    config = texts[PACKAGING_FILES[0]]
    expected = {'script_template': 'inno_setup.iss', 'app_id': GUID, 'app_name': 'ExampleClient', 'publisher': 'XClient', 'publisher_name': 'XClient', 'publisher_url': 'https://www.example.com', 'display_name': 'Example 加速器', 'executable_name': 'ExampleClient.exe', 'output_base_file_name': 'ExampleClient.exe', 'install_dir_name': r'{autopf}\ExampleClient', 'privileges_required': 'admin', 'setup_icon_file': r'windows\runner\resources\app_icon.ico'}
    for key, value in expected.items():
        guard.require(yaml_scalar(config, key) == value, 'example_packaging_config_required')
    package_version = version + '+' + build
    guard.require(yaml_scalar(texts['pubspec.yaml'], 'version') == package_version, 'exact_pubspec_version_required')
    options = texts['distribute_options.yaml']
    guard.require(yaml_scalar(options, 'app_name') == 'ExampleClient' and yaml_scalar(options, 'output') == 'dist/', 'example_distributor_options_required')
    template = texts[PACKAGING_FILES[1]]
    directives = {'AppId': '{{APP_ID}}', 'AppVersion': '{{APP_VERSION}}', 'AppName': '{{DISPLAY_NAME}}', 'DefaultDirName': '{{INSTALL_DIR_NAME}}', 'OutputBaseFilename': '{{OUTPUT_BASE_FILENAME}}', 'PrivilegesRequired': '{{PRIVILEGES_REQUIRED}}', 'AppMutex': 'XClient-' + GUID}
    for key, value in directives.items():
        guard.require(ini_value(template, key) == value, 'example_inno_template_required')
    process_list = "Processes := ['{{EXECUTABLE_NAME}}', 'XClientexampleCore.exe', 'XClientexampleHelperService.exe'];"
    guard.require(process_list in template and 'FlClashCore.exe' not in template and 'FlClashHelperService.exe' not in template, 'example_inno_processes_required')
    blocks = re.findall(r'^\[Run\]\s*\n(.*?)(?=^\[|\Z)', template, re.MULTILINE | re.DOTALL)
    guard.require(len(blocks) == 1, 'one_inno_run_section_required')
    entries = [line.strip() for line in blocks[0].splitlines() if line.strip() and not line.lstrip().startswith(';')]
    guard.require(len(entries) == 1 and re.fullmatch(r'Filename:\s*"\{app\}\\+\{\{EXECUTABLE_NAME\}\}";.*\bskipifsilent', entries[0]), 'silent_install_must_not_launch_app')
    mutexes = re.findall(r'constexpr wchar_t kXClientInstallerMutexName\[\] = L"([^"]*)";', texts['windows/runner/main.cpp'])
    guard.require(mutexes == ['XClient-' + GUID], 'runner_installer_mutex_required')
    return {'version': package_version, 'sha256': hashes}


def verify_packaging_inputs(root, frozen):
    guard.require(isinstance(frozen, dict) and isinstance(frozen.get('sha256'), dict) and set(frozen['sha256']) == set(PACKAGING_FILES), 'packaging_evidence_required')
    for relative, expected in frozen['sha256'].items():
        file = root / relative
        guard.require(file.is_file() and not file.is_symlink() and file.resolve().is_relative_to(root.resolve()) and guard.digest(file) == expected, 'packaging_input_changed')
    parts = frozen.get('version', '').split('+')
    guard.require(len(parts) == 2 and packaging_inputs(root, *parts) == frozen, 'packaging_evidence_changed')


def verify_windows_registration(registrations, install_root, package_version):
    guard.require(len(registrations) == 1, 'one_expected_guid_registration_required')
    actual = registrations[0]
    guard.require(actual.get('app_id') in (GUID, '{' + GUID + '}'), 'registered_guid_mismatch')
    location = actual.get('install_location')
    guard.require(isinstance(location, str) and Path(location).is_absolute() and Path(location).resolve() == install_root.resolve(), 'registered_install_directory_mismatch')
    guard.require(actual.get('display_version') == package_version, 'registered_display_version_mismatch')
    return True


def compare_requirements(private, second_bundle, one, two):
    report = {'v1_self_match': one.get('self_match'), 'v2_self_match': two.get('self_match'), 'v2_satisfies_v1': None, 'v1_satisfies_v2': None, 'requirements_differ': None, 'reason': 'unavailable'}
    try:
        files = [private / ('v' + stage + '-designated.req') for stage in ('1', '2')]
        for file, signing in zip(files, (one, two)):
            guard.require(signing.get('self_match') is True and file.is_file() and not file.is_symlink() and hashlib.sha256(file.read_bytes()).hexdigest() == signing.get('sha256'), 'requirement_input_changed')
        report['v2_satisfies_v1'] = requirement_matches(second_bundle, files[0], expected_sha256=one['sha256'])
        report['v1_satisfies_v2'] = requirement_matches(private / 'v1/ExampleClient.app', files[1], expected_sha256=two['sha256'])
        report['requirements_differ'] = one['sha256'] != two['sha256']
        report['reason'] = 'complete'
    except Exception as error:
        report['reason'] = 'processTimeout' if isinstance(error, subprocess.TimeoutExpired) else 'diagnosticFailed'
    return report


def stage_bundle(args):
    state, output = load(args)
    version, build = validate_stage(args.stage)
    private = output / 'private'
    guard.require(not (private / ('v' + args.stage + '-bundle.json')).exists(), 'new_bundle_stage_required')
    prepared = json_file(private / ('v' + args.stage + '-build.json'))
    defines = json_file(private / ('v' + args.stage + '-defines.json'))
    guard.require(guard.digest(private / ('v' + args.stage + '-defines.json')) == prepared['defines_sha256'], 'defines_changed')
    generated = guard.generated_config(args.platform)
    guard.require(generated.stat().st_mtime_ns > prepared['prepared_ns'], 'fresh_generated_config_required')
    values = guard.config_values(generated, args.platform)
    target = Path(values['FLUTTER_TARGET'])
    guard.require((target if target.is_absolute() else ROOT / target).resolve() == TARGET, 'qa_target_required')
    guard.verify_defines(values['DART_DEFINES'], {key: defines[key] for key in defines if key.startswith('XC_') or key == 'SAFE_MODE'})
    bundle = Path(args.bundle).resolve()
    guard.require(bundle.is_dir() and bundle.is_relative_to(ROOT / 'build'), 'build_bundle_required')
    assets = private / 'assets'
    assets.mkdir(exist_ok=True)
    cdhash = None
    signing = None
    if args.platform == 'windows':
        guard.require(isinstance(prepared.get('packaging'), dict) and prepared['packaging'].get('version') == version + '+' + build, 'packaging_stage_version_mismatch')
        verify_packaging_inputs(ROOT, prepared['packaging'])
        guard.require(bundle.parts[-4:] == ('windows', 'x64', 'runner', 'Release'), 'windows_release_bundle_required')
        exe, payload = bundle / 'ExampleClient.exe', bundle / 'data/app.so'
        package = Path(args.package).resolve()
        guard.require(package.is_file() and not package.is_symlink() and package.is_relative_to(ROOT) and package.suffix == '.exe' and package.stat().st_mtime_ns > prepared['prepared_ns'], 'fresh_inno_package_required')
        destination = assets / ('example-windows-x64-setup-v' + version + '.exe')
        guard.require(not destination.exists(), 'new_package_required')
        shutil.copy2(package, destination)
    else:
        guard.require(bundle.parent == ROOT / 'build/macos/Build/Products/Release' and bundle.name == 'ExampleClient.app', 'macos_release_bundle_required')
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        guard.require(info.get('CFBundleIdentifier') == 'com.xclient.example' and info.get('CFBundleExecutable') == 'ExampleClient' and info.get('FLTEnableImpeller') is False, 'example_macos_identity_required')
        signing_mode = state['macos_signing']
        identity = {}
        if signing_mode == mac_signing.MODE:
            identity = mac_signing.sign_bundle(output, bundle, args.stage)
        else:
            command(['/usr/bin/codesign', '--force', '--deep', '--sign', '-', '--entitlements', ROOT / 'macos/Runner/Release.entitlements', bundle])
        command(['/usr/bin/codesign', '--verify', '--deep', '--strict', bundle])
        signed = subprocess.run(['/usr/bin/codesign', '-dvvv', str(bundle)], capture_output=True, check=True)
        description = (signed.stderr + signed.stdout).decode()
        match = re.search(r'^CDHash=([0-9a-f]+)$', description, re.MULTILINE)
        adhoc = 'Signature=adhoc' in description
        guard.require(match and adhoc == (signing_mode == 'adhoc'), 'prepared_signature_mode_required')
        cdhash = match[1]
        signing = {**identity, **stage_requirement(bundle, private, args.stage)}
        if signing_mode == mac_signing.MODE:
            guard.require(signing['self_match'] is True and signing['form'] == 'certificateRequirement', 'certificate_requirement_required')
        guard.write_new(output / ('receipts/signing-' + args.stage + '.json'), {'adhoc': adhoc, 'cdhash': cdhash, **identity, **signing})
        exe = bundle / 'Contents/MacOS/ExampleClient'
        payload = bundle / 'Contents/Frameworks/App.framework/Versions/A/App'
        if not payload.is_file():
            payload = bundle / 'Contents/Frameworks/App.framework/App'
        destination = assets / ('example-macos-universal-v' + version + '.zip')
        guard.require(not destination.exists(), 'new_package_required')
        command(['/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', bundle, destination])
        if args.stage == '1':
            shutil.copytree(bundle, private / 'v1/ExampleClient.app', symlinks=True)
    guard.require(exe.is_file() and payload.is_file() and payload.stat().st_mtime_ns > prepared['prepared_ns'], 'fresh_native_payload_required')
    metadata = {'version': version, 'build': build, 'package_version': version + '+' + build, 'executable_sha256': guard.digest(exe), 'payload_sha256': guard.digest(payload), 'cdhash': cdhash, 'package': str(destination), 'package_sha256': guard.digest(destination), 'files': tree_digest(bundle)}
    if signing is not None:
        metadata['signing'] = signing
    if args.platform == 'windows':
        guard.write_new(output / ('receipts/packaging-' + args.stage + '.json'), prepared['packaging'])
    guard.write_new(private / ('v' + args.stage + '-bundle.json'), metadata)
    if args.stage == '2':
        first = json_file(private / 'v1-bundle.json')
        verify_pair(first, metadata)
        if args.platform == 'macos':
            compatibility = compare_requirements(private, bundle, first.get('signing', {}), metadata.get('signing', {}))
            guard.write_new(output / 'receipts/signing-compatibility.json', compatibility)
            if state['macos_signing'] == mac_signing.MODE:
                guard.require(all(compatibility.get(key) is True for key in ('v1_self_match', 'v2_self_match', 'v2_satisfies_v1', 'v1_satisfies_v2')), 'cross_version_certificate_requirement_mismatch')
    print(json.dumps({'staged': args.stage, 'platform': args.platform, 'macos_host_architecture_only': args.platform == 'macos'}))


def windows_objects():
    import winreg
    registrations = []
    for view in (winreg.KEY_WOW64_64KEY, winreg.KEY_WOW64_32KEY):
        for app_id in (GUID, '{' + GUID + '}'):
            path = 'Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\' + app_id + '_is1'
            try:
                key = winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, path, 0, winreg.KEY_READ | view)
            except FileNotFoundError:
                continue
            with key:
                values = {'app_id': app_id}
                for field, name in [('install_location', 'InstallLocation'), ('display_version', 'DisplayVersion')]:
                    try:
                        values[field] = winreg.QueryValueEx(key, name)[0]
                    except FileNotFoundError:
                        values[field] = None
                registrations.append(values)
    service = command(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', "[bool](Get-Service -Name '" + SERVICE + "' -ErrorAction SilentlyContinue)"])
    return registrations, service.strip().lower() == 'true'


def no_preexisting_example_processes():
    if sys.platform == 'win32':
        raw = command(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', "@(Get-CimInstance Win32_Process -Filter \"Name='ExampleClient.exe' OR Name='XClientexampleCore.exe' OR Name='XClientexampleHelperService.exe'\").Count"])
        guard.require(raw == '0', 'example_process_already_exists')
    else:
        names = {Path(line.strip()).name for line in command(['/bin/ps', '-axo', 'comm=']).splitlines()}
        guard.require(not names.intersection({'ExampleClient', 'XClientexampleCore'}), 'example_process_already_exists')


def alive(pid):
    if sys.platform != 'win32':
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
    from ctypes import wintypes
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x1000, False, pid)
    if not handle:
        guard.require(ctypes.get_last_error() == 87, 'process_presence_unknown')
        return False
    try:
        code = wintypes.DWORD()
        guard.require(kernel.GetExitCodeProcess(handle, ctypes.byref(code)), 'process_presence_unknown')
        return code.value == 259
    finally:
        kernel.CloseHandle(handle)


def stop_owned(owner, mismatch=None):
    if not alive(owner['pid']):
        return True
    try:
        identity = guard.process_identity(owner['pid'])
    except (guard.Refused, subprocess.CalledProcessError):
        if not alive(owner['pid']):
            return True
        raise
    validate_observed_owner(owner, identity, 'cleanupOwner', mismatch)
    if sys.platform == 'win32':
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(1, False, owner['pid'])
        guard.require(bool(handle), 'owned_process_stop_failed')
        try:
            validate_observed_owner(owner, guard.process_identity(owner['pid']), 'cleanupBeforeSignal', mismatch)
            guard.require(kernel.TerminateProcess(handle, 1), 'owned_process_stop_failed')
        finally:
            kernel.CloseHandle(handle)
    else:
        import signal
        os.kill(owner['pid'], signal.SIGTERM)
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not alive(owner['pid']):
            return True
        validate_observed_owner(owner, guard.process_identity(owner['pid']), 'cleanupWait', mismatch)
        time.sleep(0.05)
    raise guard.Refused('owned_process_stop_unconfirmed')


def child_core(owner, expected):
    if sys.platform == 'win32':
        raw = command(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', f"@(Get-CimInstance Win32_Process -Filter 'ParentProcessId={owner['pid']}' | Select-Object -ExpandProperty ProcessId) | ConvertTo-Json -Compress"])
        pids = json.loads(raw) if raw else []
        pids = pids if isinstance(pids, list) else [pids]
    else:
        rows = command(['/bin/ps', '-axo', 'pid=,ppid=']).splitlines()
        pids = [int(row.split()[0]) for row in rows if len(row.split()) == 2 and int(row.split()[1]) == owner['pid']]
    for pid in pids:
        if not alive(pid):
            continue
        identity = guard.process_identity(pid)
        if Path(identity['executable']) == expected:
            return identity
    raise guard.Refused('owned_core_not_observed')


def observe_children(owned, rows, mismatch=None):
    current = {}
    for owner in list(owned):
        if alive(owner['pid']):
            observe_owner_identity(owner, 'observeOwner', mismatch)
            current[owner['pid']] = owner
    remaining = list(rows)
    for _ in range(len(rows)):
        adopted = False
        for row in list(remaining):
            if row['pid'] in current or row['parent'] not in current or not alive(row['pid']):
                continue
            observe_owner_identity(current[row['parent']], 'observeParent', mismatch)
            try:
                identity = guard.process_identity(row['pid'])
            except Exception as error:
                if identity_query_disappeared(error) and not alive(row['pid']):
                    remaining.remove(row)
                    continue
                raise OwnerObservationError({'pid': row['pid']}, 'adoptChild', error) from None
            guard.require(Path(identity['executable']).resolve() == Path(row['executable']).resolve(), 'child_image_changed')
            if identity not in owned:
                owned.append(identity)
            current[row['pid']] = identity
            remaining.remove(row)
            adopted = True
        if not adopted:
            break
    return owned


def observe_owner_identity(owner, phase, mismatch):
    current = None
    try:
        current = guard.process_identity(owner['pid'])
        validate_observed_owner(owner, current, phase, mismatch)
    except Exception as error:
        raise OwnerObservationError(owner, phase, error, current) from None


def reported_v2_owner(hello, first_pid, executable, expected_sha256):
    guard.require(type(hello.get('pid')) is int and hello['pid'] > 0 and hello['pid'] != first_pid and hello.get('executable_sha256') == expected_sha256 and guard.digest(executable) == expected_sha256, 'v2_hello_mismatch')
    owner = guard.process_identity(hello['pid'])
    guard.require(Path(owner['executable']) == executable, 'v2_owner_mismatch')
    return owner


def observe_direct_child(owned, child, mismatch=None, report=None):
    report = report if report is not None else {}
    report.setdefault('retry_attempted', False)
    report.update({'direct_child_present': child is not None, 'direct_child_pid': child.pid if child is not None else None})
    try:
        rows = process_rows(child)
    finally:
        report['direct_child_returncode'] = child.returncode if child is not None else None
    try:
        return observe_children(owned, rows, mismatch)
    except OwnerObservationError as error:
        report.update({'failure_phase': error.phase, 'failure_kind': error.kind, 'failure_pid_matches_direct': child is not None and error.pid == child.pid})
        if child is None or error.pid != child.pid or not error.direct_exit_retry:
            raise
        code = child.poll()
        report['direct_child_returncode'] = code
        report['retry_poll_exit_observed'] = code is not None
        if code is None:
            raise
        report['retry_pid_absent'] = not alive(child.pid)
        if not report['retry_pid_absent']:
            raise
        report['retry_attempted'] = True
        try:
            return observe_children(owned, process_rows(), mismatch)
        except Exception as retried:
            report['retry_failure_kind'] = fixture_exception_kind(retried)
            if isinstance(retried, OwnerObservationError):
                report.update({'retry_failure_phase': retried.phase, 'retry_failure_pid_matches_direct': retried.pid == child.pid})
            raise


def process_rows(direct_child=None):
    if direct_child is not None:
        direct_child.poll()
    if sys.platform == 'win32':
        raw = command(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', '@(Get-CimInstance Win32_Process | Where-Object ExecutablePath | ForEach-Object { [pscustomobject]@{pid=$_.ProcessId; parent=$_.ParentProcessId; executable=$_.ExecutablePath} }) | ConvertTo-Json -Compress'])
        value = json.loads(raw)
        return value if isinstance(value, list) else [value]
    rows = command(['/bin/ps', '-axo', 'pid=,ppid=,comm=']).splitlines()
    return [{'pid': int(parts[0]), 'parent': int(parts[1]), 'executable': parts[2]} for row in rows if len(parts := row.strip().split(None, 2)) == 3]


class HttpsFixture(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        value = self.server.allowed.get(self.path)
        if value is None:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(value.stat().st_size))
        self.send_header('Content-Type', 'application/json' if value.suffix == '.json' else 'application/octet-stream')
        self.end_headers()
        try:
            with value.open('rb') as source:
                shutil.copyfileobj(source, self.wfile)
        except (BrokenPipeError, ConnectionResetError):
            pass


def close_fixture(server, started):
    if started:
        server.shutdown()
    server.server_close()


def sign_fixture(state, output):
    private = output / 'private'
    version, _ = validate_stage('2')
    base = 'https://localhost:' + str(state['port'])
    env = dict(os.environ, XCLIENT_REL_SEED=(private / 'rel.seed').read_text(encoding='utf-8').strip())
    command(['dart', 'tool/xclient/xsign.dart', 'sign-release', 'example', version, private / 'assets', base + '/assets', '--kid', 'qa-rel', '--out', private / 'release.json'], environment=env)
    guard.write_new(private / 'policy-payload.json', {'brand': 'example', 'seq': 1, 'latest': version, 'min_supported': version, 'force': True, 'notes': 'Synthetic CI update', 'release_urls': [base + '/release.json']})
    env = dict(os.environ, XCLIENT_REL_SEED=(private / 'ctrl.seed').read_text(encoding='utf-8').strip())
    command(['dart', 'tool/xclient/xsign.dart', 'sign', 'policy', private / 'policy-payload.json', '--kid', 'qa-ctrl', '--out', private / 'policy.json'], environment=env)
    for seed in ('ctrl.seed', 'rel.seed'):
        (private / seed).unlink()


def wait_file(file, deadline, observe=None):
    next_observation = 0
    while time.monotonic() < deadline:
        guard.require(not (file.parent / 'failure.json').exists(), 'qa_app_reported_failure')
        if observe is not None and time.monotonic() >= next_observation:
            observe()
            next_observation = time.monotonic() + 0.5
        if file.exists():
            return json_file(file)
        time.sleep(0.05)
    raise guard.Refused('native_update_deadline')


def require_no_app_failure(receipts):
    guard.require(not os.path.lexists(receipts / 'failure.json'), 'qa_app_reported_failure')


def verify_exit_observation(receipts, owners_gone, v1_exit_code):
    require_no_app_failure(receipts)
    for stage in ('1', '2'):
        guard.require(json_file(receipts / ('exit-' + stage + '.json')).get('production_exit_requested') is True, 'production_exit_path_required')
    guard.require(owners_gone and v1_exit_code == 0, 'production_exit_not_observed')
    return True


def verify_probe_child_identity(result, pid, owner):
    expected = Path('/bin/cat').resolve()
    diagnostic = {'pid': pid, 'pid_matches': owner['pid'] == pid, 'expected_executable_kind': 'fixedCat', 'observed_executable_kind': executable_kind(str(expected), owner['executable']), 'executable_matches': Path(owner['executable']).resolve() == expected, 'started_present': isinstance(owner.get('started'), str) and bool(owner['started'].strip()), **mac_process_snapshot(owner)}
    result['child_identity'] = diagnostic
    guard.require(all(diagnostic[key] is True for key in ('pid_matches', 'executable_matches', 'started_present')), 'probe_child_identity_mismatch')


def pending_store_begin(value, expected_id, now_ms):
    fields = {'stage', 'id', 'operation', 'event', 'outcome', 'started_ms', 'elapsed_ms'}
    operations = {'initialRead', 'initialWrite', 'initialVerify', 'crossRead', 'replacementWrite', 'replacementRead', 'cleanupDelete', 'cleanupRead'}
    return isinstance(value, dict) and set(value) == fields and value['stage'] == '2' and type(value['id']) is int and type(expected_id) is int and value['id'] == expected_id and 1 <= expected_id <= 32 and isinstance(value['operation'], str) and value['operation'] in operations and value['event'] == 'begin' and value['outcome'] == 'pending' and type(value['started_ms']) is int and type(value['elapsed_ms']) is int and 0 <= value['elapsed_ms'] < 120000 and 5000 <= now_ms - value['started_ms'] <= 60000


def valid_capture_png(file):
    if not file.is_file() or file.is_symlink() or not 45 <= file.stat().st_size <= 25 * 1024 * 1024:
        return False
    with file.open('rb') as stream:
        header = stream.read(33)
        stream.seek(-12, 2)
        end = stream.read(12)
    return header[:12] == b'\x89PNG\r\n\x1a\n\x00\x00\x00\r' and header[12:16] == b'IHDR' and zlib.crc32(header[12:29]) == int.from_bytes(header[29:33], 'big') and all(0 < int.from_bytes(header[start:start + 4], 'big') <= 16384 for start in (16, 20)) and end == b'\x00\x00\x00\x00IEND\xaeB`\x82'


def native_store_screenshot(output, owner, attempt):
    guard.ci_identity('macos')
    output = guard.scoped(output)
    guard.require(attempt in (1, 2), 'bounded_capture_required')
    report = {'captured': False, 'reason': 'unavailable'}
    try:
        validate_owner(owner, guard.process_identity(owner['pid']))
        graphics = ctypes.CDLL('/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics')
        preflight = graphics.CGPreflightScreenCaptureAccess
        preflight.restype, preflight.argtypes = ctypes.c_bool, []
        if not preflight():
            return {**report, 'reason': 'permissionUnavailable'}
        directory = output / 'private/captures'
        guard.require(directory.resolve() == directory and not directory.is_symlink(), 'capture_directory_scope')
        directory.mkdir(exist_ok=True)
        name = 'native-store-pending-' + str(attempt) + '.png'
        private_image, image = directory / name, output / 'receipts' / name
        guard.require(not private_image.exists() and not private_image.is_symlink() and not image.exists() and not image.is_symlink(), 'new_capture_required')
        captured = subprocess.run(['/usr/sbin/screencapture', '-x', '-t', 'png', str(private_image)], capture_output=True, timeout=5)
        if captured.returncode != 0:
            return {**report, 'reason': 'captureFailed'}
        if not valid_capture_png(private_image):
            return {**report, 'reason': 'invalidPng'}
        validate_owner(owner, guard.process_identity(owner['pid']))
        with private_image.open('rb') as source, image.open('xb') as target:
            shutil.copyfileobj(source, target)
        return {'captured': True, 'reason': 'captured', 'png_sha256': guard.digest(image), 'bytes': image.stat().st_size}
    except Exception as error:
        report['reason'] = 'captureTimeout' if isinstance(error, subprocess.TimeoutExpired) else 'captureUnavailable'
    return report


def capture_pending_store(output, owner, state, *, now_ms=None):
    now_ms = time.time_ns() // 10**6 if now_ms is None else now_ms
    if state['attempts'] >= 2 or now_ms - state['last_ms'] < 5000:
        return
    for file in sorted((output / 'receipts').glob('store-2-??-begin.json')):
        match = re.fullmatch(r'store-2-([0-9]{2})-begin\.json', file.name)
        if match is None or (file.parent / file.name.replace('-begin.json', '-end.json')).exists():
            continue
        value = json_file(file)
        if not pending_store_begin(value, int(match[1]), now_ms):
            continue
        state['attempts'] += 1
        state['last_ms'] = now_ms
        captured = native_store_screenshot(output, owner, state['attempts'])
        guard.write_new(output / ('receipts/native-store-pending-' + str(state['attempts']) + '.json'), {'stage': '2', 'id': value['id'], 'operation': value['operation'], 'attempt': state['attempts'], **captured})
        break


def confirmation_capture_available(output):
    for attempt in (1, 2):
        receipt = output / ('receipts/native-store-pending-' + str(attempt) + '.json')
        image = receipt.with_suffix('.png')
        if not receipt.is_file() or receipt.is_symlink():
            continue
        metadata = json_file(receipt)
        if metadata.get('captured') is True and metadata.get('stage') == '2' and metadata.get('id') == 1 and metadata.get('operation') == 'crossRead' and valid_capture_png(image) and guard.digest(image) == metadata.get('png_sha256'):
            return True
    return False


def process_probe(args):
    job = guard.ci_identity(args.platform)
    guard.require(args.platform == 'macos', 'macos_process_probe_required')
    output = guard.scoped(args.output)
    guard.require(not output.exists() and not output.is_symlink(), 'new_output_required')
    inputs = {Path(__file__).resolve(): guard.digest(Path(__file__).resolve()), Path(guard.__file__).resolve(): guard.digest(Path(guard.__file__).resolve())}
    before = guard.network_hash()
    output.mkdir(parents=True, mode=0o700)
    receipts = output / 'receipts'
    receipts.mkdir()
    (output / '.native-process-probe-owned').write_text(secrets.token_hex(16), encoding='ascii')
    child, owner, mismatches = None, None, []
    result = {'success': False, 'job': job, 'live_owner_matched': False, 'zombie_observed': False, 'observer_refused_before_reap': False, 'direct_child_reaped_before_scan': False, 'observer_passed_after_reap': False, 'child_reaped': False, 'child_stopped': False, 'normal_exit': False, 'network_unchanged': False, 'inputs_unchanged': False, 'error_classes': []}
    try:
        child = subprocess.Popen(['/bin/cat'], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        owner = guard.process_identity(child.pid)
        verify_probe_child_identity(result, child.pid, owner)
        result['owner'] = owner
        observe_children([owner], process_rows())
        result['live_owner_matched'] = True
        child.stdin.close()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            snapshot = mac_process_snapshot(owner)
            result['before_reap'] = snapshot
            if snapshot['state'] in ('zombie', 'absent'):
                break
            time.sleep(0.05)
        result['zombie_observed'] = result['before_reap']['state'] == 'zombie'
        try:
            observe_children([owner], process_rows(), mismatches.append)
        except guard.Refused as error:
            result['observer_refused_before_reap'] = True
            result['observer_refusal'] = str(error) if str(error) in ('cleanup_owner_mismatch', 'process_identity_unavailable') else 'other'
        result['process_observation'] = {}
        observe_direct_child([owner], child, report=result['process_observation'])
        result['direct_child_reaped_before_scan'] = child.returncode is not None
        guard.require(result['direct_child_reaped_before_scan'], 'probe_exit_not_yet_reaped')
        result['observer_passed_after_reap'] = True
    except Exception as error:
        result['error_classes'].append(str(error) if isinstance(error, guard.Refused) else 'process_probe_failed')
    finally:
        if child is not None:
            try:
                if child.stdin is not None and not child.stdin.closed:
                    child.stdin.close()
                try:
                    code = child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    guard.require(owner is not None, 'probe_cleanup_identity_unconfirmed')
                    validate_owner(owner, guard.process_identity(child.pid))
                    child.terminate()
                    code = child.wait(timeout=5)
                result['child_reaped'] = True
                result['normal_exit'] = code == 0
                result['child_stopped'] = not alive(child.pid)
            except Exception:
                result['error_classes'].append('probe_cleanup_unconfirmed')
        result['network_unchanged'] = before == guard.network_hash()
        result['inputs_unchanged'] = all(guard.digest(file) == expected for file, expected in inputs.items())
        result['success'] = all(result[key] is True for key in ('live_owner_matched', 'direct_child_reaped_before_scan', 'observer_passed_after_reap', 'child_reaped', 'child_stopped', 'normal_exit', 'network_unchanged', 'inputs_unchanged')) and not result['error_classes']
        guard.write_new(receipts / 'ownership.json', {'mismatches': mismatches})
        guard.write_new(receipts / 'probe-result.json', result)
    print(json.dumps({'success': result['success'], 'zombie_observed': result['zombie_observed'], 'observer_refused_before_reap': result['observer_refused_before_reap'], 'error_classes': result['error_classes']}, sort_keys=True))
    return 0 if result['success'] else 1


def run(args):
    state, output = load(args)
    private = output / 'private'
    one, two = [json_file(private / ('v' + stage + '-bundle.json')) for stage in ('1', '2')]
    verify_pair(one, two)
    guard.require(not (private / 'installed').exists() and not (private / 'run-started').exists(), 'fresh_install_required')
    (private / 'run-started').write_text(state['nonce'], encoding='utf-8')
    before = guard.network_hash()
    child, owned, server, installed, server_started = None, [], None, False, False
    capture_owner = None
    capture_state = {'attempts': 0, 'last_ms': 0}
    mismatches = []
    mismatch = mismatches.append if args.platform == 'macos' else None
    result = {'success': False, 'initial_install': False, 'real_update_handoff': False, 'v1_exit': False, 'v1_observed_exit_code': None, 'v2_exit_code_observed': False, 'v2_native_identity': False, 'v2_files_match': False, 'synthetic_store_across_versions': False, 'synthetic_store_cleanup': False, 'exit_observed_after_production_request': False, 'owned_processes_stopped': False, 'network_unchanged': False, 'installation_cleanup': False, 'macos_host_architecture_only': args.platform == 'macos', 'uac_interaction_tested': False, 'error_classes': [], 'checkpoint': 'admission', 'exception_kind': None, 'cleanup_exception_kind': None, 'process_observation': {}, 'cleanup_process_observation': {}}
    if args.platform == 'windows':
        result.update({'initial_windows_registry': False, 'updated_windows_registry': False})
    if state['macos_confirmation'] == data_keychain.MODE:
        result.update({'owned_data_keychain_active': False, 'owned_data_item_verified': False, 'system_confirmation_simulated': False, 'owned_data_keychain_cleanup': False})
    executable = private_path(output, state['installed_executable'])
    install_root = executable.parent if args.platform == 'windows' else executable.parents[2]
    def observe(cleanup=False):
        if args.platform == 'macos':
            observe_direct_child(owned, child, mismatch, result['cleanup_process_observation' if cleanup else 'process_observation'])
            if not cleanup and capture_owner is not None:
                capture_pending_store(output, capture_owner, capture_state)
                if state['macos_confirmation'] == data_keychain.MODE:
                    result['system_confirmation_simulated'] = keychain_confirmation.maybe_confirm(output, capture_owner, two['executable_sha256'], lambda: confirmation_capture_available(output))
            return
        rows = process_rows()
        download = private / 'downloads/example-windows-x64-v1.0.0-pre.2.exe'
        if args.platform == 'windows':
            for row in rows:
                if Path(row['executable']).resolve() == download and alive(row['pid']):
                    guard.require(guard.digest(download) == two['package_sha256'], 'installer_image_mismatch')
                    identity = guard.process_identity(row['pid'])
                    guard.require(Path(identity['executable']).resolve() == download, 'installer_image_changed')
                    if identity not in owned:
                        owned.append(identity)
        observe_children(owned, rows, mismatch)
    try:
        result['checkpoint'] = 'preexistingObjects'
        if state['macos_signing'] == mac_signing.MODE:
            mac_signing.verify_ready(output)
        no_preexisting_example_processes()
        if args.platform == 'windows':
            registrations, service = windows_objects()
            guard.require(not registrations and not service, 'example_objects_already_exist')
        for metadata in (one, two):
            guard.require(guard.digest(private_path(output, metadata['package'])) == metadata['package_sha256'], 'staged_package_changed')
        if state['macos_confirmation'] == data_keychain.MODE:
            result['owned_data_keychain_active'] = data_keychain.begin(output)['owned_data_keychain_active']
        result['checkpoint'] = 'fixtureSigning'
        sign_fixture(state, output)
        server = http.server.ThreadingHTTPServer(('127.0.0.1', state['port']), HttpsFixture)
        server.daemon_threads = True
        server.allowed = {'/policy.json': private / 'policy.json', '/release.json': private / 'release.json', **{'/assets/' + Path(metadata['package']).name: Path(metadata['package']) for metadata in (one, two)}}
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(private / 'server-chain.crt', private / 'server.key')
        server.socket = context.wrap_socket(server.socket, server_side=True)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        server_started = True
        result['checkpoint'] = 'initialInstall'
        installed = True
        if args.platform == 'windows':
            command([one['package'], '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/NOICONS', '/TASKS=', '/DIR=' + str(install_root), '/LOG=' + str(private / 'initial-install.log')])
        else:
            install_root.parent.mkdir(parents=True)
            command(['/usr/bin/ditto', private / 'v1/ExampleClient.app', install_root])
        verify_installed(install_root, one['files'])
        if args.platform == 'windows':
            registrations, service = windows_objects()
            verify_windows_registration(registrations, install_root, one['package_version'])
            guard.require(not service, 'unexpected_example_service')
            result['initial_windows_registry'] = True
            guard.write_new(output / 'receipts/registry-1.json', {'expected_guid_registered': True, 'owned_directory': True, 'display_version': one['package_version'], 'helper_service_absent': True})
        result['initial_install'] = True
        result['checkpoint'] = 'launchV1'
        child = subprocess.Popen([str(executable)], cwd=executable.parent, env=dict(os.environ, FLCLASH_ACCEPT_DISCLAIMER='1'), stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        owner = guard.process_identity(child.pid)
        guard.require(Path(owner['executable']) == executable, 'v1_owner_mismatch')
        owned.append(owner)
        deadline = time.monotonic() + 180
        result['checkpoint'] = 'helloV1'
        hello = wait_file(output / 'receipts/hello-1.json', deadline, observe)
        guard.require(hello['pid'] == owner['pid'] and hello['executable_sha256'] == one['executable_sha256'], 'v1_hello_mismatch')
        guard.write_new(private / 'lease-1.json', {**owner, 'nonce': state['nonce'], 'job': state['job'], 'executable_sha256': one['executable_sha256']})
        result['checkpoint'] = 'readyV1'
        wait_file(output / 'receipts/ready-1.json', deadline, observe)
        if state['macos_confirmation'] == data_keychain.MODE:
            result['checkpoint'] = 'ownedDataItem'
            result['owned_data_item_verified'] = data_keychain.prove_item_placement(output)['owned_item_metadata_verified']
        result['checkpoint'] = 'coreV1'
        core = executable.with_name('XClientexampleCore' + ('.exe' if args.platform == 'windows' else ''))
        core_owner = child_core(owner, core)
        if core_owner not in owned:
            owned.append(core_owner)
        guard.write_new(private / 'arm.json', {'nonce': state['nonce']})
        result['checkpoint'] = 'helperReceipt'
        helper = wait_file(output / 'receipts/helper.json', deadline, observe)
        guard.require(helper.get('force_active') is True, 'forced_policy_handoff_required')
        result['real_update_handoff'] = helper['real_process_started'] is True
        result['checkpoint'] = 'helperIdentity'
        if alive(helper['pid']):
            helper_owner = guard.process_identity(helper['pid'])
            validate_observed_owner({key: helper[key] for key in ('pid', 'executable', 'started')}, helper_owner, 'helperReceipt', mismatch)
            if helper_owner not in owned:
                owned.append(helper_owner)
        result['checkpoint'] = 'helloV2'
        hello_two = wait_file(output / 'receipts/hello-2.json', deadline, observe)
        next_owner = reported_v2_owner(hello_two, owner['pid'], executable, two['executable_sha256'])
        if next_owner not in owned:
            owned.append(next_owner)
        capture_owner = next_owner
        guard.write_new(private / 'lease-2.json', {**next_owner, 'nonce': state['nonce'], 'job': state['job'], 'executable_sha256': two['executable_sha256']})
        result['checkpoint'] = 'verifyV2'
        verified = wait_file(output / 'receipts/verified-2.json', deadline, observe)
        guard.require(all(verified.get(key) is True for key in ('canonical_identity', 'synthetic_read', 'synthetic_replace', 'synthetic_delete')) and verified.get('error_classes') == [], 'v2_native_verification_failed')
        result['checkpoint'] = 'coreV2'
        core_owner = child_core(next_owner, core)
        if core_owner not in owned:
            owned.append(core_owner)
        result['checkpoint'] = 'exitRequests'
        guard.write_new(private / 'stop.json', {'nonce': state['nonce']})
        child.wait(timeout=max(1, deadline - time.monotonic()))
        for stage in ('1', '2'):
            guard.require(wait_file(output / ('receipts/exit-' + stage + '.json'), deadline).get('production_exit_requested') is True, 'production_exit_path_required')
        grace = time.monotonic() + 8
        while any(alive(item['pid']) for item in owned) and time.monotonic() < grace:
            time.sleep(0.1)
        result['v1_observed_exit_code'] = child.returncode
        result['exit_observed_after_production_request'] = verify_exit_observation(output / 'receipts', not any(alive(item['pid']) for item in owned), child.returncode)
        result.update({'v1_exit': child.returncode == 0, 'v2_native_identity': True, 'synthetic_store_across_versions': True, 'synthetic_store_cleanup': True})
        result['checkpoint'] = 'installedV2'
        verify_installed(install_root, two['files'])
        if args.platform == 'windows':
            registrations, service = windows_objects()
            verify_windows_registration(registrations, install_root, two['package_version'])
            guard.require(not service, 'unexpected_example_service')
            result['updated_windows_registry'] = True
            guard.write_new(output / 'receipts/registry-2.json', {'expected_guid_registered': True, 'owned_directory': True, 'display_version': two['package_version'], 'helper_service_absent': True})
        result['v2_files_match'] = True
        result['checkpoint'] = 'complete'
    except Exception as error:
        result['exception_kind'] = fixture_exception_kind(error)
        result['error_classes'].append(str(error) if isinstance(error, guard.Refused) else 'native_update_fixture_error')
    finally:
        ownership_confirmed = True
        try:
            late_hello = output / 'receipts/hello-2.json'
            if args.platform == 'macos' and child is not None and late_hello.is_file():
                reported = json_file(late_hello)
                guard.require(type(reported.get('pid')) is int and reported['pid'] > 0, 'v2_hello_mismatch')
                if alive(reported['pid']):
                    late_owner = reported_v2_owner(reported, child.pid, executable, two['executable_sha256'])
                    if late_owner not in owned:
                        owned.append(late_owner)
                        result['cleanup_process_observation']['late_v2_adopted'] = True
            observe(cleanup=True)
        except Exception as error:
            ownership_confirmed = False
            result['cleanup_exception_kind'] = fixture_exception_kind(error)
            result['error_classes'].append('process_tree_ownership_unconfirmed')
        if not (private / 'stop.json').exists():
            guard.write_new(private / 'stop.json', {'nonce': state['nonce']})
        time.sleep(1)
        stopped = ownership_confirmed
        for owner in reversed(owned):
            try:
                stop_owned(owner, mismatch)
            except Exception:
                stopped = False
        if stopped:
            try:
                no_preexisting_example_processes()
            except Exception:
                stopped = False
                result['error_classes'].append('example_processes_remaining_after_stop')
        result['owned_processes_stopped'] = stopped and bool(owned)
        try:
            if installed and stopped:
                if args.platform == 'windows':
                    uninstallers = list(install_root.glob('unins*.exe'))
                    guard.require(len(uninstallers) == 1, 'owned_uninstaller_required')
                    command([uninstallers[0], '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG=' + str(private / 'uninstall.log')])
                    registrations, service = windows_objects()
                    guard.require(not registrations and not service, 'example_objects_cleanup_failed')
                else:
                    guard.require(install_root.resolve().is_relative_to(private.resolve()) and install_root.name == 'ExampleClient.app', 'cleanup_path_rejected')
                    shutil.rmtree(install_root)
                result['installation_cleanup'] = not executable.exists()
        except Exception:
            result['error_classes'].append('installation_cleanup_unconfirmed')
        if server is not None:
            close_fixture(server, server_started)
        result['network_unchanged'] = before == guard.network_hash()
        try:
            require_no_app_failure(output / 'receipts')
        except guard.Refused as error:
            result['error_classes'].append(str(error))
        if state['macos_confirmation'] == data_keychain.MODE:
            try:
                result['owned_data_keychain_cleanup'] = data_keychain.cleanup(output)['success']
            except Exception:
                result['error_classes'].append('owned_data_keychain_cleanup_unconfirmed')
        if state['macos_signing'] == mac_signing.MODE:
            result['signing_resources_cleaned'] = False
            try:
                result['signing_resources_cleaned'] = mac_signing.cleanup(output)['success']
            except Exception:
                result['error_classes'].append('signing_cleanup_unconfirmed')
        required = [key for key in result if key not in ('success', 'error_classes', 'macos_host_architecture_only', 'uac_interaction_tested', 'v1_observed_exit_code', 'v2_exit_code_observed', 'checkpoint', 'exception_kind', 'cleanup_exception_kind', 'process_observation', 'cleanup_process_observation')]
        if state['macos_confirmation'] == data_keychain.MODE and result['checkpoint'] == 'complete' and not result['system_confirmation_simulated']:
            result['error_classes'].append('expected_system_confirmation_not_observed')
        result['success'] = all(result[key] is True for key in required) and not result['error_classes']
        guard.write_new(output / 'receipts/processes.json', {'owners': owned})
        if mismatches:
            guard.write_new(output / 'receipts/ownership.json', {'mismatches': mismatches[:16]})
        guard.write_new(output / 'receipts/runner-result.json', result)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['success'] else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'brand', 'stage', 'run', 'process-probe', 'signing-preflight', 'signing-cleanup', 'confirmation-cleanup'])
    parser.add_argument('--macos-signing', choices=['adhoc', mac_signing.MODE], default='adhoc')
    parser.add_argument('--macos-confirmation', choices=['disabled', data_keychain.MODE], default='disabled')
    parser.add_argument('--platform', choices=['windows', 'macos'], required=True)
    parser.add_argument('--output')
    parser.add_argument('--state')
    parser.add_argument('--stage', choices=['1', '2'])
    parser.add_argument('--bundle')
    parser.add_argument('--package')
    args = parser.parse_args()
    if args.mode == 'process-probe':
        guard.require(args.output is not None, 'output_required')
        return process_probe(args)
    if args.mode == 'confirmation-cleanup':
        state, output = load(args)
        guard.require(state['macos_confirmation'] == data_keychain.MODE, 'owned_confirmation_fixture_required')
        data_keychain.cleanup(output)
    elif args.mode in ('signing-preflight', 'signing-cleanup'):
        state, output = load(args)
        guard.require(state['macos_signing'] == mac_signing.MODE, 'ephemeral_signing_fixture_required')
        if args.mode == 'signing-preflight':
            mac_signing.preflight(output)
        else:
            mac_signing.cleanup(output)
    elif args.mode == 'prepare':
        guard.require(args.output is not None, 'output_required')
        prepare(args)
    elif args.mode == 'brand':
        brand_stage(args)
    elif args.mode == 'stage':
        guard.require(args.bundle is not None and (args.platform != 'windows' or args.package is not None), 'bundle_package_required')
        stage_bundle(args)
    else:
        return run(args)
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'success': False, 'error_class': str(error) if isinstance(error, guard.Refused) else 'native_update_setup_error'}))
        sys.exit(1)
