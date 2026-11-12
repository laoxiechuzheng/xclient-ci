import importlib.util
import json
from pathlib import Path, PurePosixPath
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('macos_keychain_confirmation', Path(__file__).with_name('macos_keychain_confirmation.py'))
confirmation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(confirmation)


class PreflightTest(unittest.TestCase):
    def test_a_completed_confirmation_never_repeats_agent_or_password_actions(self):
        with patch.object(confirmation.data_keychain, '_load', return_value=(Path('/owned'), {}, {'confirmation_completed': True})), patch.object(confirmation, 'agent_candidates') as agents, patch.object(confirmation.data_keychain, 'password') as password:
            self.assertTrue(confirmation.maybe_confirm(Path('/owned'), {}, 'a' * 64, lambda: True))
        agents.assert_not_called()
        password.assert_not_called()

    def test_a_changed_app_birth_or_disk_image_is_refused_before_any_password_action(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            output = Path(directory).resolve()
            executable = output / 'private/installed/ExampleClient'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'owned synthetic app')
            owner = {'pid': 7, 'started': 'first', 'executable': str(executable)}
            paths, state = {'keychain': output / 'private/data.keychain-db'}, {'nonce': 'a' * 32}
            agent = {'owner': {'pid': 8, 'started': 'agent', 'executable': '/System/Library/SecurityAgent'}, 'executable_sha256': 'b' * 64}
            for observed, expected in [({**owner, 'started': 'changed'}, confirmation.guard.digest(executable)), (owner, 'f' * 64)]:
                with patch.object(confirmation.data_keychain, 'full_job', return_value='job'), patch.object(confirmation, 'accessibility_available', return_value=True), patch.object(confirmation, 'pending_read', return_value={}), patch.object(confirmation.data_keychain, '_load', return_value=(output, paths, state)), patch.object(confirmation.data_keychain, 'active_state', return_value=True), patch.object(confirmation.guard, 'process_identity', return_value=observed), patch.object(confirmation.data_keychain, 'password') as password, self.assertRaises(confirmation.guard.Refused):
                    confirmation.verify_action_owner(output, paths, state, owner, expected, agent)
                password.assert_not_called()

    def test_a_non_apple_security_agent_is_rejected_before_ax_or_secret_access(self):
        class SystemPath(PurePosixPath):
            def resolve(self):
                return self
        path = '/System/Library/Frameworks/Security.framework/Versions/A/MachServices/SecurityAgent.bundle/Contents/MacOS/SecurityAgent'
        owner = {'pid': 8, 'started': 'agent', 'executable': path}
        with patch.object(confirmation, 'Path', SystemPath), patch.object(confirmation.signer, 'run_tool', side_effect=[Mock(stdout=('8 ' + path).encode()), Mock(returncode=1)]) as command, patch.object(confirmation.guard, 'process_identity', return_value=owner), patch.object(confirmation.ax, 'Session') as session, patch.object(confirmation.guard, 'digest') as digest, self.assertRaisesRegex(confirmation.guard.Refused, 'apple_security_agent_required'):
            confirmation.agent_candidates()
        self.assertEqual(command.call_args.args[0][:5], ['/usr/bin/codesign', '--verify', '--strict', '-R', '=anchor apple'])
        session.assert_not_called()
        digest.assert_not_called()

    def test_confirmation_is_bound_to_the_live_original_cross_read(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            output = Path(directory)
            receipts = output / 'receipts'
            receipts.mkdir()
            value = {'stage': '2', 'id': 1, 'operation': 'crossRead', 'event': 'begin', 'outcome': 'pending', 'started_ms': 10000, 'elapsed_ms': 0}
            (receipts / 'store-2-01-begin.json').write_text(json.dumps(value))
            self.assertEqual(confirmation.pending_read(output, now_ms=15000), value)
            self.assertIsNone(confirmation.pending_read(output, now_ms=14999))
            self.assertIsNone(confirmation.pending_read(output, now_ms=24000))
            (receipts / 'store-2-01-end.json').write_text('{}')
            self.assertIsNone(confirmation.pending_read(output, now_ms=16000))

    def test_without_pending_cross_read_no_agent_or_password_action_is_attempted(self):
        state = {'phase': 'active', 'confirmation_attempted': False, 'confirmation_completed': False, 'item_metadata_verified': True}
        with patch.object(confirmation.data_keychain, '_load', return_value=(Path('/owned'), {}, state)), patch.object(confirmation, 'pending_read', return_value=None), patch.object(confirmation, 'agent_candidates') as agents, patch.object(confirmation.data_keychain, 'password') as password:
            self.assertFalse(confirmation.maybe_confirm(Path('/owned'), {}, 'a' * 64, lambda: True))
        agents.assert_not_called()
        password.assert_not_called()

    def test_local_host_is_refused_before_query_or_directory_mutation(self):
        with patch.dict(confirmation.guard.os.environ, {'GITHUB_ACTIONS': 'false'}), patch.object(confirmation, 'accessibility_available') as query, patch.object(Path, 'mkdir') as mkdir, self.assertRaises(confirmation.guard.Refused):
            confirmation.preflight(confirmation.guard.ROOT / 'out/unowned-probe')
        query.assert_not_called()
        mkdir.assert_not_called()

    def test_only_the_non_prompting_accessibility_query_is_used(self):
        library = Mock()
        library.AXIsProcessTrusted.return_value = False
        with patch.object(confirmation.ax.ctypes, 'CDLL', return_value=library):
            self.assertFalse(confirmation.accessibility_available())
        library.AXIsProcessTrusted.assert_called_once_with()
        self.assertEqual(library.AXIsProcessTrusted.argtypes, [])
        self.assertEqual(library.method_calls[0][0], 'AXIsProcessTrusted')

    def test_no_permission_or_query_error_never_creates_a_credential_or_claims_success(self):
        for result in (False, OSError('SENSITIVE_DETAIL')):
            with self.subTest(kind=type(result).__name__), tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
                output = Path(directory) / 'receipt'
                mock = {'side_effect': result} if isinstance(result, Exception) else {'return_value': result}
                with patch.object(confirmation.guard, 'ci_identity', return_value='job'), patch.object(confirmation.guard, 'scoped', return_value=output), patch.object(confirmation, 'accessibility_available', **mock):
                    report = confirmation.preflight(output)
                self.assertFalse(report['preflight_success'])
                self.assertFalse(report['permission_requested'] or report['credentials_created'] or report['keychain_changed'])
                self.assertEqual(report['confirmation_actions'], 0)
                self.assertEqual({item.name for item in output.iterdir()}, {'preflight.json'})
                self.assertNotIn('SENSITIVE', json.dumps(report))


if __name__ == '__main__':
    unittest.main()
