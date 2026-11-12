#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_store_smoke as guard
import macos_keychain_ax as ax
import macos_data_keychain as data_keychain
import macos_signing_fixture as signer
from macos_keychain_ax import accessibility_available


def preflight(output):
    guard.ci_identity('macos')
    output = guard.scoped(output)
    guard.require(not output.exists() and not output.is_symlink(), 'fresh_confirmation_preflight_required')
    report = {'scope': 'owned-data-keychain-confirmation-preflight', 'preflight_success': False, 'accessibility_available': False, 'permission_requested': False, 'credentials_created': False, 'keychain_changed': False, 'confirmation_actions': 0, 'error_class': None}
    try:
        report['accessibility_available'] = accessibility_available()
        report['preflight_success'] = report['accessibility_available']
        if not report['preflight_success']:
            report['error_class'] = 'accessibility_permission_unavailable'
    except Exception:
        report['error_class'] = 'accessibility_query_unavailable'
    output.mkdir(mode=0o700, parents=True)
    guard.write_new(output / 'preflight.json', report)
    return report


def pending_read(output, *, now_ms=None):
    now_ms = time.time_ns() // 10**6 if now_ms is None else now_ms
    file = output / 'receipts/store-2-01-begin.json'
    if not file.is_file() or file.is_symlink() or file.stat().st_size > 2048 or (output / 'receipts/store-2-01-end.json').exists() or (output / 'receipts/failure.json').exists():
        return None
    value = json.loads(file.read_text(encoding='utf-8'))
    fields = {'stage', 'id', 'operation', 'event', 'outcome', 'started_ms', 'elapsed_ms'}
    valid = set(value) == fields and value['stage'] == '2' and type(value['id']) is int and value['id'] == 1 and value['operation'] == 'crossRead' and value['event'] == 'begin' and value['outcome'] == 'pending' and type(value['started_ms']) is int and type(value['elapsed_ms']) is int and value['elapsed_ms'] == 0 and 5000 <= now_ms - value['started_ms'] < 14000
    return value if valid else None


def agent_candidates():
    raw = signer.run_tool(['/bin/ps', '-ww', '-axo', 'pid=,comm=']).stdout.decode('utf-8', errors='replace')
    agents = []
    for line in raw.splitlines():
        match = re.fullmatch(r'\s*(\d+)\s+(.+?)\s*', line)
        if match is None:
            continue
        path = Path(match[2])
        if not path.is_absolute() or path.name != 'SecurityAgent' or not path.resolve().is_relative_to('/System/Library'):
            continue
        identity = guard.process_identity(int(match[1]))
        executable = Path(identity['executable']).resolve()
        guard.require(executable == path.resolve(), 'security_agent_image_changed')
        bundle = executable
        for parent in executable.parents:
            if parent.suffix in ('.app', '.bundle'):
                bundle = parent
                break
        verified = signer.run_tool(['/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple', bundle], check=False)
        guard.require(verified.returncode == 0, 'apple_security_agent_required')
        agents.append({'owner': identity, 'executable_sha256': guard.digest(executable)})
    guard.require(len(agents) <= 4, 'bounded_security_agents_required')
    return agents


def verify_action_owner(output, paths, state, owner, executable_sha256, agent):
    data_keychain.full_job()
    guard.require(accessibility_available(), 'accessibility_permission_unavailable')
    guard.require(pending_read(output) is not None, 'owned_cross_read_no_longer_pending')
    _, current_paths, current_state = data_keychain._load(output)
    guard.require(current_state['nonce'] == state['nonce'] and current_paths['keychain'] == paths['keychain'], 'confirmation_generation_changed')
    data_keychain.active_state(current_paths, current_state)
    guard.require(guard.process_identity(owner['pid']) == owner, 'confirmation_app_owner_changed')
    executable = Path(owner['executable']).resolve()
    guard.require(executable.name == 'ExampleClient' and executable.is_relative_to(output / 'private/installed') and guard.digest(executable) == executable_sha256, 'owned_confirmation_app_image_required')
    agent_owner = agent['owner']
    guard.require(guard.process_identity(agent_owner['pid']) == agent_owner and guard.digest(Path(agent_owner['executable'])) == agent['executable_sha256'], 'security_agent_owner_changed')
    return True


def maybe_confirm(output, owner, executable_sha256, before_action):
    output, paths, state = data_keychain._load(output)
    if state['confirmation_completed']:
        return True
    guard.require(not state['confirmation_attempted'] and state['phase'] == 'active' and state['item_metadata_verified'] is True, 'bounded_confirmation_attempt_required')
    if pending_read(output) is None:
        return False
    sessions, matches = [], []
    try:
        for agent in agent_candidates():
            session = ax.Session(agent['owner']['pid'])
            sessions.append(session)
            for snapshot in session.snapshots():
                try:
                    selected = ax.select_dialog(snapshot, paths['label'], paths['service'])
                except guard.Refused as error:
                    if str(error) == 'owned_confirmation_dialog_not_matched':
                        continue
                    raise
                matches.append((session, selected, agent))
        if not matches:
            return False
        guard.require(len(matches) == 1, 'unique_owned_confirmation_dialog_required')
        session, selected, agent = matches[0]
        def check_owner():
            return verify_action_owner(output, paths, state, owner, executable_sha256, agent)
        def claim():
            _, _, current = data_keychain._load(output)
            guard.require(not current['confirmation_attempted'], 'bounded_confirmation_attempt_required')
            current['confirmation_attempted'] = True
            current['phase'] = 'confirming'
            data_keychain.save(paths, current)
        def supplied_password():
            _, _, current = data_keychain._load(output)
            return data_keychain.password(paths, current)
        action = ax.confirm_dialog(session, selected, paths['label'], paths['service'], check_owner=check_owner, password_supplier=supplied_password, claim_attempt=claim, before_action=before_action)
        _, _, current = data_keychain._load(output)
        current['confirmation_completed'] = True
        current['phase'] = 'confirmed'
        data_keychain.save(paths, current)
        guard.write_new(output / 'receipts/confirmation.json', {'scope': 'nonce-owned-disposable-data-keychain', 'consent_simulated': True, 'original_login_password_accessed': False, 'owned_item_metadata_verified': True, 'dialog_fingerprint': selected['fingerprint'], 'service_sha256': hashlib.sha256(paths['service'].encode()).hexdigest(), 'confirmation_actions': 1, **action})
        return True
    finally:
        for session in sessions:
            session.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    report = preflight(args.output)
    print(json.dumps(report, sort_keys=True))
    return 0 if report['preflight_success'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'preflight_success': False, 'error_class': str(error) if isinstance(error, guard.Refused) else 'confirmation_preflight_setup_failed'}))
        sys.exit(1)
