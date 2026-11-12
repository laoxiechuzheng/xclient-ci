import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('macos_signing_fixture', Path(__file__).with_name('macos_signing_fixture.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class SigningFixtureTest(unittest.TestCase):
    def test_signing_temporarily_lists_only_its_owned_keychain_and_restores_on_error(self):
        with tempfile.TemporaryDirectory(dir=fixture.guard.ROOT / '.dart_tool') as directory:
            locations = fixture.paths(Path(directory).resolve())
            locations['preflight'].mkdir(parents=True)
            target = locations['preflight'] / 'version1'
            target.write_bytes(b'synthetic executable')
            original = {'default': '/login', 'login': '/login', 'search': ['/login', '/system']}
            state = {'certificate_sha1': 'a' * 40, 'original': original}
            calls = []
            def tool(arguments, **kwargs):
                calls.append(arguments)
                if arguments[0] == '/usr/bin/codesign':
                    raise fixture.guard.Refused('synthetic_sign_failure')
                return Mock(returncode=0)
            with patch.object(fixture, 'snapshot', return_value=original), patch.object(fixture, 'run_tool', side_effect=tool), patch.object(fixture, '_restore') as restore, self.assertRaises(fixture.guard.Refused):
                fixture._sign(locations, state, target, fixture.PREFLIGHT_ID)
            self.assertEqual(calls[0], ['/usr/bin/security', 'list-keychains', '-d', 'user', '-s', str(locations['keychain']), '/login', '/system'])
            restore.assert_called_once_with(locations, state)
            self.assertFalse(any('default-keychain' in command or 'login-keychain' in command for command in calls))

    def test_failed_signing_receipt_has_only_known_tool_operation_and_reason(self):
        result = Mock(returncode=1, stdout=b'', stderr=b'SENSITIVE_PATH CSSMERR_TP_NOT_TRUSTED SENSITIVE_PASSWORD')
        with patch.object(fixture.subprocess, 'run', return_value=result), self.assertRaises(fixture.SigningCommandFailure) as raised:
            fixture.run_tool(['/usr/bin/codesign', '--force', '--sign', 'SENSITIVE_IDENTITY', '/SENSITIVE_PATH'])
        self.assertEqual({key: value for key, value in raised.exception.diagnostic.items() if key != 'message_words'}, {'program': 'codesign', 'operation': '--sign', 'exit_code': 1, 'reason': 'CSSMERR_TP_NOT_TRUSTED'})
        self.assertNotIn('SENSITIVE', json.dumps(raised.exception.diagnostic))

    def test_unknown_signing_message_exports_only_the_fixed_vocabulary(self):
        result = Mock(returncode=1, stdout=b'', stderr=b'/SENSITIVE_PATH a-secret.example.invalid token012345: this identity cannot be used for signing code')
        failure = fixture.SigningCommandFailure(['/usr/bin/codesign', '--sign', 'SENSITIVE_IDENTITY'], result)
        words = failure.diagnostic['message_words']
        self.assertEqual(words[-8:], ['this', 'identity', 'cannot', 'be', 'used', 'for', 'signing', 'code'])
        self.assertNotIn('sensitive', words)
        self.assertNotIn('example', words)
        self.assertNotIn('token', words)

    def test_login_query_uses_the_implemented_undomained_security_api(self):
        responses = [Mock(returncode=0, stdout=b'"/login"\n') for _ in range(3)]
        with patch.object(fixture, 'run_tool', side_effect=responses) as run:
            self.assertEqual(fixture.snapshot(), {'default': '/login', 'login': '/login', 'search': ['/login']})
        self.assertEqual(run.call_args_list[0].args[0], ['/usr/bin/security', 'default-keychain', '-d', 'user'])
        self.assertEqual(run.call_args_list[1].args[0], ['/usr/bin/security', 'login-keychain'])
        self.assertEqual(run.call_args_list[2].args[0], ['/usr/bin/security', 'list-keychains', '-d', 'user'])

    def test_snapshot_failure_reports_only_fixed_operation_and_numeric_exit(self):
        default = Mock(returncode=0, stdout=b'"/login"\n')
        login = Mock(returncode=50, stdout=b'SENSITIVE_PATH', stderr=b'SENSITIVE_PASSWORD')
        with patch.object(fixture, 'run_tool', side_effect=[default, login]), self.assertRaisesRegex(fixture.guard.Refused, '^signing_snapshot_login-keychain_exit_50$'):
            fixture.snapshot()

    def test_preflight_failure_restores_original_state_and_stays_red(self):
        with tempfile.TemporaryDirectory(dir=fixture.guard.ROOT / '.dart_tool') as directory:
            output = Path(directory).resolve()
            (output / 'receipts').mkdir()
            original_file = output / 'synthetic-original.keychain-db'
            original_file.write_text('synthetic keychain placeholder')
            original = {'default': str(original_file), 'login': str(original_file), 'search': [str(original_file)]}
            state = {'phase': 'prepared', 'original': None, 'keychain_create_attempted': False}
            locations = fixture.paths(output)
            with patch.object(fixture, '_load', return_value=(output, locations, state)), patch.object(fixture, 'snapshot', return_value=original), patch.object(fixture, '_write_state'), patch.object(fixture, '_generate', side_effect=fixture.guard.Refused('synthetic_generation_failure')), patch.object(fixture, 'run_tool') as run, self.assertRaises(fixture.guard.Refused):
                fixture.preflight(output)
            run.assert_not_called()
            report = json.loads((output / 'receipts/signing-preflight.json').read_text())
            self.assertFalse(report['success'])
            self.assertTrue(report['original_state_restored'])
            self.assertEqual(state['phase'], 'failed')
            self.assertEqual(report['checkpoint'], 'generateIdentity')

    def test_cleanup_removes_only_owned_material_and_is_idempotent(self):
        with tempfile.TemporaryDirectory(dir=fixture.guard.ROOT / '.dart_tool') as directory:
            output = Path(directory).resolve()
            (output / 'receipts').mkdir()
            locations = fixture.paths(output)
            locations['directory'].mkdir(parents=True)
            locations['marker'].write_text('synthetic-owned-marker')
            locations['key'].write_text('SENSITIVE_SYNTHETIC_KEY')
            locations['password'].write_text('SENSITIVE_SYNTHETIC_PASSWORD')
            outside = output / 'unrelated.txt'
            outside.write_text('must survive')
            state = {'phase': 'prepared', 'original': None, 'keychain_create_attempted': False}
            with patch.object(fixture, '_load', return_value=(output, locations, state)), patch.object(fixture, 'run_tool') as run:
                first = fixture.cleanup(output)
                second = fixture.cleanup(output)
            run.assert_not_called()
            self.assertTrue(first['success'] and second['success'])
            self.assertEqual(outside.read_text(), 'must survive')
            self.assertFalse(locations['key'].exists() or locations['password'].exists())
            self.assertNotIn('SENSITIVE', json.dumps(first))
            self.assertEqual({item.name for item in locations['directory'].iterdir()}, {'state.json', '.owned'})

    def test_external_keychain_state_change_is_never_overwritten(self):
        original = {'default': '/login', 'login': '/login', 'search': ['/login']}
        with patch.object(fixture, 'snapshot', return_value={**original, 'search': ['/unknown', '/login']}), patch.object(fixture, 'run_tool') as run, self.assertRaises(fixture.guard.Refused):
            fixture._restore(fixture.paths(Path('/owned/output')), {'original': original, 'keychain_create_attempted': True})
        run.assert_not_called()

    def test_only_explicit_mac_fixture_mode_is_allowed(self):
        fixture.validate_mode('macos', 'adhoc')
        fixture.validate_mode('windows', 'adhoc')
        fixture.validate_mode('macos', 'ephemeral-self-signed')
        for platform, mode in [('windows', 'ephemeral-self-signed'), ('macos', 'SENSITIVE_MODE'), ('linux', 'adhoc')]:
            with self.assertRaises(fixture.guard.Refused):
                fixture.validate_mode(platform, mode)

    def test_mac_lifecycle_refuses_local_host_before_any_command_or_file_mutation(self):
        output = fixture.guard.ROOT / 'out/unused-signing-fixture'
        with patch.dict(fixture.os.environ, {'GITHUB_ACTIONS': 'false'}), patch.object(fixture, 'run_tool') as run, patch.object(fixture.Path, 'mkdir') as mkdir:
            for action in [lambda: fixture.prepare(output, 'job', 'a' * 32), lambda: fixture.preflight(output), lambda: fixture.cleanup(output)]:
                with self.assertRaises(fixture.guard.Refused):
                    action()
        run.assert_not_called()
        mkdir.assert_not_called()

    def test_snapshot_parser_preserves_exact_search_order_and_requires_one_default(self):
        snapshot = fixture.parse_snapshot('"/owned/login.keychain-db"\n', '"/owned/login.keychain-db"\n', '"/owned/login.keychain-db"\n"/Library/Keychains/System.keychain"\n')
        self.assertEqual(snapshot['search'], ['/owned/login.keychain-db', '/Library/Keychains/System.keychain'])
        for default in ('', '"/one" " /two"', 'relative.keychain'):
            with self.assertRaises(fixture.guard.Refused):
                fixture.parse_snapshot(default, '"/owned/login.keychain-db"', '"/owned/login.keychain-db"')

    def test_restore_accepts_only_its_own_added_keychain(self):
        original = {'default': '/login', 'login': '/login', 'search': ['/login', '/system']}
        owned = ('/private/qa.keychain-db', '/private/qa.keychain')
        self.assertTrue(fixture.restorable_snapshot(original, original, owned))
        self.assertTrue(fixture.restorable_snapshot(original, {**original, 'search': [owned[0], '/login', '/system']}, owned))
        for changed in [{**original, 'default': owned[0]}, {**original, 'login': '/other'}, {**original, 'search': ['/login']}, {**original, 'search': ['/system', '/login']}, {**original, 'search': ['/login', '/unknown', '/system']}]:
            self.assertFalse(fixture.restorable_snapshot(original, changed, owned))

    def test_every_preflight_control_is_mandatory(self):
        report = {key: True for key in fixture.PREFLIGHT_CHECKS}
        fixture.require_preflight(report)
        for key in fixture.PREFLIGHT_CHECKS:
            with self.subTest(key=key), self.assertRaises(fixture.guard.Refused):
                fixture.require_preflight({**report, key: False})
        with self.assertRaises(fixture.guard.Refused):
            fixture.require_preflight({})

    def test_failed_secret_command_never_exports_argv_or_stderr(self):
        for result in [Mock(returncode=1, stdout=b'SENSITIVE_OUTPUT', stderr=b'SENSITIVE_OUTPUT'), subprocess.CalledProcessError(1, ['/usr/bin/security', '-P', 'SENSITIVE_PASSWORD'])]:
            with self.subTest(kind=type(result).__name__):
                mocked = {'side_effect': result} if isinstance(result, Exception) else {'return_value': result}
                with patch.object(fixture.subprocess, 'run', **mocked) as run, self.assertRaises(fixture.guard.Refused) as raised:
                    fixture.run_tool(['/usr/bin/security', 'import', '-P', 'SENSITIVE_PASSWORD'])
                self.assertNotIn('SENSITIVE', str(raised.exception))
                self.assertTrue(run.call_args.kwargs['capture_output'])
                self.assertNotIn('shell', run.call_args.kwargs)

    def test_config_has_only_one_code_signing_section_and_no_host_extension_merge(self):
        config = fixture.certificate_config('a' * 32)
        self.assertEqual(config.count('extendedKeyUsage='), 1)
        self.assertIn('extendedKeyUsage=critical,codeSigning', config)
        self.assertIn('keyUsage=critical,digitalSignature', config)
        self.assertNotIn('serverAuth', config)
        self.assertNotIn('x509_extensions', config)
        self.assertNotIn('req_extensions', config)


if __name__ == '__main__':
    unittest.main()
