import importlib.util
from pathlib import Path
import ssl
import sys
import tempfile
import unittest
from unittest.mock import patch
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('native_update_smoke', Path(__file__).with_name('native_update_smoke.py'))
qa = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qa)
import native_tls_probe as tls_probe


class ContractTest(unittest.TestCase):
    def test_a_child_that_disappears_during_identity_query_is_not_adopted_or_signalled(self):
        parent = {'pid': 7, 'executable': '/owned/app', 'started': 'first'}
        child = {'pid': 9, 'executable': '/owned/live-child', 'started': 'second'}
        rows = [{'pid': 8, 'parent': 7, 'executable': '/bin/sleep'}, {'pid': 9, 'parent': 7, 'executable': child['executable']}]
        seen = []
        def present(pid):
            if pid == 8:
                seen.append(pid)
                return seen.count(pid) == 1
            return True
        def identity(pid):
            if pid == 8:
                raise qa.subprocess.CalledProcessError(1, ['PRIVATE_COMMAND'])
            return parent if pid == 7 else child
        owned = [parent]
        with patch.object(qa, 'alive', side_effect=present), patch.object(qa.guard, 'process_identity', side_effect=identity), patch.object(qa.os, 'kill') as signal:
            qa.observe_children(owned, rows)
        self.assertEqual(owned, [parent, child])
        signal.assert_not_called()

    def test_late_v2_adoption_requires_actual_installed_hash_path_and_a_distinct_pid(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            executable = (Path(directory) / 'ExampleClient').resolve()
            executable.write_bytes(b'synthetic installed v2')
            expected = qa.guard.digest(executable)
            hello = {'pid': 9, 'executable_sha256': expected}
            owner = {'pid': 9, 'executable': str(executable), 'started': 'second'}
            with patch.object(qa.guard, 'process_identity', return_value=owner):
                self.assertEqual(qa.reported_v2_owner(hello, 7, executable, expected), owner)
                for changed in ({**hello, 'pid': 7}, {**hello, 'executable_sha256': 'f' * 64}):
                    with self.assertRaises(qa.guard.Refused):
                        qa.reported_v2_owner(changed, 7, executable, expected)
            with patch.object(qa.guard, 'process_identity', return_value={**owner, 'executable': '/other/ExampleClient'}), self.assertRaises(qa.guard.Refused):
                qa.reported_v2_owner(hello, 7, executable, expected)
            executable.write_bytes(b'changed')
            with patch.object(qa.guard, 'process_identity') as query, self.assertRaises(qa.guard.Refused):
                qa.reported_v2_owner(hello, 7, executable, expected)
            query.assert_not_called()

    def test_confirmation_requires_a_hashed_native_capture_of_the_owned_cross_read(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as directory:
            output = Path(directory)
            receipts = output / 'receipts'
            receipts.mkdir()
            self.assertFalse(qa.confirmation_capture_available(output))
            image = receipts / 'native-store-pending-1.png'
            image.write_bytes(self.png_fixture())
            receipt = receipts / 'native-store-pending-1.json'
            metadata = {'captured': True, 'stage': '2', 'id': 1, 'operation': 'crossRead', 'png_sha256': qa.guard.digest(image)}
            qa.guard.write_new(receipt, metadata)
            self.assertTrue(qa.confirmation_capture_available(output))
            for changed in ({**metadata, 'operation': 'replacementRead'}, {**metadata, 'captured': False}, {**metadata, 'png_sha256': 'f' * 64}, {**metadata, 'stage': '1'}):
                receipt.write_text(qa.json.dumps(changed))
                self.assertFalse(qa.confirmation_capture_available(output))
            receipt.write_text(qa.json.dumps(metadata))
            image.write_bytes(b'partial PNG')
            self.assertFalse(qa.confirmation_capture_available(output))

    def test_designated_requirement_receipt_contains_only_hash_and_fixed_form(self):
        value = 'Executable=/PRIVATE_PATH\ndesignated => cdhash H"' + 'a' * 40 + '"\n'
        requirement, source = qa.designated_requirement(value)
        self.assertEqual(requirement, 'cdhash H"' + 'a' * 40 + '"')
        self.assertEqual(source, 'explicit')
        diagnostic = qa.requirement_diagnostic(requirement)
        self.assertEqual(diagnostic['form'], 'cdhashOnly')
        self.assertEqual(len(diagnostic['sha256']), 64)
        self.assertNotIn('PRIVATE', str(diagnostic))
        self.assertNotIn('cdhash H', str(diagnostic))
        self.assertEqual(qa.designated_requirement('SENSITIVE_OTHER_OUTPUT'), (None, 'unknown'))
        self.assertEqual(qa.designated_requirement(value + value), (None, 'unknown'))
        self.assertEqual(qa.requirement_diagnostic('identifier "SENSITIVE_IDENTIFIER"')['form'], 'other')

    def test_only_the_single_official_implicit_designated_prefix_is_accepted(self):
        expression = 'cdhash H"' + 'a' * 40 + '"'
        plain = 'designated => ' + expression
        implicit = '# ' + plain
        self.assertEqual(qa.designated_requirement(implicit), (expression, 'implicit'))
        self.assertEqual(qa.designated_requirement(plain), (expression, 'explicit'))
        for value in ('## ' + plain, '# note ' + plain, implicit + '\n' + plain, implicit + '\n' + implicit, plain + '\n## ' + plain):
            with self.subTest(value=value[:18]):
                self.assertEqual(qa.designated_requirement(value), (None, 'unknown'))

    def test_requirement_verification_uses_an_explicit_verified_literal_argument(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            file = Path(directory) / 'private-requirement.txt'
            requirement = 'cdhash H"' + 'a' * 40 + '"'
            file.write_text(requirement, encoding='utf-8')
            with patch.object(qa.subprocess, 'run', return_value=Mock(returncode=0)) as run:
                self.assertTrue(qa.requirement_matches(Path('/owned/app'), file, expected_sha256=qa.guard.digest(file)))
        self.assertEqual(run.call_args.args[0], ['/usr/bin/codesign', '--verify', '--strict', '-R', '=' + requirement, str(Path('/owned/app'))])
        self.assertTrue(run.call_args.kwargs['capture_output'])
        self.assertNotIn('shell', run.call_args.kwargs)

    def test_raw_requirement_stays_private_and_changed_requirement_cannot_be_cross_tested(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            private = Path(directory)
            raw = 'identifier "SENSITIVE_SYNTHETIC_IDENTIFIER"'
            displayed = Mock(returncode=0, stdout=('designated => ' + raw + '\n').encode(), stderr=b'')
            with patch.object(qa.subprocess, 'run', side_effect=[displayed, Mock(returncode=0)]):
                signing = qa.stage_requirement(Path('/owned/app'), private, '1')
            self.assertEqual((private / 'v1-designated.req').read_text(), raw)
            self.assertTrue(signing['self_match'])
            self.assertNotIn('SENSITIVE', str(signing))
            (private / 'v1-designated.req').write_text('changed')
            with patch.object(qa, 'requirement_matches') as match:
                result = qa.compare_requirements(private, Path('/owned/app'), signing, signing)
            self.assertIsNone(result['v2_satisfies_v1'])
            self.assertEqual(result['reason'], 'diagnosticFailed')
            match.assert_not_called()

    def test_pending_store_capture_accepts_only_owned_fixed_schema_and_pending_age(self):
        begin = {'stage': '2', 'id': 1, 'operation': 'crossRead', 'event': 'begin', 'outcome': 'pending', 'started_ms': 1000, 'elapsed_ms': 0}
        self.assertTrue(qa.pending_store_begin(begin, 1, 6000))
        for changed in [{**begin, 'id': True}, {**begin, 'stage': '1'}, {**begin, 'operation': 'SENSITIVE'}, {**begin, 'operation': {}}, {**begin, 'extra': 'SENSITIVE'}, {**begin, 'started_ms': 7000}]:
            self.assertFalse(qa.pending_store_begin(changed, 1, 6000))
        self.assertFalse(qa.pending_store_begin(begin, 1, 5999))

    def test_pending_capture_is_bounded_and_ignores_completed_operations(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            begin = {'stage': '2', 'id': 1, 'operation': 'crossRead', 'event': 'begin', 'outcome': 'pending', 'started_ms': 1000, 'elapsed_ms': 0}
            qa.guard.write_new(output / 'receipts/store-2-01-begin.json', begin)
            capture = {'captured': False, 'reason': 'permissionUnavailable'}
            state = {'attempts': 0, 'last_ms': 0}
            with patch.object(qa, 'native_store_screenshot', return_value=capture) as take:
                for now in (6000, 6001, 11000, 16000):
                    qa.capture_pending_store(output, {}, state, now_ms=now)
            self.assertEqual(take.call_count, 2)
            self.assertEqual(state['attempts'], 2)
            qa.guard.write_new(output / 'receipts/store-2-01-end.json', {'outcome': 'timeout'})
            with patch.object(qa, 'native_store_screenshot') as take:
                qa.capture_pending_store(output, {}, {'attempts': 0, 'last_ms': 0}, now_ms=20000)
            take.assert_not_called()

    def test_native_capture_refuses_local_host_before_loading_framework_or_creating_file(self):
        with patch.dict(qa.os.environ, {'GITHUB_ACTIONS': 'false'}), patch.object(qa.ctypes, 'CDLL') as load, patch.object(qa.Path, 'mkdir') as mkdir, self.assertRaises(qa.guard.Refused):
            qa.native_store_screenshot(qa.ROOT / 'out/unused', {}, 1)
        load.assert_not_called()
        mkdir.assert_not_called()

    def test_missing_capture_permission_never_requests_permission_or_takes_a_picture(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        graphics = Mock()
        graphics.CGPreflightScreenCaptureAccess.return_value = False
        with patch.object(qa.guard, 'ci_identity'), patch.object(qa.guard, 'scoped', return_value=qa.ROOT / 'out/unused'), patch.object(qa.guard, 'process_identity', return_value=owner), patch.object(qa.ctypes, 'CDLL', return_value=graphics), patch.object(qa.subprocess, 'run') as run, patch.object(qa.Path, 'mkdir') as mkdir:
            report = qa.native_store_screenshot(qa.ROOT / 'out/unused', owner, 1)
        self.assertEqual(report, {'captured': False, 'reason': 'permissionUnavailable'})
        run.assert_not_called()
        mkdir.assert_not_called()
        graphics.CGRequestScreenCaptureAccess.assert_not_called()

    @staticmethod
    def png_fixture():
        def chunk(name, value):
            body = name + value
            return len(value).to_bytes(4, 'big') + body + qa.zlib.crc32(body).to_bytes(4, 'big')
        header = b'\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00'
        return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', header) + chunk(b'IDAT', qa.zlib.compress(b'\0\0\0\0')) + chunk(b'IEND', b'')

    def test_native_capture_publishes_only_valid_png_with_same_owned_app(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        graphics = Mock()
        graphics.CGPreflightScreenCaptureAccess.return_value = True
        for changed in (False, True):
            with self.subTest(changed_owner=changed), tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
                output = Path(directory)
                (output / 'private').mkdir()
                (output / 'receipts').mkdir()
                def capture(arguments, **kwargs):
                    self.assertEqual(arguments[:4], ['/usr/sbin/screencapture', '-x', '-t', 'png'])
                    Path(arguments[-1]).write_bytes(self.png_fixture())
                    return Mock(returncode=0)
                current = {**owner, 'started': 'reused'} if changed else owner
                with patch.object(qa.guard, 'ci_identity'), patch.object(qa.guard, 'scoped', return_value=output), patch.object(qa.guard, 'process_identity', side_effect=[owner, current]), patch.object(qa.ctypes, 'CDLL', return_value=graphics), patch.object(qa.subprocess, 'run', side_effect=capture):
                    report = qa.native_store_screenshot(output, owner, 1)
                image = output / 'receipts/native-store-pending-1.png'
                self.assertEqual(report['captured'], not changed)
                self.assertEqual(image.exists(), not changed)
                if not changed:
                    self.assertEqual(report['png_sha256'], qa.guard.digest(image))

    def test_capture_png_rejects_partial_bad_header_and_outside_file_type(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            file = Path(directory) / 'image.png'
            valid = self.png_fixture()
            for data in (b'SENSITIVE_NOT_AN_IMAGE', valid[:-1], valid[:29] + b'\0\0\0\0' + valid[33:]):
                file.write_bytes(data)
                self.assertFalse(qa.valid_capture_png(file))
            self.assertFalse(qa.valid_capture_png(Path(directory)))

    def test_certificate_fixture_ignores_polluted_default_request_config(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            folder = Path(directory)
            private = folder / 'private'
            private.mkdir()
            polluted = folder / 'polluted.cnf'
            polluted.write_text('[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=v3_ca\nreq_extensions=v3_request\n[dn]\nCN=Polluted default\n[v3_ca]\nbasicConstraints=critical,CA:TRUE\nsubjectKeyIdentifier=hash\nextendedKeyUsage=clientAuth\n[v3_request]\nsubjectAltName=DNS:polluted.invalid\n', encoding='ascii')
            with patch.dict(qa.os.environ, {'OPENSSL_CONF': str(polluted)}):
                openssl = qa.generate_fixture_certificate(private)
            counts = {}
            for name in ('ca', 'server'):
                counts[name] = tls_probe.certificate_extension_diagnostic(ssl.PEM_cert_to_DER_cert((private / (name + '.crt')).read_text(encoding='ascii')))
                self.assertTrue(counts[name]['unique'], name + ' extension OIDs must be unique')
                self.assertEqual(counts[name]['unknown_oid_count'], 0)
                for kind in ('basicConstraints', 'subjectKeyIdentifier', 'keyUsage'):
                    self.assertEqual(counts[name]['known_oid_counts'][kind], 1)
            self.assertEqual(counts['ca']['known_oid_counts']['extendedKeyUsage'], 0, 'host request config must not constrain the fixture CA to client authentication')
            self.assertEqual(counts['ca']['extension_count'], 3)
            self.assertEqual(counts['server']['extension_count'], 6)
            csr = qa.command([openssl, 'req', '-in', private / 'server.csr', '-noout', '-text'])
            self.assertNotIn('polluted.invalid', csr, 'host request extensions must not enter the server CSR')
            qa.command([openssl, 'verify', '-CAfile', private / 'ca.crt', '-purpose', 'sslserver', '-verify_hostname', 'localhost', private / 'server.crt'])

    def test_fixture_uses_a_ca_signed_server_auth_leaf(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            private = Path(directory)
            openssl = qa.generate_fixture_certificate(private)
            leaf = qa.command([openssl, 'x509', '-in', private / 'server.crt', '-noout', '-text'])
            self.assertTrue('X509v3 Basic Constraints: critical' in leaf and 'CA:FALSE' in leaf, 'server leaf must declare critical CA:false')
            self.assertTrue('TLS Web Server Authentication' in leaf, 'server leaf requires serverAuth EKU')
            self.assertTrue('X509v3 Key Usage: critical' in leaf and 'Digital Signature, Key Encipherment' in leaf, 'server leaf requires TLS RSA key usages')
            self.assertTrue('DNS:localhost' in leaf and 'IP Address:127.0.0.1' in leaf, 'server leaf requires both local SANs')
            self.assertTrue('Public-Key: (2048 bit)' in leaf and 'sha256WithRSAEncryption' in leaf, 'server leaf requires RSA2048/SHA256')
            root = qa.command([openssl, 'x509', '-in', private / 'ca.crt', '-noout', '-text'])
            self.assertTrue('X509v3 Basic Constraints: critical' in root and 'CA:TRUE, pathlen:0' in root, 'test root requires a constrained CA declaration')
            self.assertTrue('Certificate Sign, CRL Sign' in root, 'test root requires signing key usages')
            self.assertTrue('Public-Key: (2048 bit)' in root and 'sha256WithRSAEncryption' in root, 'test root requires RSA2048/SHA256')
            for name in ('ca.crt', 'server.crt'):
                public = (private / name).read_bytes()
                self.assertEqual(public.count(b'-----BEGIN CERTIFICATE-----'), 1)
                self.assertNotIn(b'PRIVATE KEY', public)
            self.assertNotEqual(qa.guard.digest(private / 'ca.crt'), qa.guard.digest(private / 'server.crt'))
            self.assertEqual((private / 'server-chain.crt').read_bytes(), (private / 'server.crt').read_bytes() + (private / 'ca.crt').read_bytes())
            ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER).load_cert_chain(private / 'server-chain.crt', private / 'server.key')
            qa.command([openssl, 'verify', '-CAfile', private / 'ca.crt', '-purpose', 'sslserver', '-verify_hostname', 'localhost', private / 'server.crt'])
            qa.command([openssl, 'verify', '-CAfile', private / 'ca.crt', '-purpose', 'sslserver', '-verify_ip', '127.0.0.1', private / 'server.crt'])
            with self.assertRaises(qa.guard.Refused):
                qa.command([openssl, 'verify', '-CAfile', private / 'ca.crt', '-purpose', 'sslserver', '-verify_hostname', 'wrong.invalid', private / 'server.crt'])

    def test_v2_failure_cannot_pass_after_pid_disappears(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            receipts = Path(directory)
            for stage in ('1', '2'):
                qa.guard.write_new(receipts / ('exit-' + stage + '.json'), {'production_exit_requested': True})
            self.assertTrue(qa.verify_exit_observation(receipts, True, 0))
            qa.guard.write_new(receipts / 'failure.json', {'error_class': 'production_exit_failed'})
            with self.assertRaises(qa.guard.Refused):
                qa.verify_exit_observation(receipts, True, 0)

    def test_late_failure_is_rechecked_after_cleanup(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            receipts = Path(directory)
            qa.require_no_app_failure(receipts)
            qa.guard.write_new(receipts / 'failure.json', {'error_class': 'production_exit_returned'})
            with self.assertRaises(qa.guard.Refused):
                qa.require_no_app_failure(receipts)

    def test_revoked_request_or_nonzero_child_status_cannot_pass(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            receipts = Path(directory)
            qa.guard.write_new(receipts / 'exit-1.json', {'production_exit_requested': True})
            with self.assertRaises(qa.guard.Refused):
                qa.verify_exit_observation(receipts, True, 0)
            qa.guard.write_new(receipts / 'exit-2.json', {'production_exit_requested': True})
            with self.assertRaises(qa.guard.Refused):
                qa.verify_exit_observation(receipts, True, 1)

    def packaging_fixture(self, root):
        values = {'script_template': 'inno_setup.iss', 'app_id': qa.GUID, 'app_name': 'ExampleClient', 'publisher': 'XClient', 'publisher_name': 'XClient', 'publisher_url': 'https://www.example.com', 'display_name': 'Example 加速器', 'executable_name': 'ExampleClient.exe', 'output_base_file_name': 'ExampleClient.exe', 'install_dir_name': r'{autopf}\ExampleClient', 'privileges_required': 'admin', 'setup_icon_file': r'windows\runner\resources\app_icon.ico'}
        config = root / 'windows/packaging/exe/make_config.yaml'
        config.parent.mkdir(parents=True)
        config.write_text('\n'.join(key + ': ' + qa.json.dumps(value) for key, value in values.items()) + '\n', encoding='utf-8')
        template = (qa.ROOT / 'windows/packaging/exe/inno_setup.iss').read_text(encoding='utf-8').replace('FlClashCore', 'XClientexampleCore').replace('FlClashHelperService', qa.SERVICE).replace('[Setup]', '[Setup]\nAppMutex=XClient-' + qa.GUID, 1)
        (config.parent / 'inno_setup.iss').write_text(template, encoding='utf-8')
        (root / 'pubspec.yaml').write_text('name: fl_clash\nversion: 1.0.0-pre.1+10000401\n', encoding='utf-8')
        (root / 'distribute_options.yaml').write_text('app_name: "ExampleClient"\noutput: "dist/"\n', encoding='utf-8')
        runner = root / 'windows/runner/main.cpp'
        runner.parent.mkdir(parents=True)
        runner.write_text('constexpr wchar_t kXClientInstallerMutexName[] = L"XClient-' + qa.GUID + '";\n', encoding='utf-8')
        return config

    def test_successful_packer_can_delete_temporary_iss(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            root = Path(directory)
            self.packaging_fixture(root)
            frozen = qa.packaging_inputs(root, '1.0.0-pre.1', '10000401')
            generated = root / 'dist/generated.iss'
            generated.parent.mkdir()
            generated.write_text('temporary successful compiler input', encoding='utf-8')
            generated.unlink()
            qa.verify_packaging_inputs(root, frozen)

    def test_changed_frozen_packaging_source_is_rejected(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            root = Path(directory)
            config = self.packaging_fixture(root)
            frozen = qa.packaging_inputs(root, '1.0.0-pre.1', '10000401')
            (root / 'dist').mkdir()
            (root / 'dist/generated.iss').write_text('available but not authoritative', encoding='utf-8')
            config.write_text(config.read_text(encoding='utf-8') + '# changed after build preparation\n', encoding='utf-8')
            with self.assertRaisesRegex(qa.guard.Refused, 'packaging_input_changed'):
                qa.verify_packaging_inputs(root, frozen)

    def test_wrong_packaging_guid_dir_and_full_version_are_rejected(self):
        for source, old, new in [('windows/packaging/exe/make_config.yaml', qa.GUID, 'OTHER-GUID'), ('windows/packaging/exe/make_config.yaml', r'{autopf}\\ExampleClient', r'{autopf}\\OtherClient'), ('pubspec.yaml', '1.0.0-pre.1+10000401', '1.0.0-pre.1+100004010')]:
            with self.subTest(source=source, replacement=new), tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
                root = Path(directory)
                self.packaging_fixture(root)
                file = root / source
                text = file.read_text(encoding='utf-8')
                self.assertIn(old, text)
                file.write_text(text.replace(old, new), encoding='utf-8')
                with self.assertRaises(qa.guard.Refused):
                    qa.packaging_inputs(root, '1.0.0-pre.1', '10000401')

    def test_registry_requires_expected_guid_directory_and_exact_display_version(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            install = Path(directory).resolve()
            expected = {'app_id': qa.GUID, 'install_location': str(install), 'display_version': '1.0.0-pre.1+10000401'}
            qa.verify_windows_registration([expected], install, expected['display_version'])
            for rows in [[], [{**expected, 'app_id': 'OTHER'}], [{**expected, 'install_location': str(install.parent / 'other')}], [{**expected, 'display_version': '1.0.0-pre.1'}], [{**expected, 'display_version': '1.0.0-pre.1+100004010'}]]:
                with self.assertRaises(qa.guard.Refused):
                    qa.verify_windows_registration(rows, install, expected['display_version'])
    def test_only_fixed_upgrade_stages(self):
        self.assertEqual(qa.validate_stage('1'), ('1.0.0-pre.1', '10000401'))
        self.assertEqual(qa.validate_stage('2'), ('1.0.0-pre.2', '10000402'))
        for value in ['0', '3', '../1', '1.0.0', True, None]:
            with self.assertRaises(qa.guard.Refused):
                qa.validate_stage(value)

    def test_pair_requires_distinct_payload_and_ad_hoc_identity(self):
        one = {'payload_sha256': 'a', 'executable_sha256': 'b', 'cdhash': 'c'}
        two = {'payload_sha256': 'd', 'executable_sha256': 'e', 'cdhash': 'f'}
        self.assertTrue(qa.verify_pair(one, two))
        for field in ['payload_sha256', 'executable_sha256', 'cdhash']:
            with self.assertRaises(qa.guard.Refused):
                qa.verify_pair(one, {**two, field: one[field]})

    def test_cleanup_requires_full_original_owner(self):
        owner = {'pid': 23, 'executable': '/owned/ExampleClient', 'started': 'first'}
        self.assertTrue(qa.validate_owner(owner, owner))
        for other in [{**owner, 'pid': 24}, {**owner, 'started': 'second'}, {**owner, 'executable': '/other/ExampleClient'}, None]:
            with self.assertRaises(qa.guard.Refused):
                qa.validate_owner(owner, other)

    def test_identity_mismatch_diagnostics_preserve_strict_failure(self):
        owner = {'pid': 23, 'executable': '/owned/ExampleClient', 'started': 'Wed Nov  4 05:31:02 2026'}
        current = {**owner, 'executable': '/work/ExampleClient'}
        diagnostics = []
        with patch.object(qa, 'mac_process_snapshot', return_value={'state': 'zombie', 'parent_pid': 19, 'snapshot_start_matches': True, 'snapshot_executable_kind': 'basename'}), self.assertRaisesRegex(qa.guard.Refused, 'cleanup_owner_mismatch'):
            qa.validate_observed_owner(owner, current, 'observeOwner', diagnostics.append)
        self.assertEqual(diagnostics, [{'phase': 'observeOwner', 'pid': 23, 'pid_matches': True, 'executable_matches': False, 'started_matches': True, 'observed_executable_kind': 'sameBasename', 'state': 'zombie', 'parent_pid': 19, 'snapshot_start_matches': True, 'snapshot_executable_kind': 'basename'}])

    def test_mac_ps_diagnostic_reduces_command_to_owned_classes(self):
        owner = {'pid': 23, 'executable': '/owned/ExampleClient', 'started': 'Wed Nov  4 05:31:02 2026'}
        result = qa.parse_mac_process_snapshot(owner, '23 19 Z Wed Nov  4 05:31:02 2026 (ExampleClient)')
        self.assertEqual(result, {'state': 'zombie', 'parent_pid': 19, 'snapshot_start_matches': True, 'snapshot_executable_kind': 'defunctName'})
        self.assertNotIn('ExampleClient', str(result))
        changed = qa.parse_mac_process_snapshot(owner, '23 20 S Wed Nov  4 05:32:00 2026 /private/SENSITIVE_OTHER_PROCESS')
        self.assertEqual(changed['snapshot_executable_kind'], 'other')
        self.assertFalse(changed['snapshot_start_matches'])
        self.assertNotIn('SENSITIVE', str(changed))
        for raw in ('', '23 Z INVALID_PRIVATE_DATA', '24 19 Z Wed Nov  4 05:31:02 2026 /owned/ExampleClient'):
            self.assertEqual(qa.parse_mac_process_snapshot(owner, raw), {'state': 'unavailable'})

    def test_diagnostic_failure_never_accepts_reused_owner(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        with patch.object(qa, 'mac_process_snapshot', side_effect=RuntimeError('PRIVATE_DETAIL')), self.assertRaisesRegex(qa.guard.Refused, 'cleanup_owner_mismatch'):
            qa.validate_observed_owner(owner, {**owner, 'started': 'reused'}, 'observeOwner', Mock())

    def test_process_probe_refuses_local_host_before_output_creation(self):
        args = Mock(platform='macos', output=str(qa.ROOT / 'out/process-probe-test-must-not-exist'))
        with patch.dict(qa.os.environ, {'GITHUB_ACTIONS': 'false'}), patch.object(qa.Path, 'mkdir') as mkdir, self.assertRaises(qa.guard.Refused):
            qa.process_probe(args)
        mkdir.assert_not_called()

    def test_probe_child_rejection_keeps_finite_identity_evidence(self):
        owner = {'pid': 23, 'executable': '/private/SENSITIVE_UNEXPECTED_BINARY', 'started': 'first'}
        result = {}
        with patch.object(qa, 'mac_process_snapshot', return_value={'state': 'sleeping', 'parent_pid': 19}), self.assertRaisesRegex(qa.guard.Refused, 'probe_child_identity_mismatch'):
            qa.verify_probe_child_identity(result, 23, owner)
        diagnostic = result['child_identity']
        self.assertEqual(diagnostic, {'pid': 23, 'pid_matches': True, 'expected_executable_kind': 'fixedCat', 'observed_executable_kind': 'other', 'executable_matches': False, 'started_present': True, 'state': 'sleeping', 'parent_pid': 19})
        self.assertNotIn('SENSITIVE', str(result))
        self.assertNotIn('zombie_observed', result)

    def test_probe_child_requires_the_fixed_cat_image_and_start_identity(self):
        owner = {'pid': 23, 'executable': str(qa.Path('/bin/cat').resolve()), 'started': 'first'}
        with patch.object(qa, 'mac_process_snapshot', return_value={'state': 'sleeping'}):
            result = {}
            qa.verify_probe_child_identity(result, 23, owner)
            self.assertTrue(result['child_identity']['executable_matches'])
            for current in ({**owner, 'pid': 24}, {**owner, 'started': ''}, {**owner, 'executable': '/other/cat'}):
                with self.assertRaises(qa.guard.Refused):
                    qa.verify_probe_child_identity({}, 23, current)

    def test_local_machine_cannot_prepare_or_install(self):
        with patch.dict(qa.os.environ, {'GITHUB_ACTIONS': 'false'}), self.assertRaises(qa.guard.Refused):
            qa.guard.ci_identity('windows')

    def test_reused_pid_is_never_stopped(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        with patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', return_value={**owner, 'started': 'second'}):
            with self.assertRaisesRegex(qa.guard.Refused, 'cleanup_owner_mismatch'):
                qa.stop_owned(owner)

    def test_exit_during_identity_query_needs_no_force_stop(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        with patch.object(qa, 'alive', side_effect=[True, False]), patch.object(qa.guard, 'process_identity', side_effect=qa.guard.Refused('process_identity_unavailable')):
            self.assertTrue(qa.stop_owned(owner))

    def test_installed_bytes_and_parent_escape_are_checked(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            root = Path(directory)
            installed = root / 'installed'
            installed.mkdir()
            binary = installed / 'app'
            binary.write_bytes(b'one')
            expected = qa.tree_digest(installed)
            qa.verify_installed(installed, expected)
            binary.write_bytes(b'two')
            with self.assertRaises(qa.guard.Refused):
                qa.verify_installed(installed, expected)
            outside = root / 'other'
            outside.write_bytes(b'one')
            with self.assertRaises(qa.guard.Refused):
                qa.verify_installed(installed, {'../other': qa.guard.digest(outside)})

    def test_private_file_scope_rejects_other_output(self):
        with tempfile.TemporaryDirectory(dir=qa.ROOT / '.dart_tool') as directory:
            output = Path(directory).resolve()
            (output / 'private').mkdir()
            self.assertEqual(qa.private_path(output, output / 'private/new'), output / 'private/new')
            for other in [output / 'receipt', output / 'private/../other']:
                with self.assertRaises(qa.guard.Refused):
                    qa.private_path(output, other)

    def test_tls_setup_failure_closes_without_waiting_for_unstarted_server(self):
        server = Mock()
        qa.close_fixture(server, False)
        server.shutdown.assert_not_called()
        server.server_close.assert_called_once()
        started = Mock()
        qa.close_fixture(started, True)
        started.shutdown.assert_called_once()
        started.server_close.assert_called_once()

    def test_process_tree_adopts_only_verified_parent_descendants(self):
        parent = {'pid': 7, 'executable': '/owned/app', 'started': 'one'}
        child = {'pid': 8, 'executable': '/system/installer', 'started': 'two'}
        grandchild = {'pid': 9, 'executable': '/temporary/installer', 'started': 'three'}
        unknown = {'pid': 10, 'executable': '/other/app', 'started': 'four'}
        rows = [{'pid': 8, 'parent': 7, 'executable': child['executable']}, {'pid': 9, 'parent': 8, 'executable': grandchild['executable']}, {'pid': 10, 'parent': 1, 'executable': unknown['executable']}]
        identities = {item['pid']: item for item in [parent, child, grandchild, unknown]}
        owners = [parent]
        with patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', side_effect=lambda pid: identities[pid]):
            qa.observe_children(owners, rows)
        self.assertEqual(owners, [parent, child, grandchild])
        with patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', return_value={**parent, 'started': 'reused'}):
            with self.assertRaises(qa.guard.Refused):
                qa.observe_children([parent], rows)

    def test_process_scan_reaps_only_the_direct_child_before_observation(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        events = []
        child = Mock()
        child.poll.side_effect = lambda: events.append('poll')
        def rows(arguments):
            self.assertEqual(events, ['poll'])
            events.append('scan')
            return ''
        with patch.object(qa.sys, 'platform', 'darwin'), patch.object(qa, 'command', side_effect=rows), patch.object(qa, 'alive', return_value=False), patch.object(qa.guard, 'process_identity') as identity:
            qa.observe_children([owner], qa.process_rows(child))
        self.assertEqual(events, ['poll', 'scan'])
        child.poll.assert_called_once_with()
        child.terminate.assert_not_called()
        child.kill.assert_not_called()
        identity.assert_not_called()

    def test_process_scan_still_refuses_reused_pid_after_direct_child_poll(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        child = Mock()
        child.poll.return_value = None
        with patch.object(qa.sys, 'platform', 'darwin'), patch.object(qa, 'command', return_value='23 19 /other/app'), patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', return_value={**owner, 'started': 'reused', 'executable': '/other/app'}), self.assertRaisesRegex(qa.guard.Refused, 'cleanup_owner_mismatch'):
            qa.observe_children([owner], qa.process_rows(child))
        child.poll.assert_called_once_with()
        child.terminate.assert_not_called()

    def test_direct_exit_between_poll_and_identity_is_reaped_and_rescanned_once(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        child = Mock(pid=23, returncode=None)
        events, state, diagnostic = [], {'alive': True}, {}
        def poll():
            events.append('poll')
            if events.count('poll') == 2:
                state['alive'] = False
                child.returncode = 0
            return child.returncode
        child.poll.side_effect = poll
        with patch.object(qa.sys, 'platform', 'darwin'), patch.object(qa, 'command', side_effect=['23 19 /owned/app', '']) as scans, patch.object(qa, 'alive', side_effect=lambda pid: state['alive']), patch.object(qa.guard, 'process_identity', return_value={**owner, 'executable': '/work/app'}):
            qa.observe_direct_child([owner], child, report=diagnostic)
        self.assertEqual(scans.call_count, 2)
        self.assertEqual(events, ['poll', 'poll'])
        self.assertTrue(diagnostic['retry_attempted'])
        self.assertTrue(diagnostic['retry_pid_absent'])
        self.assertEqual(diagnostic['direct_child_returncode'], 0)
        child.terminate.assert_not_called()
        child.kill.assert_not_called()

    def test_direct_query_exit_race_keeps_original_exception_type_diagnostic(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        child = Mock(pid=23, returncode=0)
        diagnostic = {}
        with patch.object(qa, 'process_rows', side_effect=[[], []]) as scans, patch.object(qa, 'alive', side_effect=[True, False, False]), patch.object(qa.guard, 'process_identity', side_effect=qa.subprocess.CalledProcessError(1, ['PRIVATE_COMMAND'])):
            qa.observe_direct_child([owner], child, report=diagnostic)
        self.assertEqual(scans.call_count, 2)
        self.assertEqual(diagnostic['failure_kind'], 'calledProcessError')
        self.assertEqual(diagnostic['failure_phase'], 'observeOwner')
        self.assertNotIn('PRIVATE_COMMAND', str(diagnostic))

    def test_direct_exit_retry_never_accepts_live_reuse_changed_start_or_foreign_owner(self):
        direct = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        foreign = {'pid': 24, 'executable': '/owned/core', 'started': 'first'}
        cases = [(direct, {**direct, 'started': 'reused'}, 0), (direct, {**direct, 'pid': 24}, 0), (direct, {**direct, 'executable': '/other/app'}, None), (direct, {**direct, 'executable': '/other/app'}, 0), (foreign, {**foreign, 'executable': '/other/core'}, 0)]
        for owner, current, code in cases:
            with self.subTest(owner_pid=owner['pid'], returncode=code):
                child = Mock(pid=23, returncode=code)
                child.poll.return_value = code
                with patch.object(qa, 'process_rows', return_value=[]) as scans, patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', return_value=current), self.assertRaisesRegex(qa.guard.Refused, 'cleanup_owner_mismatch'):
                    qa.observe_direct_child([owner], child)
                scans.assert_called_once_with(child)
                child.terminate.assert_not_called()
                child.kill.assert_not_called()

    def test_unrelated_identity_query_errors_are_not_retryable(self):
        owner = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        for error in (qa.subprocess.CalledProcessError(2, ['PRIVATE_COMMAND']), PermissionError('PRIVATE_PATH'), TypeError('PRIVATE_VALUE')):
            with self.subTest(kind=type(error).__name__):
                child = Mock(pid=23, returncode=0)
                with patch.object(qa, 'process_rows', return_value=[]) as scans, patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', side_effect=error), self.assertRaisesRegex(qa.guard.Refused, 'owned_process_identity_unavailable'):
                    qa.observe_direct_child([owner], child)
                scans.assert_called_once_with(child)
                child.poll.assert_not_called()

    def test_unadopted_child_query_failure_is_diagnosed_without_retry(self):
        parent = {'pid': 7, 'executable': '/owned/app', 'started': 'first'}
        child = Mock(pid=23, returncode=0)
        diagnostic = {}
        rows = [{'pid': 23, 'parent': 7, 'executable': '/owned/child'}]
        with patch.object(qa, 'process_rows', return_value=rows) as scans, patch.object(qa, 'alive', return_value=True), patch.object(qa.guard, 'process_identity', side_effect=[parent, parent, qa.subprocess.CalledProcessError(1, ['PRIVATE_COMMAND'])]), self.assertRaisesRegex(qa.guard.Refused, 'owned_process_identity_unavailable'):
            qa.observe_direct_child([parent], child, report=diagnostic)
        self.assertEqual(diagnostic['failure_phase'], 'adoptChild')
        self.assertEqual(diagnostic['failure_kind'], 'calledProcessError')
        self.assertFalse(diagnostic['retry_attempted'])
        scans.assert_called_once_with(child)
        child.poll.assert_not_called()

    def test_direct_exit_retry_is_bounded_and_does_not_swallow_second_owner_failure(self):
        direct = {'pid': 23, 'executable': '/owned/app', 'started': 'first'}
        foreign = {'pid': 24, 'executable': '/owned/core', 'started': 'first'}
        child = Mock(pid=23, returncode=0)
        with patch.object(qa, 'process_rows', side_effect=[[], []]) as scans, patch.object(qa, 'alive', side_effect=[True, False, False, True]), patch.object(qa.guard, 'process_identity', side_effect=[{**direct, 'executable': '/work/app'}, {**foreign, 'started': 'reused'}]), self.assertRaisesRegex(qa.guard.Refused, 'cleanup_owner_mismatch'):
            qa.observe_direct_child([direct, foreign], child)
        self.assertEqual(scans.call_count, 2)
        child.poll.assert_called_once_with()

    def test_fixture_exception_kinds_never_export_raw_errors(self):
        self.assertEqual(qa.fixture_exception_kind(qa.subprocess.CalledProcessError(1, ['SENSITIVE_COMMAND'])), 'calledProcessError')
        self.assertEqual(qa.fixture_exception_kind(KeyError('SENSITIVE_KEY')), 'keyError')
        self.assertEqual(qa.fixture_exception_kind(TypeError('SENSITIVE_VALUE')), 'typeError')
        self.assertEqual(qa.fixture_exception_kind(RuntimeError('SENSITIVE_VALUE')), 'other')


if __name__ == '__main__':
    unittest.main()
