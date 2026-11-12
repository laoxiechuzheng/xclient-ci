import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import time

import native_store_smoke as guard

MODE = 'ephemeral-self-signed'
SOURCE = Path(__file__).resolve()
PREFLIGHT_ID = 'com.xclient.qa.signing-preflight'
PREFLIGHT_CHECKS = ('identity_unique', 'first_embedded_certificate', 'second_embedded_certificate', 'first_self', 'second_self', 'second_matches_first', 'first_matches_second', 'foreign_signature_valid', 'foreign_rejected', 'original_state_restored')


class SigningCommandFailure(guard.Refused):
    def __init__(self, arguments, result):
        super().__init__('signing_command_failed')
        program = Path(str(arguments[0])).name
        program = program if program in ('security', 'codesign', 'openssl', 'xcrun') else 'unknown'
        operations = ('create-keychain', 'unlock-keychain', 'set-keychain-settings', 'import', 'find-identity', 'set-key-partition-list', 'delete-keychain', '--sign', '--verify', '--display', 'req', 'pkcs12', 'x509')
        operation = next((value for value in operations if value in arguments), 'unknown')
        text = (result.stdout + result.stderr).decode('utf-8', errors='replace')
        reasons = ('CSSMERR_TP_NOT_TRUSTED', 'CSSMERR_TP_CERT_EXPIRED', 'CSSMERR_TP_CERT_NOT_VALID_YET', 'errSecInternalComponent', 'errSecInteractionNotAllowed', 'errSecAuthFailed', 'no identity found', 'unable to build chain', 'code object is not signed at all')
        reason = next((value for value in reasons if value in text), 'unknown')
        vocabulary = set('a an the this identity certificate private key keychain code signing signature cannot can be used use for not no valid invalid trusted trust root chain self signed unable build expired yet supported unsupported format operation failed error permission access denied interaction allowed found could requested item specified does exist have has been modified object is missing internal component required public application policy unrecognized type value algorithm'.split())
        words = [word for word in re.findall('[a-z]+', text.lower()) if word in vocabulary][:48]
        self.diagnostic = {'program': program, 'operation': operation, 'exit_code': result.returncode, 'reason': reason, 'message_words': words}


def designated_requirement(description):
    lines = [line for line in description.splitlines() if 'designated =>' in line]
    if len(lines) == 1:
        match = re.fullmatch(r'(# )?designated => ([^\r\n\0]+)', lines[0])
        if match and match[2].strip() and len(match[2]) <= 8192:
            return match[2], 'implicit' if match[1] else 'explicit'
    return None, 'unknown'


def requirement_diagnostic(requirement):
    if requirement is None:
        return {'available': False, 'form': 'unknown', 'sha256': None}
    if re.fullmatch(r'cdhash H"(?:[0-9a-fA-F]{40}|[0-9a-fA-F]{64})"', requirement):
        form = 'cdhashOnly'
    elif 'cdhash ' in requirement:
        form = 'containsCdhash'
    elif 'anchor ' in requirement or 'certificate ' in requirement:
        form = 'certificateRequirement'
    else:
        form = 'other'
    return {'available': True, 'form': form, 'sha256': hashlib.sha256(requirement.encode('utf-8')).hexdigest()}


def requirement_matches(bundle, requirement_file, *, expected_sha256):
    guard.require(requirement_file.is_file() and not requirement_file.is_symlink() and 0 < requirement_file.stat().st_size <= 8192 and guard.digest(requirement_file) == expected_sha256, 'requirement_input_changed')
    requirement = requirement_file.read_text(encoding='utf-8')
    guard.require(not any(char in requirement for char in ('\n', '\r', '\0')), 'single_requirement_required')
    result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, str(bundle)], capture_output=True, timeout=10)
    return result.returncode == 0


def stage_requirement(bundle, private, stage):
    guard.require(stage in ('1', '2'), 'fixed_upgrade_stage_required')
    report = {**requirement_diagnostic(None), 'source': 'unknown', 'self_match': None, 'reason': 'unavailable'}
    try:
        displayed = subprocess.run(['/usr/bin/codesign', '--display', '-r', '-', str(bundle)], capture_output=True, timeout=10)
        if displayed.returncode != 0:
            return {**report, 'reason': 'displayFailed'}
        raw = (displayed.stdout + displayed.stderr).decode('utf-8', errors='replace')
        requirement, source = designated_requirement(raw)
        report['source'] = source
        report.update(requirement_diagnostic(requirement))
        if requirement is None:
            return {**report, 'reason': 'missingRequirement'}
        file = private / ('v' + stage + '-designated.req')
        with file.open('x', encoding='utf-8') as stream:
            stream.write(requirement)
        report['self_match'] = requirement_matches(bundle, file, expected_sha256=report['sha256'])
        report['reason'] = 'complete' if report['self_match'] else 'selfCheckFailed'
    except Exception as error:
        report['reason'] = 'processTimeout' if isinstance(error, subprocess.TimeoutExpired) else 'diagnosticFailed'
    return report


def validate_mode(platform, mode):
    guard.require(platform in ('windows', 'macos') and mode in ('adhoc', MODE) and (mode != MODE or platform == 'macos'), 'macos_signing_mode_rejected')


def run_tool(arguments, *, timeout=30, check=True):
    try:
        result = subprocess.run([str(value) for value in arguments], cwd=guard.ROOT, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        raise guard.Refused('signing_command_timeout') from None
    except Exception:
        raise guard.Refused('signing_command_failed') from None
    if check and result.returncode != 0:
        raise SigningCommandFailure(arguments, result)
    return result


def parse_snapshot(default, login, search):
    values = [shlex.split(value) for value in (default, login, search)]
    guard.require(len(values[0]) == 1 and len(values[1]) == 1 and 0 < len(values[2]) <= 32 and len(set(values[2])) == len(values[2]), 'signing_keychain_snapshot_invalid')
    guard.require(all(path.startswith('/') and not any(char in path for char in ('\0', '\n', '\r')) for group in values for path in group), 'signing_keychain_snapshot_invalid')
    return {'default': values[0][0], 'login': values[1][0], 'search': values[2]}


def snapshot():
    values = []
    for operation in ('default-keychain', 'login-keychain', 'list-keychains'):
        domain = [] if operation == 'login-keychain' else ['-d', 'user']
        observed = run_tool(['/usr/bin/security', operation, *domain], check=False)
        guard.require(observed.returncode == 0, 'signing_snapshot_' + operation + '_exit_' + str(observed.returncode))
        values.append(observed.stdout.decode('utf-8'))
    return parse_snapshot(*values)


def restorable_snapshot(original, current, owned):
    return current['default'] == original['default'] and current['login'] == original['login'] and [path for path in current['search'] if path not in owned] == original['search']


def require_preflight(report):
    guard.require(all(report.get(key) is True for key in PREFLIGHT_CHECKS), 'signing_preflight_incomplete')


def certificate_config(nonce):
    guard.require(re.fullmatch('[0-9a-f]{32}', nonce), 'signing_nonce_invalid')
    return '[req]\nprompt=no\ndistinguished_name=dn\n[dn]\nCN=XClient QA ' + nonce + '\n[code_signing]\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=critical,codeSigning\nsubjectKeyIdentifier=hash\n'


def paths(output):
    directory = output / 'private/signing'
    return {'directory': directory, 'state': directory / 'state.json', 'marker': directory / '.owned', 'keychain': directory / 'qa-signing.keychain-db', 'password': directory / 'password', 'config': directory / 'request.cnf', 'key': directory / 'identity.key', 'certificate': directory / 'identity.crt', 'container': directory / 'identity.p12', 'preflight': directory / 'preflight'}


def _write_state(locations, state):
    target = locations['state']
    guard.require(not target.is_symlink() and locations['directory'].resolve() == locations['directory'], 'signing_state_scope_rejected')
    temporary = target.with_name('state.next')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(state, stream, sort_keys=True)
        stream.flush()
    temporary.replace(target)


def _load(output):
    job = guard.ci_identity('macos')
    output = guard.scoped(output)
    locations = paths(output)
    guard.require(locations['directory'].resolve() == locations['directory'] and not locations['directory'].is_symlink() and locations['state'].is_file() and not locations['state'].is_symlink(), 'owned_signing_state_required')
    state = json.loads(locations['state'].read_text(encoding='utf-8'))
    guard.require(state['mode'] == MODE and state['job'] == job and state['output'] == str(output) and state['keychain'] == str(locations['keychain']) and state['source_sha256'] == guard.digest(SOURCE), 'signing_state_identity_mismatch')
    nonce = state['nonce']
    guard.require(re.fullmatch('[0-9a-f]{32}', nonce) and locations['marker'].read_text(encoding='ascii') == nonce and (output / '.native-update-owned').read_text(encoding='ascii') == nonce, 'signing_marker_mismatch')
    guard.require(0 <= time.time_ns() - state['prepared_ns'] < 7200 * 10**9, 'signing_state_expired')
    return output, locations, state


def prepare(output, job, nonce):
    guard.require(guard.ci_identity('macos') == job, 'signing_job_mismatch')
    output = guard.scoped(output)
    locations = paths(output)
    guard.require(re.fullmatch('[0-9a-f]{32}', nonce) and not locations['directory'].exists() and not locations['directory'].is_symlink(), 'new_signing_directory_required')
    locations['directory'].mkdir(mode=0o700)
    locations['marker'].write_text(nonce, encoding='ascii')
    state = {'mode': MODE, 'job': job, 'nonce': nonce, 'output': str(output), 'keychain': str(locations['keychain']), 'source_sha256': guard.digest(SOURCE), 'prepared_ns': time.time_ns(), 'phase': 'prepared', 'original': None, 'keychain_create_attempted': False, 'certificate_sha1': None, 'certificate_sha256': None, 'material_hashes': {}}
    _write_state(locations, state)


def _aliases(locations):
    return (str(locations['keychain']), str(locations['keychain']).removesuffix('-db'))


def _restore(locations, state):
    original = state['original']
    if original is None:
        guard.require(not state['keychain_create_attempted'], 'signing_original_state_unknown')
        return True
    current = snapshot()
    guard.require(restorable_snapshot(original, current, _aliases(locations)), 'signing_external_keychain_state_changed')
    if current['search'] != original['search']:
        run_tool(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original['search']])
    guard.require(snapshot() == original, 'signing_keychain_state_not_restored')
    return True


def _private_text(file, text):
    with file.open('x', encoding='ascii') as stream:
        stream.write(text)
    file.chmod(0o600)


def _password(locations, state):
    file = locations['password']
    guard.require(file.is_file() and not file.is_symlink() and guard.digest(file) == state['material_hashes'].get('password'), 'signing_password_changed')
    value = file.read_text(encoding='ascii')
    guard.require(re.fullmatch('[0-9a-f]{64}', value), 'signing_password_invalid')
    return value


def _materials_unchanged(locations, state):
    for name in ('password', 'key', 'certificate', 'container'):
        file = locations[name]
        guard.require(file.is_file() and not file.is_symlink() and file.resolve() == file and guard.digest(file) == state['material_hashes'].get(name), 'signing_material_changed')


def _generate(locations, state):
    openssl = shutil.which('openssl')
    guard.require(openssl is not None, 'existing_openssl_required')
    _private_text(locations['password'], secrets.token_hex(32))
    _private_text(locations['config'], certificate_config(state['nonce']))
    run_tool([openssl, 'req', '-new', '-x509', '-newkey', 'rsa:2048', '-nodes', '-sha256', '-days', '1', '-config', locations['config'], '-extensions', 'code_signing', '-keyout', locations['key'], '-out', locations['certificate']])
    locations['key'].chmod(0o600)
    run_tool([openssl, 'pkcs12', '-export', '-inkey', locations['key'], '-in', locations['certificate'], '-out', locations['container'], '-passout', 'file:' + str(locations['password'])])
    locations['container'].chmod(0o600)
    der = run_tool([openssl, 'x509', '-in', locations['certificate'], '-outform', 'DER']).stdout
    state['certificate_sha1'] = hashlib.sha1(der).hexdigest()
    state['certificate_sha256'] = hashlib.sha256(der).hexdigest()
    state['material_hashes'] = {name: guard.digest(locations[name]) for name in ('password', 'key', 'certificate', 'container')}
    _write_state(locations, state)


def _identity_hashes(locations):
    value = run_tool(['/usr/bin/security', 'find-identity', '-p', 'codesigning', locations['keychain']]).stdout.decode('utf-8', errors='replace')
    return {match.lower() for match in re.findall(r'\b[0-9a-fA-F]{40}\b', value)}


def _create_keychain(locations, state):
    state['keychain_create_attempted'] = True
    _write_state(locations, state)
    password = _password(locations, state)
    run_tool(['/usr/bin/security', 'create-keychain', '-p', password, locations['keychain']])
    run_tool(['/usr/bin/security', 'unlock-keychain', '-p', password, locations['keychain']])
    run_tool(['/usr/bin/security', 'set-keychain-settings', '-lut', '7200', locations['keychain']])
    run_tool(['/usr/bin/security', 'import', locations['container'], '-k', locations['keychain'], '-P', password, '-T', '/usr/bin/codesign'])
    guard.require(_identity_hashes(locations) == {state['certificate_sha1']}, 'single_owned_signing_identity_required')
    run_tool(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple:', '-s', '-k', password, locations['keychain']])


def _sign(locations, state, target, identifier, entitlements=None):
    guard.require(re.fullmatch('[0-9a-f]{40}', state['certificate_sha1']) and target.resolve() == target and (target.is_relative_to(locations['preflight']) or (target.is_relative_to(guard.ROOT / 'build') and target.name == 'ExampleClient.app')), 'signing_target_rejected')
    command = ['/usr/bin/codesign', '--force', '--sign', state['certificate_sha1'], '--keychain', str(locations['keychain']), '--identifier', identifier, '--timestamp=none']
    if entitlements is not None:
        guard.require(entitlements == guard.ROOT / 'macos/Runner/Release.entitlements', 'signing_entitlements_rejected')
        command += ['--deep', '--entitlements', str(entitlements)]
    current = snapshot()
    guard.require(restorable_snapshot(state['original'], current, _aliases(locations)), 'signing_external_keychain_state_changed')
    try:
        if str(locations['keychain']) not in current['search']:
            run_tool(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', str(locations['keychain']), *state['original']['search']])
        run_tool([*command, target])
        run_tool(['/usr/bin/codesign', '--verify', '--deep', '--strict', target])
    finally:
        _restore(locations, state)


def _embedded_matches(locations, state, target, label):
    guard.require(re.fullmatch(r'(mini[12]|stage[12])', label), 'signing_extract_label_invalid')
    directory = locations['directory'] / 'embedded'
    directory.mkdir(exist_ok=True)
    prefix = directory / (label + '-')
    guard.require(not Path(str(prefix) + '0').exists(), 'fresh_signing_extract_required')
    run_tool(['/usr/bin/codesign', '--display', '--extract-certificates=' + str(prefix), target])
    leaf = Path(str(prefix) + '0')
    guard.require(leaf.is_file() and not leaf.is_symlink(), 'embedded_signing_certificate_unavailable')
    return guard.digest(leaf) == state['certificate_sha256']


def preflight(output):
    output, locations, state = _load(output)
    guard.require(state['phase'] == 'prepared', 'new_signing_preflight_required')
    report = {'success': False, 'mode': MODE, 'checkpoint': 'snapshot', **{key: False for key in PREFLIGHT_CHECKS}, 'certificate_sha256': None, 'error_classes': []}
    try:
        state['original'] = snapshot()
        guard.require(all(Path(state['original'][key]).is_file() for key in ('default', 'login')), 'original_keychain_unavailable')
        state['phase'] = 'preflighting'
        _write_state(locations, state)
        report['checkpoint'] = 'generateIdentity'
        _generate(locations, state)
        report['certificate_sha256'] = state['certificate_sha256']
        report['checkpoint'] = 'importIdentity'
        _create_keychain(locations, state)
        report['identity_unique'] = _identity_hashes(locations) == {state['certificate_sha1']}
        report['checkpoint'] = 'compileMiniatures'
        directory = locations['preflight']
        directory.mkdir()
        binaries = []
        for number in (1, 2):
            source, binary = directory / ('version' + str(number) + '.c'), directory / ('version' + str(number))
            _private_text(source, 'int main(void) { return ' + str(number) + '; }\n')
            run_tool(['/usr/bin/xcrun', '--sdk', 'macosx', 'clang', '-O0', source, '-o', binary], timeout=60)
            binaries.append(binary)
        foreign = directory / 'foreign'
        shutil.copy2(binaries[1], foreign)
        run_tool(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', PREFLIGHT_ID, foreign])
        run_tool(['/usr/bin/codesign', '--verify', '--strict', foreign])
        report['foreign_signature_valid'] = True
        report['checkpoint'] = 'signMiniatures'
        report['signing_keychain_was_in_searchlist'] = str(locations['keychain']) in snapshot()['search']
        for number, binary in enumerate(binaries, 1):
            _sign(locations, state, binary, PREFLIGHT_ID)
            report['first_embedded_certificate' if number == 1 else 'second_embedded_certificate'] = _embedded_matches(locations, state, binary, 'mini' + str(number))
        report['checkpoint'] = 'miniatureRequirements'
        first, second = [stage_requirement(binary, directory, str(number)) for number, binary in enumerate(binaries, 1)]
        report['first_self'], report['second_self'] = first['self_match'] is True, second['self_match'] is True
        report['second_matches_first'] = requirement_matches(binaries[1], directory / 'v1-designated.req', expected_sha256=first['sha256'])
        report['first_matches_second'] = requirement_matches(binaries[0], directory / 'v2-designated.req', expected_sha256=second['sha256'])
        report['foreign_rejected'] = not requirement_matches(foreign, directory / 'v1-designated.req', expected_sha256=first['sha256'])
    except Exception as error:
        report['error_classes'].append(str(error) if isinstance(error, guard.Refused) else 'signing_preflight_failed')
        if isinstance(error, SigningCommandFailure):
            report['command_failure'] = error.diagnostic
    finally:
        try:
            report['original_state_restored'] = _restore(locations, state)
        except Exception:
            report['error_classes'].append('signing_keychain_restore_unconfirmed')
        report['success'] = all(report[key] is True for key in PREFLIGHT_CHECKS) and not report['error_classes']
        state['phase'] = 'ready' if report['success'] else 'failed'
        state['preflight'] = report
        _write_state(locations, state)
        guard.write_new(output / 'receipts/signing-preflight.json', report)
    require_preflight(report)
    return report


def sign_bundle(output, bundle, stage):
    output, locations, state = _load(output)
    guard.require(stage in ('1', '2') and state['phase'] == 'ready', 'signing_fixture_not_ready')
    require_preflight(state['preflight'])
    _materials_unchanged(locations, state)
    guard.require(snapshot() == state['original'] and _identity_hashes(locations) == {state['certificate_sha1']}, 'signing_identity_or_original_state_changed')
    run_tool(['/usr/bin/security', 'unlock-keychain', '-p', _password(locations, state), locations['keychain']])
    try:
        _sign(locations, state, bundle, 'com.xclient.example', guard.ROOT / 'macos/Runner/Release.entitlements')
        guard.require(_embedded_matches(locations, state, bundle, 'stage' + stage), 'staged_signing_certificate_mismatch')
    finally:
        _restore(locations, state)
    return {'mode': MODE, 'certificate_sha256': state['certificate_sha256'], 'embedded_certificate_matches': True}


def verify_ready(output):
    _, locations, state = _load(output)
    guard.require(state['phase'] == 'ready', 'signing_fixture_not_ready')
    require_preflight(state['preflight'])
    _materials_unchanged(locations, state)
    guard.require(snapshot() == state['original'] and _identity_hashes(locations) == {state['certificate_sha1']}, 'signing_identity_or_original_state_changed')
    return True


def cleanup(output):
    output, locations, state = _load(output)
    report = {'success': False, 'mode': MODE, 'owned_keychain_absent': False, 'private_material_removed': False, 'original_state_restored': False, 'error_classes': []}
    try:
        if state['keychain_create_attempted'] and any(Path(value).exists() for value in _aliases(locations)):
            run_tool(['/usr/bin/security', 'delete-keychain', locations['keychain']])
        report['original_state_restored'] = _restore(locations, state)
        for item in locations['directory'].iterdir():
            if item.name in ('state.json', '.owned'):
                continue
            if item.is_dir() and not item.is_symlink():
                guard.require(item.resolve() == item and item.is_relative_to(locations['directory']), 'signing_cleanup_scope_rejected')
                shutil.rmtree(item)
            else:
                item.unlink()
        report['owned_keychain_absent'] = not any(Path(value).exists() for value in _aliases(locations))
        report['private_material_removed'] = {item.name for item in locations['directory'].iterdir()} <= {'state.json', '.owned'}
    except Exception as error:
        report['error_classes'].append(str(error) if isinstance(error, guard.Refused) else 'signing_cleanup_failed')
    report['success'] = all(report[key] is True for key in ('owned_keychain_absent', 'private_material_removed', 'original_state_restored')) and not report['error_classes']
    state['phase'] = 'cleaned' if report['success'] else 'cleanupFailed'
    _write_state(locations, state)
    receipt = output / 'receipts/signing-cleanup.json'
    if not receipt.exists():
        guard.write_new(receipt, report)
    else:
        previous = json.loads(receipt.read_text(encoding='utf-8'))
        guard.require(previous.get('success') is True and report['success'], 'signing_cleanup_prior_failure')
    guard.require(report['success'], 'signing_cleanup_unconfirmed')
    return report
