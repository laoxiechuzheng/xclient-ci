import hashlib
import json
from pathlib import Path
import re
import secrets
import time

import macos_keychain_ax as ax
import macos_signing_fixture as signer
import native_store_smoke as guard

MODE = 'confirm-owned'
SOURCE_NAMES = ('macos_data_keychain.py', 'macos_keychain_ax.py', 'macos_keychain_confirmation.py')


def validate_mode(platform, signing, mode):
    guard.require(mode in ('disabled', MODE) and (mode == 'disabled' or (platform == 'macos' and signing in ('adhoc', signer.MODE))), 'owned_confirmation_mode_rejected')


def full_job():
    return ax.confirmation_job()


def source_hashes():
    return {name: guard.digest(Path(__file__).with_name(name)) for name in SOURCE_NAMES}


def locations(output, nonce):
    guard.require(re.fullmatch('[0-9a-f]{32}', nonce) is not None, 'confirmation_nonce_invalid')
    label = 'xclient-qa-data-' + nonce[:12]
    directory = output / 'private/confirmation'
    return {'directory': directory, 'state': directory / 'state.json', 'marker': directory / '.owned', 'keychain': directory / (label + '.keychain-db'), 'password': directory / 'password', 'label': label, 'service': 'com.xclient.q' + nonce[:12] + '.secure-storage'}


def aliases(paths):
    return str(paths['keychain']), str(paths['keychain']).removesuffix('-db')


def verify_keychain_path(paths):
    target = paths['keychain']
    guard.require(target.is_file() and not target.is_symlink() and target.resolve() == target, 'owned_data_keychain_path_changed')
    legacy = Path(aliases(paths)[1])
    guard.require(not legacy.exists() or (legacy.is_symlink() and legacy.resolve() == target), 'owned_data_keychain_alias_changed')


def save(paths, state):
    guard.require(paths['directory'].resolve() == paths['directory'] and not paths['state'].is_symlink(), 'confirmation_state_scope_rejected')
    temporary = paths['state'].with_name('state.next')
    with temporary.open('x', encoding='utf-8') as stream:
        json.dump(state, stream, sort_keys=True)
        stream.flush()
    temporary.replace(paths['state'])


def prepare(output, job, nonce):
    guard.require(full_job() == job, 'confirmation_job_mismatch')
    output = guard.scoped(output)
    paths = locations(output, nonce)
    guard.require((output / '.native-update-owned').read_text(encoding='ascii') == nonce, 'confirmation_outer_marker_mismatch')
    guard.require(not paths['directory'].exists() and not paths['directory'].is_symlink(), 'new_confirmation_directory_required')
    paths['directory'].mkdir(mode=0o700)
    paths['marker'].write_text(nonce, encoding='ascii')
    save(paths, {'mode': MODE, 'job': job, 'nonce': nonce, 'output': str(output), 'prepared_ns': time.time_ns(), 'sources': source_hashes(), 'phase': 'prepared', 'original': None, 'create_attempted': False, 'password_sha256': None, 'item_metadata_verified': False, 'confirmation_attempted': False, 'confirmation_completed': False})


def _load(output):
    job = full_job()
    output = guard.scoped(output)
    state_file = output / 'private/confirmation/state.json'
    guard.require(state_file.is_file() and not state_file.is_symlink(), 'owned_confirmation_state_required')
    state = json.loads(state_file.read_text(encoding='utf-8'))
    paths = locations(output, state['nonce'])
    guard.require(paths['directory'].resolve() == paths['directory'] and state['mode'] == MODE and state['job'] == job and state['output'] == str(output) and state['sources'] == source_hashes(), 'confirmation_state_identity_mismatch')
    guard.require(paths['marker'].read_text(encoding='ascii') == state['nonce'] and (output / '.native-update-owned').read_text(encoding='ascii') == state['nonce'], 'confirmation_marker_mismatch')
    guard.require(0 <= time.time_ns() - state['prepared_ns'] < 7200 * 10**9, 'confirmation_state_expired')
    return output, paths, state


def restorable(original, current, owned):
    return current['login'] == original['login'] and current['default'] in (original['default'], *owned) and [path for path in current['search'] if path not in owned] == original['search']


def restore_original(paths, state):
    original = state['original']
    if original is None:
        guard.require(not state['create_attempted'], 'confirmation_original_state_unknown')
        return True
    current = signer.snapshot()
    guard.require(restorable(original, current, aliases(paths)), 'confirmation_external_keychain_state_changed')
    if current['default'] != original['default']:
        signer.run_tool(['/usr/bin/security', 'default-keychain', '-d', 'user', '-s', original['default']])
    if current['search'] != original['search']:
        signer.run_tool(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', *original['search']])
    guard.require(signer.snapshot() == original, 'confirmation_original_state_not_restored')
    return True


def active_state(paths, state):
    verify_keychain_path(paths)
    current = signer.snapshot()
    canonical = lambda path: str(paths['keychain']) if path in aliases(paths) else path
    guard.require(current['login'] == state['original']['login'] and current['default'] in aliases(paths) and [canonical(path) for path in current['search']] == [str(paths['keychain']), *state['original']['search']], 'owned_data_keychain_not_active')
    return True


def verify_synthetic_item(paths, state):
    active_state(paths, state)
    result = signer.run_tool(['/usr/bin/security', 'find-generic-password', '-s', paths['service'], paths['keychain']], check=False)
    guard.require(result.returncode == 0, 'owned_synthetic_item_metadata_query_failed')
    guard.require(len(result.stdout) <= 65536, 'bounded_synthetic_metadata_required')
    lines = result.stdout.decode('utf-8').splitlines()
    keychains = [line.removeprefix('keychain: ').strip() for line in lines if line.startswith('keychain: ')]
    services = [line.strip() for line in lines if line.lstrip().startswith('"svce"')]
    guard.require(keychains == ['"' + str(paths['keychain']) + '"'], 'owned_synthetic_keychain_path_unconfirmed')
    guard.require(services == ['"svce"<blob>="' + paths['service'] + '"'], 'owned_synthetic_service_unconfirmed')
    return True


def prove_item_placement(output):
    output, paths, state = _load(output)
    guard.require(state['phase'] == 'active' and not state.get('confirmation_attempted'), 'owned_item_placement_phase_rejected')
    guard.require(verify_synthetic_item(paths, state) is True, 'owned_synthetic_item_metadata_unconfirmed')
    state['item_metadata_verified'] = True
    save(paths, state)
    report = {'owned_item_metadata_verified': True, 'metadata_only': True, 'keychain_path_sha256': hashlib.sha256(str(paths['keychain']).encode()).hexdigest(), 'service_sha256': hashlib.sha256(paths['service'].encode()).hexdigest()}
    guard.write_new(output / 'receipts/confirmation-item.json', report)
    return report


def password(paths, state):
    file = paths['password']
    guard.require(file.is_file() and not file.is_symlink() and guard.digest(file) == state['password_sha256'], 'confirmation_password_changed')
    value = file.read_text(encoding='ascii')
    guard.require(re.fullmatch('[0-9a-f]{64}', value) is not None, 'confirmation_password_invalid')
    return value


def begin(output):
    output, paths, state = _load(output)
    guard.require(state['phase'] == 'prepared', 'new_confirmation_run_required')
    guard.require(ax.accessibility_available(), 'accessibility_permission_unavailable')
    guard.require(all(not Path(value).exists() and not Path(value).is_symlink() for value in aliases(paths)), 'new_data_keychain_required')
    state['original'] = signer.snapshot()
    guard.require(not any(value in aliases(paths) for value in (state['original']['default'], state['original']['login'], *state['original']['search'])), 'data_keychain_preexisted_in_preferences')
    state['phase'] = 'creating'
    save(paths, state)
    try:
        value = secrets.token_hex(32)
        with paths['password'].open('x', encoding='ascii') as stream:
            stream.write(value)
        paths['password'].chmod(0o600)
        state['password_sha256'] = guard.digest(paths['password'])
        state['create_attempted'] = True
        save(paths, state)
        signer.run_tool(['/usr/bin/security', 'create-keychain', '-p', value, paths['keychain']])
        verify_keychain_path(paths)
        signer.run_tool(['/usr/bin/security', 'unlock-keychain', '-p', value, paths['keychain']])
        signer.run_tool(['/usr/bin/security', 'set-keychain-settings', '-lut', '7200', paths['keychain']])
        guard.require(restorable(state['original'], signer.snapshot(), aliases(paths)), 'confirmation_external_keychain_state_changed')
        signer.run_tool(['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', str(paths['keychain']), *state['original']['search']])
        signer.run_tool(['/usr/bin/security', 'default-keychain', '-d', 'user', '-s', paths['keychain']])
        active_state(paths, state)
        state['phase'] = 'active'
        save(paths, state)
    except Exception:
        state['phase'] = 'failed'
        try:
            restore_original(paths, state)
        finally:
            save(paths, state)
        raise
    return {'owned_data_keychain_active': True, 'original_login_unchanged': True, 'permission_requested': False, 'credentials_created': True}


def cleanup(output):
    output, paths, state = _load(output)
    report = {'success': False, 'original_state_restored': False, 'owned_keychain_absent': False, 'password_removed': False, 'error_classes': []}
    try:
        if state['create_attempted']:
            process_rows = signer.run_tool(['/bin/ps', '-axo', 'comm=']).stdout.decode('utf-8', errors='replace').splitlines()
            guard.require(not any(Path(line.strip()).name == 'ExampleClient' for line in process_rows), 'confirmation_app_still_running')
        report['original_state_restored'] = restore_original(paths, state)
        if any(Path(path).exists() for path in aliases(paths)):
            guard.require(state['create_attempted'], 'unexpected_confirmation_keychain')
            verify_keychain_path(paths)
            signer.run_tool(['/usr/bin/security', 'delete-keychain', paths['keychain']])
        report['owned_keychain_absent'] = not any(Path(path).exists() for path in aliases(paths))
        guard.require(report['owned_keychain_absent'], 'owned_data_keychain_delete_unconfirmed')
        if paths['password'].exists():
            guard.require(not paths['password'].is_symlink(), 'confirmation_password_scope_changed')
            paths['password'].unlink()
        report['password_removed'] = not paths['password'].exists()
    except Exception as error:
        report['error_classes'].append(str(error) if isinstance(error, guard.Refused) else 'confirmation_cleanup_failed')
    report['success'] = all(report[key] is True for key in ('original_state_restored', 'owned_keychain_absent', 'password_removed')) and not report['error_classes']
    state['phase'] = 'cleaned' if report['success'] else 'cleanupFailed'
    save(paths, state)
    receipt = output / 'receipts/confirmation-cleanup.json'
    if not receipt.exists():
        guard.write_new(receipt, report)
    else:
        guard.require(json.loads(receipt.read_text())['success'] is True and report['success'], 'confirmation_cleanup_prior_failure')
    guard.require(report['success'], 'confirmation_cleanup_unconfirmed')
    return report
