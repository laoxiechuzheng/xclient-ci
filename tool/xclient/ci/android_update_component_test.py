import copy
import argparse
import importlib.util
import json
import os
import re
from pathlib import Path
import sys
import time
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile
import struct
import shutil

sys.path.insert(0, str(Path(__file__).resolve().parent))
spec = importlib.util.spec_from_file_location('android_update_component', Path(__file__).with_name('android_update_component.py'))
component = importlib.util.module_from_spec(spec)
if spec.loader is not None:
    spec.loader.exec_module(component)


class ComponentGuardTest(unittest.TestCase):
    def setUp(self):
        self.context = dict(repository='owner/client', run_id='123', run_attempt='1', sha='a' * 40)
        self.state = dict(build_mode='profile', purpose='update-component', sources={'target.dart': 'b' * 64}, defines_sha256='c' * 64)
        self.base = dict(XC_BRAND_ID='example', XC_VERSION_NAME='1.0.0-pre.1', XC_BUILD_NUMBER='10000401', SAFE_MODE='true', APP_ENV='dev')
        self.context_patch = patch.object(component.qa, 'transfer_context', return_value=self.context)
        self.context_patch.start()
        self.addCleanup(self.context_patch.stop)

    def pair(self):
        return component.pair_receipt(self.state, self.base, 'd' * 32, {
            str(n): dict(sha256=str(n) * 64, size=100 + n, signer_sha256='e' * 64, app_label='Example 加速器', built_ns=time.time_ns())
            for n in (1, 2)
        })

    def test_stage_defines_bind_the_compiled_fixture_and_only_v1_to_v2_bytes(self):
        one = component.stage_defines(self.base, 'd' * 32, '1', '2' * 64, 102)
        two = component.stage_defines(self.base, 'd' * 32, '2')
        self.assertEqual(one['XC_ANDROID_UPDATE_V2_SHA256'], '2' * 64)
        self.assertEqual(one['XC_ANDROID_UPDATE_V2_BYTES'], '102')
        self.assertEqual(two['XC_VERSION_NAME'], '1.0.0-pre.2')
        self.assertEqual(two['XC_BUILD_NUMBER'], '10000402')
        self.assertEqual(two['XC_ANDROID_UPDATE_V2_SHA256'], '')
        self.assertEqual(two['XC_ANDROID_UPDATE_V2_BYTES'], '0')
        self.assertEqual(one['XC_ANDROID_UPDATE_SOURCE'], 'a' * 40)
        self.assertNotIn('XC_ANDROID_UPDATE_QA', self.base)

    def test_nonhosted_runs_and_foreign_jobs_refuse_before_sdk_or_guest_access(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(component.qa, 'sdk_tool') as sdk, patch.object(component.qa, 'command') as command, self.assertRaises(component.qa.Refused):
            component.load(argparse.Namespace(state='/foreign/state.json'), component.qa.PRODUCER_JOB)
        sdk.assert_not_called()
        command.assert_not_called()
        with patch.object(component.qa, 'load_state', return_value=(self.state, Path('/owned'))), patch.dict(os.environ, {'GITHUB_JOB': 'foreign'}), self.assertRaises(component.qa.Refused):
            component.load(argparse.Namespace(state='/foreign/state.json'), component.qa.CONSUMER_JOB)

    def test_component_debug_preparation_is_refused_before_sdk_or_output_work(self):
        with patch.object(component.qa, 'ci_identity', return_value='owned-job'), patch.dict(os.environ, {'GITHUB_JOB': component.qa.PRODUCER_JOB, 'XCLIENT_ANDROID_QA_PURPOSE': 'update-component'}), patch.object(component.qa, 'sdk_tool') as sdk, self.assertRaisesRegex(component.qa.Refused, '^component_profile_purpose_required$'):
            component.qa.prepare(argparse.Namespace(output='/foreign', purpose='update-component', build_mode='debug'))
        sdk.assert_not_called()

    def test_native_failure_is_finite_and_cannot_upload_arbitrary_fields(self):
        driver = component.ComponentDriver.__new__(component.ComponentDriver)
        driver.pair, driver.guest, driver.report = self.pair(), {'pid': 1234}, {}
        value = component.control_lease(driver.pair, '1', 1234, 'prepare')
        value.pop('action')
        value.update(phase='initialStore', error_class='store', synthetic_cleanup_confirmed=False)
        driver.read = Mock(return_value=value)
        with self.assertRaisesRegex(component.qa.Refused, '^native_component_stage_failed$'):
            driver.wait('ready-1.json', '1')
        self.assertEqual(driver.report['native_failure'], dict(phase='initialStore', error_class='store', synthetic_cleanup_confirmed=False))
        driver.report = {}
        driver.read.return_value = dict(value, password='PRIVATE')
        with self.assertRaisesRegex(component.qa.Refused, '^native_component_failure_schema_required$'):
            driver.wait('ready-1.json', '1')
        self.assertNotIn('PRIVATE', json.dumps(driver.report))

    def test_actual_store_returns_must_be_successful_timely_and_value_free(self):
        driver = component.ComponentDriver.__new__(component.ComponentDriver)
        driver.output = Path('/owned')
        values = [dict(stage='2', id=1, operation='crossRead', event=event, outcome='pending' if event == 'begin' else 'success', started_ms=123, elapsed_ms=ms, **(dict(method='read', late=False) if event == 'nativeReturn' else {})) for event, ms in [('begin', 0), ('nativeReturn', 20), ('end', 21)]]
        driver.wait = Mock(side_effect=values)
        with patch.object(component.qa, 'write_json') as write:
            driver.store_proofs('2', (('crossRead', 'read'),))
        self.assertEqual(len(write.call_args.args[1]), 3)
        for changes in [dict(elapsed_ms=15001), dict(late=True), dict(value='PRIVATE'), dict(outcome='error')]:
            bad = copy.deepcopy(values)
            bad[1].update(changes)
            driver.wait = Mock(side_effect=bad)
            with patch.object(component.qa, 'write_json') as write, self.assertRaises(component.qa.Refused):
                driver.store_proofs('2', (('crossRead', 'read'),))
            write.assert_not_called()

    def test_pair_schema_rejects_foreign_run_source_mode_stage_signer_and_unbound_defines(self):
        pair = self.pair()
        component.validate_pair(self.state, self.base, pair)
        changes = [
            lambda p: p.update(run_id='124'), lambda p: p.update(run_attempt='2'),
            lambda p: p.update(sha='b' * 40), lambda p: p.update(repository='other/repo'),
            lambda p: p.update(purpose='lifecycle'), lambda p: p.update(schema=True),
            lambda p: p.update(private_key='PRIVATE'), lambda p: p.update(fixture_id='../foreign'),
            lambda p: p['stages']['2'].update(signer_sha256='f' * 64),
            lambda p: p['stages']['1'].update(defines_sha256='f' * 64),
            lambda p: p['stages']['1'].update(size=True),
            lambda p: p['stages']['1'].update(filename='foreign.apk'),
            lambda p: p['stages']['2'].update(version='1.0.0-pre.1'),
            lambda p: p['stages']['2'].update(build=10000402.0),
            lambda p: p['checks'].update(same_signer=1),
            lambda p: p.update(stages={'1': p['stages']['1']}),
        ]
        for change in changes:
            bad = copy.deepcopy(pair)
            change(bad)
            with self.subTest(change=changes.index(change)), self.assertRaises(component.qa.Refused):
                component.validate_pair(self.state, self.base, bad)

    def test_invalid_compiled_identity_is_rejected_before_a_target_path_is_used(self):
        for fixture, stage, digest, size in [('../bad', '1', '2' * 64, 2), ('d' * 32, '3', '', 0), ('d' * 32, '1', '', 0), ('d' * 32, '2', '2' * 64, 2), ('d' * 32, '1', '2' * 64, True)]:
            with self.subTest(stage=stage, fixture=fixture), self.assertRaises(component.qa.Refused):
                component.stage_defines(self.base, fixture, stage, digest, size)

    def test_control_lease_is_exact_and_does_not_include_host_private_state(self):
        pair = self.pair()
        lease = component.control_lease(pair, '1', 1234, 'prepare')
        self.assertEqual(set(lease), {'schema', 'fixture_id', 'source_sha', 'run_id', 'run_attempt', 'stage', 'pid', 'action'})
        self.assertEqual(lease['pid'], 1234)
        for stage, pid, action in [('2', 1234, 'install'), ('1', True, 'prepare'), ('1', -1, 'prepare'), ('1', 1234, 'other')]:
            with self.assertRaises(component.qa.Refused):
                component.control_lease(pair, stage, pid, action)

    def test_native_hello_and_receipts_require_the_exact_current_guest_generation(self):
        pair = self.pair()
        hello = {**component.control_lease(pair, '1', 1234, 'prepare')}
        hello.pop('action')
        hello.update(native_identity=True, native_version='1.0.0-pre.1', native_build='10000401', app_label='Example 加速器')
        component.validate_hello(pair, '1', hello, {'pid': 1234})
        for key, value in [('pid', 1235), ('stage', '2'), ('source_sha', 'f' * 40), ('native_build', '10000402'), ('app_label', 'Foreign'), ('native_identity', 1)]:
            bad = dict(hello, **{key: value})
            with self.subTest(key=key), self.assertRaises(component.qa.Refused):
                component.validate_hello(pair, '1', bad, {'pid': 1234})

    def test_system_actions_require_exact_owner_app_label_control_and_window(self):
        tree = component.qa.ET.fromstring('<hierarchy><node package="com.android.settings" text="Example 加速器" enabled="true"/><node package="com.android.settings" text="Allow from this source" enabled="true"/><node package="com.android.settings" resource-id="com.android.settings:id/switch_widget" class="android.widget.Switch" checkable="true" checked="false" enabled="true" bounds="[20,20][70,70]"/></hierarchy>')
        activity = b'mResumedActivity: ActivityRecord{abc u0 com.android.settings/.Settings$ManageExternalSourcesActivity t1}'
        observed = component.system_action(tree, activity, 'permission', 'Example 加速器')
        self.assertEqual(observed['package'], 'com.android.settings')
        self.assertEqual(observed['center'], (45, 45))
        for mutate in [lambda t: t[0].set('text', 'Foreign'), lambda t: t[2].set('checked', 'true'), lambda t: t[2].set('package', 'foreign.app'), lambda t: t.append(copy.deepcopy(t[2]))]:
            bad = copy.deepcopy(tree)
            mutate(bad)
            with self.assertRaises(component.qa.Refused):
                component.system_action(bad, activity, 'permission', 'Example 加速器')
        with self.assertRaises(component.qa.Refused):
            component.system_action(tree, activity.replace(b'com.android.settings/', b'foreign.app/'), 'permission', 'Example 加速器')

    def test_package_install_button_is_not_an_arbitrary_foreign_tap(self):
        tree = component.qa.ET.fromstring('<hierarchy><node package="com.google.android.packageinstaller" text="Example 加速器" enabled="true"/><node package="com.google.android.packageinstaller" text="Update" resource-id="android:id/button1" enabled="true" bounds="[20,20][70,70]"/><node package="com.google.android.packageinstaller" text="Cancel" resource-id="android:id/button2" enabled="true"/></hierarchy>')
        activity = b'topResumedActivity=ActivityRecord{abc u0 com.google.android.packageinstaller/com.android.packageinstaller.PackageInstallerActivity t1}'
        self.assertEqual(component.system_action(tree, activity, 'install', 'Example 加速器')['center'], (45, 45))
        tree[1].set('text', 'Delete')
        with self.assertRaises(component.qa.Refused):
            component.system_action(tree, activity, 'install', 'Example 加速器')

    def test_system_action_rechecks_the_window_and_rejects_clipped_buttons(self):
        driver = component.ComponentDriver.__new__(component.ComponentDriver)
        driver.device = Mock()
        driver.verify = Mock()
        driver.attest_system = Mock()
        driver.report = {'system_actions': []}
        observed = dict(package='com.android.settings', component='com.android.settings/.Settings$ManageExternalSourcesActivity', center=(200, 100))
        driver.system_owners = {'com.android.settings': {'apk_sha256': 'e' * 64}}
        for second, size in [(dict(observed, center=(210, 100)), dict(width=1080, height=1920)), (observed, dict(width=150, height=1920))]:
            driver.observe_system = Mock(side_effect=[observed, second])
            driver.device.capture.return_value = size
            with self.assertRaises(component.qa.Refused):
                driver.tap_system('permission')
            driver.device.call.assert_not_called()
        driver.observe_system = Mock(side_effect=[observed, observed])
        driver.device.capture.return_value = dict(width=1080, height=1920)
        driver.tap_system('permission')
        driver.device.call.assert_called_once_with('shell', 'input', 'tap', 200, 100)
        self.assertEqual(len(driver.report['system_actions']), 1)

    def signer_apk(self, certs, *, versions=('35.0.0', '37.0.0'), exit_code=0):
        sdk = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, sdk)
        for version in versions:
            for tool in ('aapt2', 'apksigner'):
                (sdk / 'build-tools' / version).mkdir(parents=True, exist_ok=True)
                (sdk / 'build-tools' / version / tool).write_bytes(b'')
        apk = sdk / 'app-profile.apk'
        apk.write_bytes(b'apk')
        badging = ("package: name='com.xclient.example' versionCode='10000402' versionName='1.0.0-pre.2'\n"
                   "launchable-activity: name='com.follow.clash.MainActivity'\napplication-debuggable\n"
                   "application-label:'Example'\n").encode()
        tools = []

        def command(argv, **_):
            tools.append(Path(argv[0]))
            if Path(argv[0]).name == 'aapt2':
                return badging
            if exit_code:
                raise component.qa.Refused('owned_command_failed', exit_code)
            return certs.encode()

        with patch.object(component.qa, 'validate_apk'), patch.object(component.qa, 'command', side_effect=command):
            try:
                return component.apk_info(dict(sdk=str(sdk)), apk, '2')
            finally:
                self.assertEqual([tool.parent.name for tool in tools][-1:], [versions[-1]])

    def test_signer_digest_reads_apksigner_output_before_and_after_build_tools_37(self):
        digest = 'ab' * 32
        for certs in (
            f'Signer #1 certificate DN: C=US, O=Android, CN=Android Debug\nSigner #1 certificate SHA-256 digest: {digest}\n'
            f'Signer #1 certificate SHA-1 digest: {"cd" * 20}\nSigner #1 certificate MD5 digest: {"ef" * 16}\n',
            f'V2 Signer: certificate DN: C=US, O=Android, CN=Android Debug\nV2 Signer: certificate SHA-256 digest: {digest}\n'
            f'V2 Signer: certificate SHA-1 digest: {"cd" * 20}\nV2 Signer: certificate MD5 digest: {"ef" * 16}\n',
            f'V3.0 Signer: certificate SHA-256 digest: {digest}\r\n',
            f'V1 Signer: certificate SHA-256 digest: {digest}\n',
            f'Signer: certificate SHA-256 digest: {digest}\n',
        ):
            with self.subTest(certs=certs.split(':')[0]):
                self.assertEqual(self.signer_apk(certs)['signer_sha256'], digest)

    def test_signer_digest_refuses_all_but_exactly_one_primary_signer_with_bounded_diagnostics(self):
        one, two = 'ab' * 32, 'cd' * 32
        cases = {
            '': (0, 0, 0),
            f'Signer #1 certificate SHA-256 digest: {one}\nSigner #2 certificate SHA-256 digest: {two}\n': (2, 1, 2),
            f'V2 Signer #1: certificate SHA-256 digest: {one}\nV2 Signer #2: certificate SHA-256 digest: {two}\n': (2, 0, 2),
            f'V2 Signer: certificate SHA-256 digest: {one}\nV2 Signer: certificate SHA-256 digest: {one}\n': (2, 2, 1),
            f'V2 Signer: certificate SHA-256 digest: {one}\nSource Stamp Signer: certificate SHA-256 digest: {two}\n': (2, 1, 2),
            f'V3.1 Signer (minSdkVersion=33): certificate SHA-256 digest: {one}\n': (1, 0, 1),
            f'V2 Signer: certificate SHA-256 digest: {one.upper()}\n': (1, 1, 0),
            f'V2 Signer: certificate SHA-256 digest: {one}\n' + 'x' * 32768: (0, 0, 0),
        }
        for certs, (lines, primary, distinct) in cases.items():
            with self.subTest(certs=certs[:60]):
                with self.assertRaisesRegex(component.SignerRefused, '^single_component_signer_required$') as caught:
                    self.signer_apk(certs)
                self.assertEqual(caught.exception.diagnostic, dict(stage='2', build_tools='37.0.0', apksigner_exit_code=0, output_bytes=len(certs.encode()), digest_lines=lines, primary_signer_lines=primary, distinct_digests=distinct))
                self.assertNotRegex(json.dumps(caught.exception.diagnostic), '[a-fA-F0-9]{32}')

    def test_failed_apksigner_reports_its_exit_code_and_build_tools_without_output(self):
        with self.assertRaisesRegex(component.SignerRefused, '^component_signer_tool_failed$') as caught:
            self.signer_apk('', versions=('36.1.0',), exit_code=1)
        self.assertEqual(caught.exception.diagnostic, dict(stage='2', build_tools='36.1.0', apksigner_exit_code=1))

    def test_signer_refusal_is_printed_with_its_diagnostic(self):
        diagnostic = dict(stage='1', build_tools='37.0.0', apksigner_exit_code=0, output_bytes=0, digest_lines=0, primary_signer_lines=0, distinct_digests=0)
        with patch.object(component, 'build', side_effect=component.SignerRefused('single_component_signer_required', diagnostic)), \
                patch.object(sys, 'argv', ['android_update_component.py', 'build', '--state', 'state.json']), \
                patch('builtins.print') as printed:
            self.assertEqual(component.main(), 1)
        self.assertEqual(json.loads(printed.call_args.args[0]), {'success': False, 'error': 'single_component_signer_required', 'signer': diagnostic})

    def receipt_driver(self, outputs):
        """A driver whose guest serves each receipt from its queue of reads."""
        driver = component.ComponentDriver.__new__(component.ComponentDriver)
        driver.pair, driver.guest, driver.relative = self.pair(), {'pid': 1234}, 'cache/xclient-update-qa-' + 'd' * 32
        driver.report, driver.verify = {}, Mock()
        calls = []

        def call(*argv, **_):
            calls.append(argv[0])
            name = re.search(r'/([A-Za-z0-9-]+\.json) \]; then printf missing', argv[-1])[1]
            queue = outputs.get(name, [b'missing'])
            value = queue.pop(0) if len(queue) > 1 else queue[0]
            if isinstance(value, Exception):
                raise value
            return value

        driver.device = Mock(call=Mock(side_effect=call))
        return driver, calls

    def hello(self):
        value = component.control_lease(self.pair(), '1', 1234, 'prepare')
        value.pop('action')
        return value

    def test_a_receipt_read_while_unreadable_is_retried_until_it_parses(self):
        whole = component.encoded(self.hello())
        driver, calls = self.receipt_driver({'hello-1.json': [b'missing', b'', whole[:7], whole]})
        with patch.object(component.time, 'sleep'):
            self.assertEqual(driver.wait('hello-1.json', '1'), self.hello())
        self.assertEqual(driver.report, {'step': 'hello-1.json', 'receipt_invalid_reads': 2})
        self.assertEqual(set(calls), {'shell'})

    def test_a_receipt_that_stays_unparsable_fails_as_invalid_without_its_content(self):
        secret = b'{"token": "PRIVATE-VALUE"'
        driver, _ = self.receipt_driver({'hello-1.json': [secret]})
        with patch.object(component.time, 'sleep'), self.assertRaisesRegex(component.qa.Refused, '^component_receipt_json_invalid$'):
            driver.wait('hello-1.json', '1')
        self.assertEqual(driver.report['receipt_failure'], {'file': 'hello-1.json', 'bytes': len(secret), 'attempts': component.INVALID_RECEIPT_READS})
        self.assertNotIn('PRIVATE', json.dumps(driver.report))

    def test_an_unparsable_receipt_at_the_deadline_is_invalid_not_a_timeout(self):
        driver, _ = self.receipt_driver({'hello-1.json': [b'\xff\xfe']})
        clock = [0.0]
        with patch.object(component.time, 'monotonic', side_effect=lambda: clock[0]), \
                patch.object(component.time, 'sleep', side_effect=lambda seconds: clock.__setitem__(0, clock[0] + seconds)), \
                patch.object(component, 'INVALID_RECEIPT_READS', 100), \
                self.assertRaisesRegex(component.qa.Refused, '^component_receipt_json_invalid$'):
            driver.wait('hello-1.json', '1', timeout=1)
        self.assertEqual(driver.report['receipt_failure'], {'file': 'hello-1.json', 'bytes': 2, 'attempts': 2})

    def test_a_failed_guest_read_keeps_its_exit_status_instead_of_parsing_its_output(self):
        for exit_code, code in ((3, 'component_receipt_not_regular'), (1, 'component_receipt_read_failed')):
            with self.subTest(exit_code=exit_code):
                driver, _ = self.receipt_driver({'hello-1.json': [component.qa.Refused('owned_command_failed', exit_code)]})
                with self.assertRaisesRegex(component.qa.Refused, '^' + code + '$'):
                    driver.wait('hello-1.json', '1')
                self.assertEqual(driver.report['receipt_failure'], {'file': 'hello-1.json', 'exit_code': exit_code})

    def test_the_component_step_reaches_the_run_receipt_when_the_driver_fails(self):
        receipt = {}
        driver = Mock(report={'step': 'hello-1.json'}, run=Mock(side_effect=ValueError('Expecting value')))
        with tempfile.TemporaryDirectory() as directory, patch.object(component, 'ComponentDriver', return_value=driver):
            output = Path(directory)
            (output / 'receipts').mkdir()
            with self.assertRaises(ValueError):
                component.run_component(Mock(), {}, output, receipt)
            self.assertEqual(receipt, {'component_step': 'hello-1.json'})
            self.assertEqual(json.loads((output / 'receipts/component-result.json').read_text()), {'step': 'hello-1.json'})

    def test_paired_export_import_keeps_bytes_and_artifact_owner_separate(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder).resolve()
            producer, consumer = root / 'out/producer', root / 'out/consumer'
            for directory in (producer, consumer):
                (directory / 'private').mkdir(parents=True)
                (directory / 'receipts').mkdir()
                component.qa.write_json(directory / 'private/defines.json', self.base)
            built = {}
            for stage in ('1', '2'):
                apk = producer / 'private' / ('app-v' + stage + '.apk')
                header = bytearray(20)
                header[:6], header[18:20] = b'\x7fELF\x02\x01', struct.pack('<H', 62)
                with zipfile.ZipFile(apk, 'w') as archive:
                    for library in ('libflutter.so', 'libclash.so', 'libapp.so'):
                        archive.writestr('lib/x86_64/' + library, header)
                    archive.writestr('stage', stage)
                built[stage] = dict(sha256=component.qa.sha(apk), size=apk.stat().st_size, signer_sha256='e' * 64, app_label='Example 加速器', built_ns=time.time_ns())
            pair = component.pair_receipt(self.state, self.base, 'd' * 32, built)
            component.qa.write_json(producer / 'private/update-pair.json', pair)
            producer_state = dict(self.state, job='producer-private', nonce='1' * 32)
            consumer_state = dict(self.state, job='consumer-private', nonce='2' * 32)
            component.qa.write_json(producer / 'private/build.json', dict(origin='local-component', job=producer_state['job'], nonce=producer_state['nonce'], artifact_id=None, pair_sha256=component.qa.sha(producer / 'private/update-pair.json')))
            with patch.object(component.qa, 'ROOT', root), patch.dict(os.environ, {'GITHUB_JOB': component.qa.PRODUCER_JOB}), patch.object(component, 'load', return_value=(producer_state, producer)):
                component.export(None)
            shutil.copytree(producer / 'export', consumer / 'incoming')
            def metadata(state, path, stage):
                return {key: pair['stages'][stage][key] for key in ('signer_sha256', 'app_label')} | dict(sha256=component.qa.sha(path), size=path.stat().st_size)
            with patch.object(component.qa, 'ROOT', root), patch.dict(os.environ, {'GITHUB_JOB': component.qa.CONSUMER_JOB, 'XCLIENT_ANDROID_APK_ARTIFACT_ID': '987'}), patch.object(component, 'load', return_value=(consumer_state, consumer)), patch.object(component, 'apk_info', side_effect=metadata) as native:
                component.import_pair(None)
                receipt = json.loads((consumer / 'private/build.json').read_text())
                self.assertEqual(receipt['artifact_id'], '987')
                self.assertEqual(receipt['nonce'], consumer_state['nonce'])
                self.assertNotIn(producer_state['nonce'], json.dumps(pair))
                self.assertEqual(component.qa.sha(component.validate_staged(consumer_state, consumer, receipt)), built['1']['sha256'])
                self.assertEqual(native.call_count, 2)
                with patch.dict(os.environ, {'XCLIENT_ANDROID_APK_ARTIFACT_ID': '988'}), self.assertRaises(component.qa.Refused):
                    component.validate_staged(consumer_state, consumer, receipt)
                (consumer / 'private/app-v2.apk').write_bytes(b'changed')
                with self.assertRaises(component.qa.Refused):
                    component.validate_staged(consumer_state, consumer, receipt)
            (producer / 'export/private-key').write_text('private')
            with self.assertRaises(component.qa.Refused):
                component.pair_files(producer / 'export')


if __name__ == '__main__':
    unittest.main()
