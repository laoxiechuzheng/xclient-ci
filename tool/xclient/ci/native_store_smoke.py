#!/usr/bin/env python3
import argparse
import base64
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shutil
import socket
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[3]
TARGET = ROOT / 'test/xboard/native/secure_store_app.dart'

class Refused(Exception):
    pass

def require(value, code):
    if not value:
        raise Refused(code)

def digest(file):
    return hashlib.sha256(file.read_bytes()).hexdigest()

def write_new(file, data):
    if file.exists() or file.is_symlink():
        raise FileExistsError
    temporary = file.with_name(file.name + '.next')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(data, stream, sort_keys=True)
        stream.flush()
    if file.exists() or file.is_symlink():
        raise FileExistsError
    temporary.rename(file)

def ci_identity(platform):
    env = os.environ
    require(env.get('GITHUB_ACTIONS') == 'true' and env.get('RUNNER_ENVIRONMENT') == 'github-hosted', 'github_hosted_ci_required')
    require(env.get('RUNNER_OS') == ('Windows' if platform == 'windows' else 'macOS') and sys.platform == ('win32' if platform == 'windows' else 'darwin'), 'native_runner_required')
    require(re.fullmatch(r'[0-9]+', env.get('GITHUB_RUN_ID', '')) and re.fullmatch(r'[0-9]+', env.get('GITHUB_RUN_ATTEMPT', '')) and re.fullmatch(r'[A-Za-z0-9_-]+', env.get('GITHUB_JOB', '')) and re.fullmatch(r'[a-fA-F0-9]{40}', env.get('GITHUB_SHA', '')), 'job_identity_required')
    require(Path(env.get('GITHUB_WORKSPACE', '')).resolve() == ROOT, 'workspace_mismatch')
    return ':'.join(env[key] for key in ('GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT', 'GITHUB_JOB', 'GITHUB_SHA'))

def scoped(path):
    value = Path(path).absolute()
    require(value.resolve() == value and value.is_relative_to(ROOT / 'out'), 'output_scope_rejected')
    return value

def prepare(args):
    job = ci_identity(args.platform)
    output = scoped(args.output)
    require(not output.exists(), 'new_output_required')
    defines = json.loads((ROOT / 'xclient_defines.json').read_text(encoding='utf-8'))
    require(defines.get('XC_BRAND_ID') == 'example' and defines.get('XC_VERSION_NAME') == '1.0.0-pre.1' and defines.get('XC_BUILD_NUMBER') == '10000401', 'example_canonical_identity_required')
    nonce = secrets.token_hex(16)
    output.mkdir(parents=True, mode=0o700)
    (output / '.native-store-owned').write_text(nonce, encoding='utf-8')
    defines.update({'SAFE_MODE': 'true', 'APP_ENV': 'dev', 'XC_NATIVE_STORE_QA': 'true', 'XC_NATIVE_STORE_QA_NONCE': nonce, 'XC_NATIVE_STORE_QA_JOB': job, 'XC_NATIVE_STORE_QA_OUTPUT': str(output)})
    write_new(output / 'defines.json', defines)
    windows_name = defines.get('XC_WINDOWS_APP_NAME', '')
    require(re.fullmatch(r'[A-Za-z0-9_-]+', windows_name), 'example_executable_name_required')
    write_new(output / 'build.json', {'job': job, 'nonce': nonce, 'output': str(output), 'platform': args.platform, 'prepared_ns': time.time_ns(), 'target_sha256': digest(TARGET), 'windows_executable': windows_name + '.exe'})
    print(json.dumps({'prepared': True, 'state_file': str(output / 'build.json'), 'defines_file': str(output / 'defines.json')}))

def generated_config(platform):
    if platform == 'windows':
        return ROOT / 'windows/flutter/ephemeral/generated_config.cmake'
    return ROOT / 'macos/Flutter/ephemeral/Flutter-Generated.xcconfig'

def config_values(file, platform):
    text = file.read_text(encoding='utf-8')
    values = {}
    for key in ('FLUTTER_TARGET', 'DART_DEFINES'):
        pattern = r'^\s*"' + key + r'=(.*)"\s*$' if platform == 'windows' else r'^' + key + r'=(.*)$'
        matches = re.findall(pattern, text, re.MULTILINE)
        require(len(matches) == 1, 'generated_config_field_missing_or_duplicate')
        values[key] = matches[0].replace('\\\\', '\\')
    return values

def verify_defines(encoded, expected):
    decoded = [base64.b64decode(part, validate=True).decode() for part in encoded.split(',')]
    for key, value in expected.items():
        require([part for part in decoded if part.startswith(key + '=')] == [key + '=' + value], 'compiled_qa_define_mismatch')

def verify_result(result):
    fields = {'success', 'canonical_identity', 'write_read', 'reopen', 'replace', 'namespace_isolation', 'individual_delete', 'cleanup_attempted', 'cleanup_verified', 'native_window_visible', 'native_flutter_frame_saved', 'error_classes'}
    require(set(result) == fields and result['error_classes'] == [] and all(value is True for key, value in result.items() if key != 'error_classes'), 'native_safe_receipt_failed')

def process_identity(pid):
    if sys.platform == 'win32':
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.QueryFullProcessImageNameW.argtypes = [wintypes.HANDLE, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
        kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        require(bool(handle), 'process_identity_unavailable')
        try:
            size = wintypes.DWORD(32768)
            path = ctypes.create_unicode_buffer(size.value)
            times = [wintypes.FILETIME() for _ in range(4)]
            require(kernel.QueryFullProcessImageNameW(handle, 0, path, ctypes.byref(size)) and kernel.GetProcessTimes(handle, *[ctypes.byref(value) for value in times]), 'process_identity_unavailable')
            return {'pid': pid, 'executable': str(Path(path.value).resolve()), 'started': times[0].dwHighDateTime << 32 | times[0].dwLowDateTime}
        finally:
            kernel.CloseHandle(handle)
    executable = subprocess.check_output(['/bin/ps', '-ww', '-p', str(pid), '-o', 'comm='], text=True).strip()
    started = subprocess.check_output(['/bin/ps', '-p', str(pid), '-o', 'lstart='], text=True).strip()
    require(bool(executable and started), 'process_identity_unavailable')
    return {'pid': pid, 'executable': str(Path(executable).resolve()), 'started': started}

def network_hash():
    if sys.platform == 'win32':
        import winreg
        values = {}
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, r'Software\Microsoft\Windows\CurrentVersion\Internet Settings') as key:
            for name in ('ProxyEnable', 'ProxyServer', 'ProxyOverride', 'AutoConfigURL'):
                try:
                    values[name] = winreg.QueryValueEx(key, name)[0]
                except FileNotFoundError:
                    values[name] = None
        raw = json.dumps([values, sorted(socket.if_nameindex())], sort_keys=True).encode()
    else:
        raw = subprocess.check_output(['/usr/sbin/scutil', '--proxy']) + subprocess.check_output(['/sbin/ifconfig', '-l'])
    return hashlib.sha256(raw).hexdigest()

def run(args):
    job = ci_identity(args.platform)
    state_file = scoped(args.state)
    state = json.loads(state_file.read_text(encoding='utf-8'))
    output = scoped(state['output'])
    require(state_file == output / 'build.json' and state['job'] == job and state['platform'] == args.platform and re.fullmatch(r'[0-9a-f]{32}', state['nonce']), 'prepared_identity_mismatch')
    require((output / '.native-store-owned').read_text(encoding='utf-8') == state['nonce'] and digest(TARGET) == state['target_sha256'] and not (output / 'launch.json').exists(), 'prepared_source_or_marker_changed')
    require(0 <= time.time_ns() - state['prepared_ns'] <= 7200 * 10**9, 'stale_build_marker')
    source = Path(args.bundle).resolve()
    require(source.is_dir() and source.is_relative_to(ROOT / 'build'), 'bundle_outside_workspace_build')
    config = generated_config(args.platform)
    require(config.is_file() and not config.is_symlink() and config.stat().st_mtime_ns > state['prepared_ns'], 'fresh_generated_config_required')
    values = config_values(config, args.platform)
    target = Path(values['FLUTTER_TARGET'])
    require((target if target.is_absolute() else ROOT / target).resolve() == TARGET, 'alternate_target_required')
    expected = {'SAFE_MODE': 'true', 'XC_BRAND_ID': 'example', 'XC_VERSION_NAME': '1.0.0-pre.1', 'XC_BUILD_NUMBER': '10000401', 'XC_NATIVE_STORE_QA': 'true', 'XC_NATIVE_STORE_QA_NONCE': state['nonce'], 'XC_NATIVE_STORE_QA_JOB': job, 'XC_NATIVE_STORE_QA_OUTPUT': str(output)}
    verify_defines(values['DART_DEFINES'], expected)
    if args.platform == 'windows':
        require(source.parts[-4:] == ('windows', 'x64', 'runner', 'Profile'), 'windows_profile_bundle_required')
        relative_executable = Path(state['windows_executable'])
        require(relative_executable.name == str(relative_executable), 'invalid_windows_executable_name')
        payload = source / 'data/app.so'
    else:
        require(source.parent == ROOT / 'build/macos/Build/Products/Debug' and source.suffix == '.app', 'macos_debug_bundle_required')
        info = plistlib.loads((source / 'Contents/Info.plist').read_bytes())
        require(info.get('CFBundleIdentifier') == 'com.xclient.example.debug' and info.get('FLTEnableImpeller') is False, 'safe_example_debug_app_required')
        name = info.get('CFBundleExecutable', '')
        require(name and Path(name).name == name, 'invalid_executable_name')
        relative_executable = Path('Contents/MacOS') / name
        payload = source / 'Contents/Frameworks/App.framework/Resources/flutter_assets/kernel_blob.bin'
    require(payload.is_file() and payload.resolve().is_relative_to(source) and payload.stat().st_mtime_ns > state['prepared_ns'], 'fresh_dart_payload_required')
    copied = output / ('bundle.app' if args.platform == 'macos' else 'bundle')
    require(not copied.exists(), 'new_bundle_copy_required')
    shutil.copytree(source, copied, symlinks=True)
    executable = (copied / relative_executable).resolve()
    require(executable.is_file() and executable.is_relative_to(copied), 'copied_executable_scope_rejected')
    binary_hash = digest(executable)
    before_network = network_hash()
    env = dict(os.environ, XCLIENT_NATIVE_STORE_QA_OUTPUT=str(output))
    receipt = {'success': False, 'same_job_build': True, 'alternate_target': True, 'fresh_nonce_payload': True, 'owned_process_stopped': False, 'network_unchanged': False, 'error_classes': []}
    child = None
    owner = None
    try:
        child = subprocess.Popen([str(executable)], cwd=executable.parent, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        owner = process_identity(child.pid)
        require(Path(owner['executable']) == executable, 'launched_executable_identity_mismatch')
        write_new(output / 'launch.json', {'pid': child.pid, 'job': job, 'nonce': state['nonce'], 'executable': str(executable), 'start_identity': owner['started'], 'executable_sha256': binary_hash})
        try:
            captured, _ = child.communicate(timeout=100)
        except subprocess.TimeoutExpired:
            raise Refused('native_qa_timeout_cleanup_unconfirmed')
        for line in captured.decode(errors='replace').splitlines():
            try:
                diagnostic = json.loads(line)
            except ValueError:
                continue
            if isinstance(diagnostic, dict) and isinstance(diagnostic.get('success'), bool) and isinstance(diagnostic.get('error_classes'), list):
                safe = {key: value for key, value in diagnostic.items() if isinstance(value, bool)}
                safe['error_classes'] = [] if diagnostic['error_classes'] == [] else ['app_reported_failure']
                write_new(output / 'app-diagnostic.json', safe)
                break
        code = child.returncode
        require(code == 0, 'native_qa_failed_or_permission_denied')
        result = json.loads((output / 'result.json').read_text(encoding='utf-8'))
        verify_result(result)
        png = (output / 'qa.png').read_bytes()
        require(png[:8] == b'\x89PNG\r\n\x1a\n' and len(png) > 1000 and struct.unpack('>II', png[16:24])[0] >= 300 and struct.unpack('>II', png[16:24])[1] >= 200, 'native_flutter_frame_missing')
        receipt['success'] = True
    except Exception as error:
        receipt['error_classes'].append(str(error) if isinstance(error, Refused) else 'launcher_io_or_process_error')
    finally:
        if child is not None and child.poll() is None:
            try:
                require(owner is not None and process_identity(child.pid) == owner, 'cleanup_owner_mismatch')
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    require(process_identity(child.pid) == owner, 'cleanup_owner_mismatch')
                    child.kill()
                    child.wait(timeout=5)
            except Exception:
                receipt['error_classes'].append('owned_process_cleanup_unconfirmed')
        receipt['owned_process_stopped'] = child is not None and child.poll() is not None
        receipt['network_unchanged'] = before_network == network_hash()
        receipt['bundle_unchanged'] = binary_hash == digest(executable)
        receipt['success'] = receipt['success'] and receipt['owned_process_stopped'] and receipt['network_unchanged'] and receipt['bundle_unchanged'] and not receipt['error_classes']
        write_new(output / 'runner-result.json', receipt)
    print(json.dumps(receipt, sort_keys=True))
    return 0 if receipt['success'] else 1

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['prepare', 'run'])
    parser.add_argument('--platform', choices=['windows', 'macos'], required=True)
    parser.add_argument('--output')
    parser.add_argument('--state')
    parser.add_argument('--bundle')
    args = parser.parse_args()
    if args.mode == 'prepare':
        require(args.output is not None, 'new_output_required')
        prepare(args)
        return 0
    require(args.state is not None and args.bundle is not None, 'state_and_bundle_required')
    return run(args)

if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'success': False, 'error_class': str(error) if isinstance(error, Refused) else 'launcher_setup_error'}))
        sys.exit(1)
