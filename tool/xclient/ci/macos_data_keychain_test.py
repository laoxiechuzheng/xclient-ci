import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('macos_data_keychain', Path(__file__).with_name('macos_data_keychain.py'))
data = importlib.util.module_from_spec(spec)
spec.loader.exec_module(data)


class DataKeychainTest(unittest.TestCase):
    def test_shipping_adhoc_confirmation_uses_the_same_owned_mac_gate(self):
        failure = None
        try:
            data.validate_mode('macos', 'adhoc', 'confirm-owned')
        except data.guard.Refused as error:
            failure = str(error)
        self.assertIsNone(failure)

    def test_confirmation_mode_requires_the_owned_mac_and_known_signing_mode(self):
        data.validate_mode('macos', 'ephemeral-self-signed', 'confirm-owned')
        data.validate_mode('windows', 'adhoc', 'disabled')
        for platform, signing, mode in [('windows', 'ephemeral-self-signed', 'confirm-owned'), ('windows', 'adhoc', 'confirm-owned'), ('macos', 'unknown-signer', 'confirm-owned'), ('macos', 'ephemeral-self-signed', 'other')]:
            with self.assertRaises(data.guard.Refused):
                data.validate_mode(platform, signing, mode)

    def test_only_owned_default_or_original_state_can_be_restored(self):
        original = {'default': '/login', 'login': '/login', 'search': ['/login', '/system']}
        owned = ('/private/data.keychain-db', '/private/data.keychain')
        self.assertTrue(data.restorable(original, original, owned))
        self.assertTrue(data.restorable(original, {**original, 'default': owned[0], 'search': [owned[0], '/login', '/system']}, owned))
        for value in [{**original, 'default': '/unknown'}, {**original, 'login': '/unknown'}, {**original, 'search': ['/system', '/login']}, {**original, 'search': ['/unknown', '/login', '/system']}]:
            self.assertFalse(data.restorable(original, value, owned))

    def test_unavailable_permission_precedes_all_credential_and_keychain_actions(self):
        with patch.object(data, '_load', return_value=(Path('/owned'), {}, {'phase': 'prepared'})), patch.object(data.ax, 'accessibility_available', return_value=False), patch.object(data.signer, 'snapshot') as snapshot, patch.object(data.signer, 'run_tool') as command, patch.object(data.secrets, 'token_hex') as password, self.assertRaises(data.guard.Refused):
            data.begin(Path('/owned'))
        snapshot.assert_not_called()
        command.assert_not_called()
        password.assert_not_called()

    def test_partial_default_switch_restores_before_owned_cleanup_and_never_uses_login_password(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            output = Path(directory).resolve()
            (output / 'private').mkdir()
            (output / 'receipts').mkdir()
            nonce = 'a' * 32
            (output / '.native-update-owned').write_text(nonce)
            original = {'default': '/original/login.keychain-db', 'login': '/original/login.keychain-db', 'search': ['/original/login.keychain-db', '/system/keychain']}
            current = json.loads(json.dumps(original))
            paths = data.locations(output, nonce)
            calls = []
            failed = False
            def command(arguments, **kwargs):
                nonlocal failed
                arguments = [str(value) for value in arguments]
                calls.append(arguments)
                if arguments[:2] == ['/bin/ps', '-axo']:
                    return Mock(returncode=0, stdout=b'')
                operation = arguments[1]
                if operation == 'create-keychain':
                    paths['keychain'].write_bytes(b'synthetic keychain database')
                elif operation == 'list-keychains':
                    current['search'] = arguments[arguments.index('-s') + 1:]
                elif operation == 'default-keychain':
                    current['default'] = arguments[-1]
                    if arguments[-1] == str(paths['keychain']) and not failed:
                        failed = True
                        raise data.guard.Refused('synthetic_partial_default_failure')
                elif operation == 'delete-keychain':
                    paths['keychain'].unlink()
                return Mock(returncode=0, stdout=b'')
            env = {'GITHUB_WORKFLOW': 'xclient-native-qa', 'GITHUB_EVENT_NAME': 'workflow_dispatch', 'GITHUB_JOB': 'desktop-update'}
            with patch.dict(os.environ, env), patch.object(data.guard, 'ci_identity', return_value='job'), patch.object(data.guard, 'scoped', side_effect=lambda value: Path(value).resolve()), patch.object(data.ax, 'accessibility_available', return_value=True), patch.object(data.signer, 'snapshot', side_effect=lambda: json.loads(json.dumps(current))), patch.object(data.signer, 'run_tool', side_effect=command):
                data.prepare(output, 'job', nonce)
                with self.assertRaisesRegex(data.guard.Refused, 'synthetic_partial_default_failure'):
                    data.begin(output)
                self.assertEqual(current, original)
                report = data.cleanup(output)
                self.assertTrue(report['success'])
                self.assertEqual(current, original)
                self.assertFalse(paths['password'].exists() or paths['keychain'].exists())
                self.assertTrue(data.cleanup(output)['success'])
            self.assertFalse(any('login-keychain' in value for value in calls))
            password_commands = [value for value in calls if '-p' in value]
            self.assertTrue(password_commands)
            self.assertTrue(all(value[-1] == str(paths['keychain']) for value in password_commands))
            restore = next(index for index, value in enumerate(calls) if value[1] == 'default-keychain' and value[-1] == original['default'])
            deletion = next(index for index, value in enumerate(calls) if value[1] == 'delete-keychain')
            self.assertLess(restore, deletion)

    def test_restore_rejects_external_changes_without_any_preference_write(self):
        original = {'default': '/login', 'login': '/login', 'search': ['/login']}
        locations = data.locations(Path('/owned'), 'a' * 32)
        with patch.object(data.signer, 'snapshot', return_value={**original, 'default': '/other'}), patch.object(data.signer, 'run_tool') as command, self.assertRaises(data.guard.Refused):
            data.restore_original(locations, {'original': original, 'create_attempted': True})
        command.assert_not_called()

    def test_synthetic_item_metadata_is_queried_only_in_the_owned_active_keychain(self):
        paths = data.locations(Path('/owned'), 'a' * 32)
        text = 'keychain: "' + str(paths['keychain']) + '"\n    "svce"<blob>="' + paths['service'] + '"\n'
        with patch.object(data, 'active_state', return_value=True), patch.object(data.signer, 'run_tool', return_value=Mock(returncode=0, stdout=text.encode())) as command:
            self.assertTrue(data.verify_synthetic_item(paths, {'original': {}}))
        self.assertEqual(command.call_args.args[0], ['/usr/bin/security', 'find-generic-password', '-s', paths['service'], paths['keychain']])
        self.assertNotIn('-w', command.call_args.args[0])
        self.assertNotIn('-g', command.call_args.args[0])
        for changed in (text.replace(paths['service'], 'other'), text.replace(str(paths['keychain']), '/login'), text + '    "svce"<blob>="duplicate"\n'):
            with patch.object(data, 'active_state', return_value=True), patch.object(data.signer, 'run_tool', return_value=Mock(returncode=0, stdout=changed.encode())), self.assertRaises(data.guard.Refused):
                data.verify_synthetic_item(paths, {'original': {}})

    def test_live_example_process_prevents_preference_changes_and_keychain_deletion(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            paths = data.locations(output, 'a' * 32)
            state = {'create_attempted': True}
            with patch.object(data, '_load', return_value=(output, paths, state)), patch.object(data, 'save'), patch.object(data, 'restore_original') as restore, patch.object(data.signer, 'run_tool', return_value=Mock(stdout=b'/owned/ExampleClient\n')) as command, self.assertRaises(data.guard.Refused):
                data.cleanup(output)
            restore.assert_not_called()
            self.assertEqual(command.call_count, 1)
            self.assertNotIn('delete-keychain', command.call_args.args[0])
            report = json.loads((output / 'receipts/confirmation-cleanup.json').read_text())
            self.assertFalse(report['success'])
            self.assertEqual(report['error_classes'], ['confirmation_app_still_running'])

    def test_item_placement_is_proved_before_arming_the_update_without_reading_a_password(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            paths = data.locations(output, 'a' * 32)
            state = {'phase': 'active', 'item_metadata_verified': False}
            with patch.object(data, '_load', return_value=(output, paths, state)), patch.object(data, 'verify_synthetic_item', return_value=True) as verify, patch.object(data, 'save') as save, patch.object(data, 'password') as password:
                self.assertTrue(data.prove_item_placement(output)['owned_item_metadata_verified'])
            verify.assert_called_once_with(paths, state)
            self.assertTrue(save.call_args.args[1]['item_metadata_verified'])
            password.assert_not_called()
            receipt = json.loads((output / 'receipts/confirmation-item.json').read_text())
            self.assertTrue(receipt['metadata_only'])
            self.assertNotIn(paths['service'], json.dumps(receipt))


if __name__ == '__main__':
    unittest.main()
