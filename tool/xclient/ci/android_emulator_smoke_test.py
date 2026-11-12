import json
import argparse
import base64
import importlib.util
import os
from pathlib import Path
import struct
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
import zipfile

LAUNCHER = Path(__file__).with_name('android_emulator_smoke.py')
spec = importlib.util.spec_from_file_location('android_smoke', LAUNCHER)
smoke = importlib.util.module_from_spec(spec)
spec.loader.exec_module(smoke)


class LocalRefusalTest(unittest.TestCase):
    def test_extracted_normal_main_flow_keeps_its_package_and_all_lifecycle_checks(self):
        device = Mock(spec=smoke.Device, package=smoke.lifecycle_probe.PROFILE_PACKAGE)
        tree = smoke.ET.fromstring('<hierarchy><node class="android.widget.EditText"/><node class="android.widget.EditText"/></hierarchy>')
        device.await_login.return_value = (tree, tree[0], True)
        device.call.return_value = b'1234'
        receipt = dict(errors=[], captures={})
        lifecycle = dict(success=True, replacements=[{'client_destroy_callback_returned': True, 'same_main_isolate': True}] * 2, vm_forward_cleanup=True)
        with patch.object(smoke, 'initial_start', return_value=True), patch.object(smoke.time, 'sleep'), patch.object(smoke.lifecycle_probe, 'LifecycleProbe') as probe:
            probe.return_value.run.return_value = lifecycle
            smoke.verify_lifecycle(device, receipt)
        self.assertTrue(all(receipt[key] is True for key in ('login_rendered', 'empty_form_validation', 'home_reopen', 'back_reopen', 'same_process_after_home', 'activity_destruction_tested', 'same_ui_isolate_across_activity_replacement', 'explicit_quit_reopen_verified', 'vm_forward_cleanup_verified')))
        self.assertEqual([call.args for call in device.call.call_args_list if call.args[:2] == ('shell', 'pidof')], [('shell', 'pidof', device.package)] * 2)

    def test_android_purpose_is_bound_to_the_explicit_job_and_preserves_default_lifecycle(self):
        with patch.dict(os.environ, {'XCLIENT_ANDROID_QA_PURPOSE': 'lifecycle'}):
            self.assertEqual(smoke.qa_purpose({}), 'lifecycle')
            with self.assertRaisesRegex(smoke.Refused, '^prepared_purpose_mismatch$'):
                smoke.qa_purpose({'purpose': 'update-component'})
        with patch.dict(os.environ, {'XCLIENT_ANDROID_QA_PURPOSE': 'update-component'}):
            self.assertEqual(smoke.qa_purpose({'purpose': 'update-component'}), 'update-component')
            with self.assertRaises(smoke.Refused):
                smoke.qa_purpose({})
        with patch.dict(os.environ, {'XCLIENT_ANDROID_QA_PURPOSE': 'foreign'}), self.assertRaises(smoke.Refused):
            smoke.qa_purpose()

    def test_login_transition_has_its_own_budget_after_verified_consent(self):
        agree = smoke.ET.fromstring('<hierarchy><node text="Agree" enabled="true" package="com.xclient.example"/></hierarchy>')
        login = smoke.ET.fromstring('<hierarchy><node text="登录" enabled="true" package="com.xclient.example"/></hierarchy>')
        device = Mock(spec=smoke.Device)
        elapsed = [0]
        device.ui.side_effect = [agree, login]
        def complete():
            elapsed[0] += 180
            return True
        device.disclaimer.side_effect = complete
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), patch.object(smoke.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)):
            tree, button, confirmed = smoke.Device.await_login(device)
        self.assertIs(tree, login)
        self.assertEqual(button.get('text'), '登录')
        self.assertTrue(confirmed)
        device.disclaimer.assert_called_once()

    def test_unconfirmed_consent_cannot_reset_the_login_budget(self):
        agree = smoke.ET.fromstring('<hierarchy><node text="Agree" enabled="true" package="com.xclient.example"/></hierarchy>')
        device = Mock(spec=smoke.Device)
        elapsed = [0]
        device.ui.return_value = agree
        def incomplete():
            elapsed[0] += 180
            return False
        device.disclaimer.side_effect = incomplete
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), patch.object(smoke.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)), self.assertRaisesRegex(smoke.Refused, '^login_ui_missing$'):
            smoke.Device.await_login(device)
        device.disclaimer.assert_called_once()

    def test_reappearing_consent_cannot_repeat_actions_or_extend_the_deadline(self):
        agree = smoke.ET.fromstring('<hierarchy><node text="Agree" enabled="true" package="com.xclient.example"/></hierarchy>')
        device = Mock(spec=smoke.Device)
        elapsed = [0]
        device.ui.return_value = agree
        device.disclaimer.return_value = True
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), patch.object(smoke.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)), self.assertRaisesRegex(smoke.Refused, '^consent_reappeared_after_confirmation$'):
            smoke.Device.await_login(device)
        device.disclaimer.assert_called_once()

    def test_post_consent_login_transition_is_still_bounded(self):
        agree = smoke.ET.fromstring('<hierarchy><node text="Agree" enabled="true" package="com.xclient.example"/></hierarchy>')
        loading = smoke.ET.fromstring('<hierarchy><node package="com.xclient.example"/></hierarchy>')
        device = Mock(spec=smoke.Device)
        elapsed = [0]
        trees = iter([agree])
        device.ui.side_effect = lambda: next(trees, loading)
        def complete():
            elapsed[0] += 180
            return True
        device.disclaimer.side_effect = complete
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), patch.object(smoke.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)), self.assertRaisesRegex(smoke.Refused, '^login_ui_missing$'):
            smoke.Device.await_login(device)
        self.assertEqual(elapsed[0], 280)
        device.disclaimer.assert_called_once()

    def test_completed_consent_reads_only_keyboard_visibility_from_a_large_ime_service(self):
        agree = smoke.ET.fromstring('<hierarchy><node text="Agree" enabled="true" package="com.xclient.example.dev"/></hierarchy>')
        field = smoke.ET.fromstring('<hierarchy><node class="android.widget.EditText" enabled="true" package="com.xclient.example.dev"/></hierarchy>')
        confirm = smoke.ET.fromstring('<node text="Confirm" enabled="true" package="com.xclient.example.dev"/>')
        device = Mock(spec=smoke.Device, package=smoke.PACKAGE)
        device.ui.side_effect = [agree, field]
        device.wait_label.return_value = (field, confirm)
        def call(*args):
            if args[:3] == ('shell', 'input', 'keyevent'):
                return b''
            if len(args) == 2 and args[0] == 'shell' and args[1].startswith('dumpsys input_method | sed -n ') and 'mInputShown=' in args[1]:
                return b'  mInputShown=true\n'
            return b'UNRELATED_SERVICE_DIAGNOSTIC' * 30000
        device.call.side_effect = call
        device.record_consent_input.return_value = {'input_method_visible': True}
        failure = None
        try:
            smoke.Device.disclaimer(device)
        except smoke.Refused as error:
            failure = str(error)
        self.assertIsNone(failure)
        self.assertEqual(device.record_consent_input.call_args.args[1], b'  mInputShown=true\n')
        self.assertEqual(device.tap.call_args.args[0], confirm)

    def test_native_observation_cost_is_included_in_the_finite_chunk_budget(self):
        device = smoke.Device.__new__(smoke.Device)
        elapsed, typed = [0], ['']
        statement = json.loads((smoke.ROOT / 'arb/intl_en.arb').read_text(encoding='utf-8'))['disclaimerNoServiceStatement']
        device.verify_owned = Mock()
        def ui():
            elapsed[0] += 8
            return smoke.ET.Element('node', {'class': 'android.widget.EditText', 'package': smoke.PACKAGE, 'focused': 'true', 'enabled': 'true', 'text': typed[0]})
        def call(*args):
            typed[0] += smoke.shlex.split(args[-1])[0].replace('%s', ' ')
            return b''
        device.ui, device.call = Mock(side_effect=ui), Mock(side_effect=call)
        failure = None
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]):
            try:
                device.type_consent_statement(statement)
            except smoke.Refused as error:
                failure = str(error)
        self.assertIsNone(failure)
        self.assertEqual(typed[0], statement)
        self.assertTrue(300 < elapsed[0] < 600)

    def test_zero_exit_dump_without_a_success_marker_cannot_reuse_an_old_tree(self):
        device = smoke.Device('adb', 1234, 'emulator-5554', {}, Path('/owned'), 'xc_safe_' + 'a' * 32)
        stale = b'<?xml version="1.0"?><hierarchy><node package="com.xclient.example.dev" text="STALE"/></hierarchy>'
        device.call = Mock(side_effect=lambda *args: b'' if args[:3] == ('shell', 'uiautomator', 'dump') else stale)
        failure = None
        with patch.object(smoke.time, 'sleep'):
            try:
                device.ui()
            except smoke.Refused as error:
                failure = str(error)
        self.assertEqual(failure, 'fresh_ui_dump_unconfirmed')
        self.assertTrue(all(call.args[:3] == ('shell', 'uiautomator', 'dump') for call in device.call.call_args_list))

    def test_each_confirmed_ui_dump_has_a_distinct_nonce_scoped_path(self):
        device = smoke.Device('adb', 1234, 'emulator-5554', {}, Path('/owned'), 'xc_safe_' + 'a' * 32)
        targets = []
        def call(*args):
            if args[:3] == ('shell', 'uiautomator', 'dump'):
                targets.append(args[-1])
                return ('UI hierchary dumped to: ' + args[-1] + '\n').encode()
            return b'<?xml version="1.0"?><hierarchy><node package="com.xclient.example.dev"/></hierarchy>'
        device.call = Mock(side_effect=call)
        device.ui()
        device.ui()
        self.assertEqual(len(set(targets)), 2)
        self.assertTrue(all('a' * 32 in target for target in targets))

    def test_a_dump_marker_for_a_different_file_never_grants_a_read(self):
        device = smoke.Device('adb', 1234, 'emulator-5554', {}, Path('/owned'), 'xc_safe_' + 'a' * 32)
        stale = b'<?xml version="1.0"?><hierarchy/>'
        device.call = Mock(side_effect=lambda *args: b'UI hierchary dumped to: /data/local/tmp/foreign.xml\n' if args[:3] == ('shell', 'uiautomator', 'dump') else stale)
        failure = None
        try:
            device.ui()
        except smoke.Refused as error:
            failure = str(error)
        self.assertEqual(failure, 'fresh_ui_dump_unconfirmed')
        self.assertEqual(device.call.call_count, 1)

    def test_an_anr_overlay_cannot_leave_an_underlying_field_eligible_for_typing(self):
        device = smoke.Device.__new__(smoke.Device)
        device.verify_owned, device.call = Mock(), Mock()
        device.ui = Mock(return_value=smoke.ET.fromstring('<hierarchy><node package="com.xclient.example.dev" class="android.widget.EditText" focused="true" enabled="true" text=""/><node package="android" class="android.widget.TextView" text="Pixel Launcher isn\'t responding"/></hierarchy>'))
        with self.assertRaisesRegex(smoke.Refused, 'visible_launcher_anr'):
            device.type_consent_statement('PUBLIC')
        device.call.assert_not_called()

    def test_consent_scrolling_is_bounded_and_refuses_foreign_or_changed_windows(self):
        xml = '<hierarchy><node package="com.xclient.example.dev" content-desc="Restate the statement"/><node package="com.xclient.example.dev" content-desc="Cancel"/><node package="com.xclient.example.dev" content-desc="Confirm"/><node package="com.xclient.example.dev" class="android.widget.ScrollView" scrollable="true" enabled="true" bounds="[10,100][300,500]"/></hierarchy>'
        for case in ('foreign', 'changed', 'stalled', 'bounds'):
            device = smoke.Device.__new__(smoke.Device)
            device.verify_owned, device.call = Mock(), Mock()
            device.native_capture = Mock(return_value={'width': 200 if case == 'bounds' else 320, 'height': 640})
            tree = smoke.ET.fromstring(xml)
            if case == 'foreign':
                tree[-1].set('package', 'com.android.settings')
            device.ui = Mock(return_value=tree)
            if case == 'changed':
                device.ui.side_effect = [tree, smoke.ET.fromstring('<node package="android" class="android.widget.TextView" text="Pixel Launcher isn\'t responding"/>')]
            with self.subTest(case=case), patch.object(smoke.time, 'sleep'), self.assertRaises(smoke.Refused):
                device.consent_field()
            if case == 'stalled':
                self.assertEqual(device.call.call_count, 4)
                self.assertEqual(len({call.args[0] for call in device.native_capture.call_args_list}), 4)
                self.assertTrue(all(call.args[:3] == ('shell', 'input', 'swipe') for call in device.call.call_args_list))
            else:
                device.call.assert_not_called()
            if case == 'foreign':
                device.native_capture.assert_not_called()

    def test_exact_but_late_consent_readback_cannot_pass_the_chunk_deadline(self):
        device = smoke.Device.__new__(smoke.Device)
        device.verify_owned = Mock()
        elapsed, typed, reads = [0], [''], [0]
        def ui():
            reads[0] += 1
            if reads[0] == 3:
                elapsed[0] += 60
            return smoke.ET.Element('node', {'class': 'android.widget.EditText', 'package': smoke.PACKAGE, 'focused': 'true', 'enabled': 'true', 'text': typed[0]})
        def call(*args):
            typed[0] += smoke.shlex.split(args[-1])[0]
            return b''
        device.ui, device.call = Mock(side_effect=ui), Mock(side_effect=call)
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), self.assertRaisesRegex(smoke.Refused, 'consent_input_progress_unconfirmed'):
            device.type_consent_statement('PUBLIC_STATEMENT')
        self.assertFalse(device.consent_progress['complete'])
        self.assertEqual(device.consent_progress['verified_prefix_length'], 0)
        self.assertEqual(device.call.call_count, 1)

    def test_verified_consent_progress_has_a_per_chunk_bound_despite_slow_ui_queries(self):
        device = smoke.Device.__new__(smoke.Device)
        elapsed, typed = [0], ['']
        statement = json.loads((smoke.ROOT / 'arb/intl_en.arb').read_text(encoding='utf-8'))['disclaimerNoServiceStatement']
        device.verify_owned = Mock()
        def ui():
            elapsed[0] += 2
            node = smoke.ET.Element('node', {'class': 'android.widget.EditText', 'package': smoke.PACKAGE, 'focused': 'true', 'enabled': 'true', 'text': typed[0]})
            return node
        def call(*args):
            typed[0] += smoke.shlex.split(args[-1])[0].replace('%s', ' ')
            return b''
        device.ui, device.call = Mock(side_effect=ui), Mock(side_effect=call)
        failure = None
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]):
            try:
                device.type_consent_statement(statement)
            except smoke.Refused as error:
                failure = str(error)
        self.assertIsNone(failure)
        self.assertEqual(typed[0], statement)
        self.assertGreater(elapsed[0], 90)

    def test_keyboard_clipped_consent_field_is_revealed_only_by_its_owned_scrollview(self):
        device = smoke.Device.__new__(smoke.Device)
        device.package = smoke.lifecycle_probe.PROFILE_PACKAGE
        device.verify_owned = Mock()
        hidden = smoke.ET.fromstring('<hierarchy><node package="com.xclient.example" content-desc="Restate the statement" enabled="true" /><node package="com.xclient.example" class="android.widget.ScrollView" scrollable="true" enabled="true" bounds="[184,255][896,765]"/><node package="com.xclient.example" content-desc="Cancel" enabled="true"/><node package="com.xclient.example" content-desc="Confirm" enabled="false"/></hierarchy>')
        typed, scrolled = '', False
        def ui():
            if not scrolled:
                return hidden
            tree = smoke.ET.Element('hierarchy')
            smoke.ET.SubElement(tree, 'node', {'class': 'android.widget.EditText', 'package': device.package, 'focused': 'true', 'enabled': 'true', 'text': typed})
            return tree
        def call(*args):
            nonlocal scrolled, typed
            if args[:3] == ('shell', 'input', 'swipe'):
                self.assertEqual(args[3:7], (540, 663, 540, 357))
                scrolled = True
            else:
                self.assertEqual(args[:3], ('shell', 'input', 'text'))
                typed += smoke.shlex.split(args[-1])[0].replace('%s', ' ')
            return b''
        device.ui, device.call = Mock(side_effect=ui), Mock(side_effect=call)
        device.native_capture = Mock(return_value={'width': 1080, 'height': 1920})
        failure = None
        try:
            device.type_consent_statement('PUBLIC STATEMENT')
        except smoke.Refused as error:
            failure = str(error)
        self.assertIsNone(failure)
        self.assertEqual(typed, 'PUBLIC STATEMENT')
        self.assertTrue(scrolled)
        self.assertEqual(device.native_capture.call_count, 1)

    def test_preinstall_failure_only_proves_absence_and_never_uninstalls_a_package(self):
        device = Mock(package=smoke.PACKAGE)
        device.call.return_value = b''
        self.assertEqual(smoke.cleanup_guest_app(device, False), {'app_uninstalled': False, 'app_absent_without_install': True})
        device.call.assert_called_once_with('shell', 'pm', 'list', 'packages', smoke.PACKAGE)
        device.call.reset_mock()
        device.call.return_value = ('package:' + smoke.PACKAGE + '\n').encode()
        with self.assertRaisesRegex(smoke.Refused, 'unexpected_preexisting_example_package'):
            smoke.cleanup_guest_app(device, False)
        device.call.assert_called_once_with('shell', 'pm', 'list', 'packages', smoke.PACKAGE)

    def test_attempted_install_cleanup_uses_only_the_fixed_owned_package(self):
        device = Mock(package=smoke.PACKAGE)
        device.call.side_effect = [b'', b'Success\n']
        self.assertEqual(smoke.cleanup_guest_app(device, True), {'app_uninstalled': True, 'app_absent_without_install': False})
        self.assertEqual([call.args for call in device.call.call_args_list], [('shell', 'am', 'force-stop', smoke.PACKAGE), ('uninstall', smoke.PACKAGE)])
        device.package = 'com.private.other'
        device.call.reset_mock()
        with self.assertRaises(smoke.Refused):
            smoke.cleanup_guest_app(device, True)
        device.call.assert_not_called()

    def test_launcher_readiness_requires_a_visible_resumed_home_and_a_quiet_window(self):
        device = smoke.Device.__new__(smoke.Device)
        elapsed = [0]
        launcher = smoke.ET.fromstring('<node package="com.google.android.apps.nexuslauncher" enabled="true" />')
        record = b'mResumedActivity: ActivityRecord{aa22 u0 com.google.android.apps.nexuslauncher/.NexusLauncherActivity t2}'
        clean = smoke.anr_observation(b'ACTIVITY MANAGER LAST ANR (dumpsys activity lastanr)\n  <no ANR has occurred since boot>\n', b'', smoke.PACKAGE)
        device.ui, device.verify_owned = Mock(return_value=launcher), Mock()
        device.observe_anr = Mock(return_value=clean)
        device.call = Mock(side_effect=lambda *args: record if args[-1] == 'activities' else b'stopped')
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), patch.object(smoke.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)):
            result = device.await_launcher(lambda: True)
        self.assertTrue(result['ready'])
        self.assertGreaterEqual(result['quiet_ms'], 8000)
        self.assertGreaterEqual(device.ui.call_count, 3)
        self.assertTrue(all(call.args[1] in ('dumpsys', 'getprop') for call in device.call.call_args_list))

    def test_preexisting_anr_or_changed_emulator_never_reaches_ui_actions(self):
        for owns, report, expected in ((False, {}, 'owned_emulator_identity_unconfirmed'), (True, {'last_anr_query_recognized': True, 'no_anr_since_boot_marker': False, 'recent_anr_owners': ['launcher']}, 'preexisting_system_anr'), (True, {'last_anr_query_recognized': False}, 'system_anr_state_unconfirmed')):
            device = smoke.Device.__new__(smoke.Device)
            device.verify_owned, device.ui, device.call = Mock(), Mock(), Mock()
            device.observe_anr = Mock(return_value=report)
            with self.subTest(expected=expected), self.assertRaisesRegex(smoke.Refused, expected):
                device.await_launcher(lambda: owns)
            device.ui.assert_not_called()
            device.call.assert_not_called()
            if not owns:
                device.observe_anr.assert_not_called()

    def test_anr_diagnostics_are_bounded_finite_and_do_not_leak_unknown_processes(self):
        raw = b'ANR in com.private.sensitive:worker\nReason: https://private.invalid/?token=PRIVATE\nANR in com.google.android.apps.nexuslauncher\nANR in com.xclient.example.dev\nANR in com.xclient.example.dev.other\n'
        result = smoke.anr_observation(b'ACTIVITY MANAGER LAST ANR (dumpsys activity lastanr)\nInput dispatching timed out\n', raw, smoke.PACKAGE)
        self.assertEqual(result['recent_anr_owners'], ['example', 'launcher', 'other'])
        self.assertTrue(result['input_dispatch_timeout'])
        self.assertFalse(result['no_anr_since_boot_marker'])
        self.assertNotIn('private', json.dumps(result))
        self.assertNotIn('PRIVATE', json.dumps(result))
        with self.assertRaises(smoke.Refused):
            smoke.anr_observation(b'x' * (2 * 1024 * 1024 + 1), b'', smoke.PACKAGE)
        unknown = smoke.anr_observation(b'Unknown command lastanr', b'', smoke.PACKAGE)
        self.assertFalse(unknown['last_anr_query_recognized'])

    def test_home_readiness_does_not_accept_app_text_or_a_running_boot_animation(self):
        tree = smoke.ET.fromstring('<hierarchy><node package="com.xclient.example.dev" class="android.widget.TextView" text="Pixel Launcher isn\'t responding" /></hierarchy>')
        report = smoke.launcher_observation(tree, b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t2}', b'running')
        self.assertIsNone(report['visible_anr_owner'])
        self.assertFalse(report['launcher_ui_visible'])
        self.assertFalse(report['launcher_resumed'])
        self.assertFalse(report['boot_animation_stopped'])

    def test_a_system_launcher_anr_is_refused_without_a_foreign_window_action(self):
        device = smoke.Device.__new__(smoke.Device)
        device.ui = Mock(return_value=smoke.ET.fromstring('<hierarchy><node package="android" class="android.widget.TextView" text="Pixel Launcher isn\'t responding" /></hierarchy>'))
        device.tap, device.call = Mock(), Mock()
        with patch.object(smoke.time, 'monotonic', side_effect=[0, 1, 200]), patch.object(smoke.time, 'sleep'), self.assertRaisesRegex(smoke.Refused, 'visible_launcher_anr'):
            device.await_login()
        device.tap.assert_not_called()
        device.call.assert_not_called()

    def test_an_app_anr_is_not_misclassified_as_the_system_launcher(self):
        device = smoke.Device.__new__(smoke.Device)
        device.ui = Mock(return_value=smoke.ET.fromstring('<hierarchy><node package="android" class="android.widget.TextView" text="ExampleClient isn\'t responding" /></hierarchy>'))
        device.tap, device.call = Mock(), Mock()
        with patch.object(smoke.time, 'monotonic', side_effect=[0, 1, 200]), patch.object(smoke.time, 'sleep'), self.assertRaisesRegex(smoke.Refused, 'visible_example_anr'):
            device.await_login()
        device.tap.assert_not_called()

    def test_stalled_consent_input_is_bounded_and_cannot_send_the_next_chunk(self):
        device = smoke.Device.__new__(smoke.Device)
        device.verify_owned, device.call = Mock(), Mock()
        device.ui = Mock(return_value=smoke.ET.fromstring('<node class="android.widget.EditText" package="com.xclient.example.dev" focused="true" enabled="true" text="" />'))
        elapsed = [0]
        with patch.object(smoke.time, 'monotonic', side_effect=lambda: elapsed[0]), patch.object(smoke.time, 'sleep', side_effect=lambda seconds: elapsed.__setitem__(0, elapsed[0] + seconds)), self.assertRaisesRegex(smoke.Refused, 'consent_input_progress_unconfirmed'):
            device.type_consent_statement('PUBLIC STATEMENT')
        self.assertEqual(device.call.call_count, 1)
    def test_public_consent_is_typed_in_small_verified_chunks_without_a_burst(self):
        statement = json.loads((smoke.ROOT / 'arb/intl_en.arb').read_text(encoding='utf-8'))['disclaimerNoServiceStatement']
        typed, chunks = '', []
        device = smoke.Device.__new__(smoke.Device)
        device.verify_owned = Mock()
        def ui():
            root = smoke.ET.Element('hierarchy')
            smoke.ET.SubElement(root, 'node', {'class': 'android.widget.EditText', 'package': smoke.PACKAGE, 'focused': 'true', 'enabled': 'true', 'text': typed})
            return root
        def call(*args):
            nonlocal typed
            self.assertEqual(args[:3], ('shell', 'input', 'text'))
            value = smoke.shlex.split(args[-1])[0].replace('%s', ' ')
            chunks.append(value)
            typed += value[:24]
            return b''
        device.ui, device.call = Mock(side_effect=ui), Mock(side_effect=call)
        device.type_consent_statement(statement)
        self.assertEqual(typed, statement)
        self.assertLessEqual(max(map(len, chunks)), 8)
        self.assertGreaterEqual(device.ui.call_count, len(chunks) + 1)

    def test_consent_input_never_overwrites_an_existing_or_foreign_field(self):
        for package, value in ((smoke.PACKAGE, 'existing value'), ('com.android.settings', '')):
            device = smoke.Device.__new__(smoke.Device)
            device.verify_owned, device.call = Mock(), Mock()
            node = smoke.ET.Element('node', {'class': 'android.widget.EditText', 'package': package, 'focused': 'true', 'enabled': 'true', 'text': value})
            device.ui = Mock(return_value=node)
            with self.assertRaises(smoke.Refused):
                device.type_consent_statement('PUBLIC')
            device.call.assert_not_called()
    def test_apk_identity_diagnostic_uses_only_fixed_package_classes(self):
        report = smoke.apk_metadata("package: name='SENSITIVE_UNEXPECTED_PACKAGE' versionCode='10000401'\napplication-debuggable\nlaunchable-activity: name='com.follow.clash.MainActivity'\n", 'profile')
        self.assertEqual(report['package'], 'other')
        self.assertEqual(report['expected_package'], 'com.xclient.example')
        self.assertTrue(report['debuggable'])
        self.assertNotIn('SENSITIVE', json.dumps(report))
    def test_profile_package_identity_is_exact_and_different_from_debug(self):
        valid = "package: name='com.xclient.example' versionCode='10000401' versionName='1.0.0'\napplication-debuggable\nlaunchable-activity: name='com.follow.clash.MainActivity'\n"
        smoke.validate_badging(valid, 'profile')
        with self.assertRaises(smoke.Refused):
            smoke.validate_badging(valid, 'debug')
        with self.assertRaises(smoke.Refused):
            smoke.validate_badging(valid.replace("example'", "example.dev'"), 'profile')

    def test_profile_device_scope_cannot_tap_a_debug_or_arbitrary_package(self):
        device = smoke.Device('adb', 1234, 'emulator-5554', {}, Path('/owned'), 'owned', package='com.xclient.example')
        device.call = Mock()
        node = smoke.ET.fromstring('<node package="com.xclient.example" bounds="[0,0][10,10]" />')
        device.tap(node)
        device.call.assert_called_once_with('shell', 'input', 'tap', 5, 5)
        node.set('package', 'com.xclient.example.dev')
        with self.assertRaises(smoke.Refused):
            device.tap(node)
        with self.assertRaises(smoke.Refused):
            smoke.Device('adb', 1234, 'emulator-5554', {}, Path('/owned'), 'owned', package='com.xclient.b98k')
    def test_cold_launch_metrics_are_recorded_once_and_never_overwritten_by_warm_reopen(self):
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            device = smoke.Device.__new__(smoke.Device)
            device.output = Path(directory)
            (device.output / 'receipts').mkdir()
            device.verify_owned = Mock()
            device.call = Mock(side_effect=[b'Status: ok\nWaitTime: 1234\nTotalTime: 1200\n', b'Status: ok\nWaitTime: 12\n'])
            device.start()
            device.start()
            report = json.loads((device.output / 'receipts/initial-launch.json').read_text())
            self.assertEqual(report['wait_time_ms'], 1234)
            self.assertEqual(report['total_time_ms'], 1200)
    def test_saved_ui_xml_redacts_all_editable_field_contents(self):
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            device = smoke.Device.__new__(smoke.Device)
            device.output = output
            device.ui = Mock(return_value=smoke.ET.fromstring('<hierarchy><node class="android.widget.EditText" text="PRIVATE_SYNTHETIC_INPUT" content-desc="PRIVATE_SYNTHETIC_INPUT" /></hierarchy>'))
            device.native_capture = Mock(return_value={'width': 1080, 'height': 1920})
            device.capture('failure-ui')
            self.assertNotIn('PRIVATE_SYNTHETIC_INPUT', (output / 'receipts/failure-ui.xml').read_text())
    def test_consent_diagnostic_records_only_length_and_known_statement_match(self):
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            device = smoke.Device.__new__(smoke.Device)
            device.output = output
            device.ui = Mock(return_value=smoke.ET.fromstring('<hierarchy><node class="android.widget.EditText" package="com.xclient.example.dev" text="PRIVATE_SYNTHETIC_INPUT" /></hierarchy>'))
            report = device.record_consent_input('PUBLIC_STATEMENT', b'mInputShown=true\n')
            self.assertEqual(report['input_length'], len('PRIVATE_SYNTHETIC_INPUT'))
            self.assertFalse(report['matches_expected_statement'])
            self.assertTrue(report['input_method_visible'])
            self.assertNotIn('PRIVATE_SYNTHETIC_INPUT', (output / 'receipts/consent-input.json').read_text())

    def test_profile_requires_real_aot_elf_and_debug_requires_the_jit_payload(self):
        header = b'\x7fELF\x02\x01' + bytes(12) + struct.pack('<H', 62)
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            file = Path(directory) / 'safe.apk'
            for mode in ('debug', 'profile'):
                with zipfile.ZipFile(file, 'w') as archive:
                    for library in ('libclash.so', 'libflutter.so'):
                        archive.writestr('lib/x86_64/' + library, header)
                    if mode == 'debug':
                        archive.writestr('assets/flutter_assets/kernel_blob.bin', b'jit')
                    else:
                        archive.writestr('lib/x86_64/libapp.so', header)
                smoke.validate_apk(file, mode)
                with self.assertRaises(smoke.Refused):
                    smoke.validate_apk(file, 'profile' if mode == 'debug' else 'debug')
                with self.assertRaises(smoke.Refused):
                    smoke.validate_apk(file, 'release')

    def test_mixed_jit_aot_and_a_foreign_architecture_aot_library_are_refused(self):
        header = b'\x7fELF\x02\x01' + bytes(12) + struct.pack('<H', 62)
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            file = Path(directory) / 'safe.apk'
            for mixed in (True, False):
                with zipfile.ZipFile(file, 'w') as archive:
                    for library in ('libclash.so', 'libflutter.so'):
                        archive.writestr('lib/x86_64/' + library, header)
                    archive.writestr('lib/x86_64/libapp.so', header if mixed else header[:18] + struct.pack('<H', 183))
                    if mixed:
                        archive.writestr('assets/flutter_assets/kernel_blob.bin', b'jit')
                with self.assertRaises(smoke.Refused):
                    smoke.validate_apk(file, 'profile')
    def test_consent_never_pops_the_dialog_when_the_software_keyboard_is_already_hidden(self):
        agree = smoke.ET.fromstring('<hierarchy><node text="Agree" enabled="true" package="com.xclient.example.dev" /></hierarchy>')
        field = smoke.ET.fromstring('<hierarchy><node class="android.widget.EditText" enabled="true" package="com.xclient.example.dev" /></hierarchy>')
        confirm = smoke.ET.fromstring('<node text="Confirm" enabled="true" package="com.xclient.example.dev" />')
        for visible in (True, False):
            device = Mock(spec=smoke.Device, package=smoke.PACKAGE)
            device.ui.side_effect = [agree, field]
            device.wait_label.return_value = (field, confirm)
            device.call.side_effect = lambda *args, **kwargs: ('mInputShown=' + str(visible).lower()).encode() if 'input_method' in args else b''
            device.record_consent_input.return_value = {'input_method_visible': visible}
            self.assertTrue(smoke.Device.disclaimer(device))
            backs = [call for call in device.call.call_args_list if 'KEYCODE_BACK' in call.args]
            self.assertEqual(len(backs), 1 if visible else 0)
            self.assertEqual(device.tap.call_args.args[0], confirm)

    def test_only_a_proved_late_normal_start_can_continue_without_confirming_fast_launch(self):
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            report = {'status': 'timeout', 'error_type': None, 'crash': {'owned_process_crash_seen': False}, 'late_startup': {'stages': ['bindingReady', 'rustReady', 'platformReady', 'bootstrapReady', 'trustReady', 'runApp']}, 'late_vm_startup': {'available': True, 'main_isolate_verified': True, 'owned_forward_cleanup': True}}
            file = output / 'receipts/launch-failure.json'
            device = Mock(spec=smoke.Device, output=output, package=smoke.PACKAGE)
            device.start.side_effect = smoke.Refused('app_launch_unconfirmed')
            file.write_text(json.dumps(report))
            self.assertFalse(smoke.initial_start(device))
            for changed in ({**report, 'status': 'unknown'}, {**report, 'error_type': 3}, {**report, 'late_startup': {'stages': ['initError']}}, {**report, 'late_vm_startup': {'available': False}}, {**report, 'crash': {'owned_process_crash_seen': True}}):
                file.write_text(json.dumps(changed))
                with self.assertRaises(smoke.Refused):
                    smoke.initial_start(device)
            device.start.side_effect = smoke.Refused('unexpected_guest_proxy')
            file.write_text(json.dumps(report))
            with self.assertRaisesRegex(smoke.Refused, 'unexpected_guest_proxy'):
                smoke.initial_start(device)

    def test_a_foreign_window_node_never_receives_a_tap(self):
        device = smoke.Device.__new__(smoke.Device)
        device.call = Mock()
        node = smoke.ET.fromstring('<node package="com.android.settings" bounds="[0,0][10,10]" />')
        with self.assertRaisesRegex(smoke.Refused, 'owned_app_ui_node_required'):
            device.tap(node)
        device.call.assert_not_called()

    def test_a_late_login_frame_after_am_timeout_is_diagnostic_and_never_a_pass(self):
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            output = Path(directory)
            (output / 'receipts').mkdir()
            device = Mock(spec=smoke.Device, output=output, package=smoke.PACKAGE)
            device.call.side_effect = lambda *args, **kwargs: b'Status: timeout\nWaitTime: 10000\n' if 'start' in args else b'[xclient-startup] runApp\n'
            device.native_capture.return_value = {'width': 1080, 'height': 1920, 'sha256': 'a' * 64}
            device.ui.return_value = smoke.parse_ui(b'<?xml version="1.0"?><hierarchy><node text="&#30331;&#24405;" content-desc="" enabled="true" /></hierarchy>')
            with patch.object(smoke.lifecycle_probe, 'guest_identity', return_value={'pid': 7, 'start': '100'}), patch.object(smoke.startup_probe, 'observe', return_value={'available': True, 'owned_forward_cleanup': True}), patch.object(smoke.time, 'sleep'), self.assertRaisesRegex(smoke.Refused, 'app_launch_unconfirmed'):
                smoke.Device.start(device)
            report = json.loads((output / 'receipts/launch-failure.json').read_text())
            self.assertEqual(report['status'], 'timeout')
            self.assertTrue(report['late_login_visible'])
            self.assertEqual(report['wait_time_ms'], 10000)
            device.tap.assert_not_called()

    def test_network_baseline_waits_for_ready_links_and_three_identical_snapshots(self):
        device = smoke.Device.__new__(smoke.Device)
        device.verify_owned = Mock()
        ready = {'links_sha256': 'a' * 64, 'proxy_sha256': 'b' * 64, 'interfaces': [{'name': name, 'state': 'UP', 'flags': ['UP', 'LOWER_UP']} for name in ('eth0', 'wlan0')]}
        down = {**ready, 'interfaces': [{'name': 'wlan0', 'state': 'DOWN', 'flags': ['UP', 'NO-CARRIER']}]}
        device.guest_network = Mock(side_effect=[down, ready, ready, ready])
        with patch.object(smoke.time, 'sleep'):
            self.assertEqual(device.await_network(lambda: True), ready)
        self.assertEqual(device.guest_network.call_count, 4)
        self.assertEqual(device.verify_owned.call_count, 4)

    def test_ready_wifi_does_not_hide_the_known_emulator_ethernet_startup_transition(self):
        device = smoke.Device.__new__(smoke.Device)
        device.verify_owned = Mock()
        ready = {'links_sha256': 'a' * 64, 'proxy_sha256': 'b' * 64, 'interfaces': [{'name': name, 'state': 'UP', 'flags': ['UP', 'LOWER_UP']} for name in ('eth0', 'wlan0')]}
        one_up = {**ready, 'interfaces': [{**ready['interfaces'][0], 'state': 'DOWN', 'flags': ['BROADCAST']}, ready['interfaces'][1]]}
        device.guest_network = Mock(side_effect=[one_up] * 3 + [ready] * 3)
        with patch.object(smoke.time, 'sleep'):
            self.assertEqual(device.await_network(lambda: True), ready)
        self.assertEqual(device.guest_network.call_count, 6)

    def test_network_wait_refuses_changed_emulator_ownership_before_reading_a_guest(self):
        device = smoke.Device.__new__(smoke.Device)
        device.guest_network = Mock()
        with self.assertRaisesRegex(smoke.Refused, 'owned_emulator_identity_unconfirmed'):
            device.await_network(lambda: False)
        device.guest_network.assert_not_called()

    def test_non_ci_refuses_before_creating_output(self):
        output = LAUNCHER.parents[3] / 'out' / 'android-emulator-local-refusal'
        self.assertFalse(output.exists())
        env = dict(os.environ)
        env.pop('GITHUB_ACTIONS', None)
        result = subprocess.run([sys.executable, str(LAUNCHER), 'prepare', '--output', str(output)], env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout), {'success': False, 'error': 'github_hosted_ci_required'})
        self.assertFalse(output.exists())

    def test_every_execution_entry_refuses_local_before_reading_state(self):
        for action in ('install-tools', 'build', 'run', 'export', 'import'):
            with self.subTest(action=action), patch.dict(os.environ, {}, clear=True):
                result = subprocess.run([sys.executable, str(LAUNCHER), action, '--state', 'missing-state.json'], capture_output=True, text=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(json.loads(result.stdout)['error'], 'github_hosted_ci_required')

    def test_self_hosted_and_non_manual_jobs_are_refused(self):
        env = dict(GITHUB_ACTIONS='true', RUNNER_ENVIRONMENT='self-hosted')
        with patch.dict(os.environ, env, clear=True), self.assertRaisesRegex(smoke.Refused, 'github_hosted_ci_required'):
            smoke.ci_identity()
        env.update(RUNNER_ENVIRONMENT='github-hosted', RUNNER_OS='Linux', GITHUB_EVENT_NAME='push')
        with patch.dict(os.environ, env, clear=True), patch.object(smoke.sys, 'platform', 'linux'), self.assertRaisesRegex(smoke.Refused, 'manual_safe_job_required'):
            smoke.ci_identity()

    def test_output_cannot_be_out_root_or_escape(self):
        for path in (smoke.ROOT / 'out', smoke.ROOT / 'test', smoke.ROOT / 'out/../outside'):
            with self.subTest(path=path), self.assertRaisesRegex(smoke.Refused, 'output_scope_rejected'):
                smoke.scoped(path)

    def test_badging_requires_exact_debug_package_and_launcher(self):
        valid = "package: name='com.xclient.example.dev' versionCode='10000401' versionName='1.0.0'\napplication-debuggable\nlaunchable-activity: name='com.follow.clash.MainActivity' label='Example'\n"
        smoke.validate_badging(valid)
        for invalid in (valid.replace('.example.dev', '.b98k'), valid.replace('10000401', '10000402'), valid.replace('application-debuggable', ''), valid.replace('MainActivity', 'OtherActivity')):
            with self.subTest(invalid=invalid), self.assertRaises(smoke.Refused):
                smoke.validate_badging(invalid)

    def test_actual_x64_runtime_libraries_are_required(self):
        header = b'\x7fELF\x02\x01' + bytes(12) + struct.pack('<H', 62)
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            apk = Path(directory) / 'fixture.apk'
            for machine, expect_pass in ((62, True), (183, False)):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('assets/flutter_assets/kernel_blob.bin', b'test')
                    for library in ('libclash.so', 'libflutter.so'):
                        archive.writestr('lib/x86_64/' + library, header[:18] + struct.pack('<H', machine))
                if expect_pass:
                    smoke.validate_apk(apk)
                else:
                    with self.assertRaisesRegex(smoke.Refused, 'actual_x64_elf_required'):
                        smoke.validate_apk(apk)

    def test_arm_only_and_mixed_flutter_apks_are_rejected(self):
        with tempfile.TemporaryDirectory(dir=LAUNCHER.parent) as directory:
            apk = Path(directory) / 'fixture.apk'
            header = b'\x7fELF\x02\x01' + bytes(12) + struct.pack('<H', 62)
            for arm_only in (True, False):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('assets/flutter_assets/kernel_blob.bin', b'test')
                    archive.writestr('lib/arm64-v8a/libflutter.so', header)
                    if not arm_only:
                        for library in ('libclash.so', 'libflutter.so'):
                            archive.writestr('lib/x86_64/' + library, header)
                with self.assertRaises(smoke.Refused):
                    smoke.validate_apk(apk)

    def test_png_requires_real_header_and_mobile_dimensions(self):
        valid = b'\x89PNG\r\n\x1a\n' + struct.pack('>I', 13) + b'IHDR' + struct.pack('>II', 1080, 1920)
        self.assertEqual(smoke.validate_png(valid)['width'], 1080)
        for invalid in (b'not png', valid[:16] + struct.pack('>II', 0, 1920), valid[:16] + struct.pack('>II', 100000, 1920)):
            with self.assertRaises(smoke.Refused):
                smoke.validate_png(invalid)

    def test_ui_actions_require_unique_enabled_exact_labels(self):
        tree = smoke.parse_ui(b'<?xml version="1.0"?><hierarchy><node text="Agree" enabled="true" bounds="[10,20][30,60]"/><node text="Disagree" enabled="true"/><node text="Agree" enabled="false"/></hierarchy>')
        nodes = smoke.labelled_nodes(tree, 'Agree')
        self.assertEqual(len(nodes), 1)
        self.assertEqual(smoke.node_center(nodes[0]), (20, 40))

    def test_successful_install_accepts_real_adb_prefix_but_no_failure(self):
        self.assertTrue(smoke.successful_install(b'Performing Non-Streamed Install\nSuccess\n'))
        self.assertFalse(smoke.successful_install(b'Failure [INSTALL_FAILED]\nSuccess'))
        self.assertFalse(smoke.successful_install(b''))

    def test_cleanup_refuses_changed_process_identity(self):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        with patch.object(smoke, 'process_matches', return_value=False):
            self.assertFalse(smoke.stop_owned(process, {'pid': 123, 'start': '1', 'exe': '/owned'}))
        process.terminate.assert_not_called()
        process.kill.assert_not_called()

    def test_guest_ownership_requires_nonce_name_and_sole_private_serial(self):
        device = smoke.Device('/sdk/adb', 12345, 'emulator-5554', {}, Path('/owned'), 'xc_safe_nonce')
        with patch.object(smoke, 'command', return_value=b'List of devices attached\nemulator-5554\tdevice\n'), patch.object(device, 'call', return_value=b'xc_safe_nonce\nOK\n'):
            device.verify_owned()
        with patch.object(smoke, 'command', return_value=b'List of devices attached\nemulator-5554\tdevice\n'), patch.object(device, 'call', return_value=b'other_avd\nOK\n'), self.assertRaisesRegex(smoke.Refused, 'emulator_avd_ownership_mismatch'):
            device.verify_owned()
        with patch.object(smoke, 'command', return_value=b'List of devices attached\nphysical-device\tdevice\nemulator-5554\tdevice\n'), patch.object(device, 'call') as native_call, self.assertRaisesRegex(smoke.Refused, 'unexpected_adb_inventory'):
            device.verify_owned()
        native_call.assert_not_called()

    def test_occupied_emulator_ports_are_refused_and_reservations_closed(self):
        from unittest.mock import Mock
        reservation = Mock()
        reservation.bind.side_effect = OSError()
        with patch.object(smoke.socket, 'socket', return_value=reservation), self.assertRaisesRegex(smoke.Refused, 'emulator_ports_already_in_use'):
            smoke.require_emulator_ports_free()
        reservation.close.assert_called_once()

    def test_sdk_failures_have_finite_classes_without_echoing_raw_details(self):
        for raw, expected in ((b'No space left on device', 'storage'), (b'License not accepted', 'license'), (b'Failed to find package unknown', 'packageUnavailable'), (b'Failed to download https://secret.invalid?token=private', 'network'), (b'Unrecognized failure secret', 'unknown')):
            self.assertEqual(smoke.sdk_failure_class(raw), expected)


class ApkFixture(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=LAUNCHER.parent)
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.root_patch = patch.object(smoke, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.output = self.root / 'out/android-emulator'
        (self.output / 'private').mkdir(parents=True)
        self.source = self.root / 'build/app/outputs/flutter-apk/app-debug.apk'
        self.source.parent.mkdir(parents=True)
        header = b'\x7fELF\x02\x01' + bytes(12) + struct.pack('<H', 62)
        with zipfile.ZipFile(self.source, 'w') as archive:
            archive.writestr('assets/flutter_assets/kernel_blob.bin', b'test')
            for library in ('libclash.so', 'libflutter.so'):
                archive.writestr('lib/x86_64/' + library, header)
        self.state = {'build_mode': 'debug', 'job': '123:1:android:' + 'a' * 40, 'nonce': 'b' * 32, 'prepared_ns': 1, 'defines_sha256': 'c' * 64, 'sources': {'lib/main.dart': 'd' * 64}}


class StagedApkTest(ApkFixture):
    def test_staged_copy_remains_valid_after_build_tree_is_removed(self):
        built = smoke.stage_apk(self.state, self.output, self.source, started_ns=0)
        self.assertEqual(Path(built['apk']), self.output / 'private/app-debug.apk')
        self.assertEqual(built['source_apk_sha256'], smoke.sha(self.source))
        shutil.rmtree(self.root / 'build')
        self.assertFalse(self.source.exists())
        apk = smoke.validate_staged_apk(self.state, self.output, built)
        self.assertEqual(smoke.sha(apk), built['apk_sha256'])

    def test_unscoped_source_and_existing_destination_are_refused(self):
        with self.assertRaisesRegex(smoke.Refused, 'fresh_build_apk_required'):
            smoke.stage_apk(self.state, self.output, self.root / 'other.apk', started_ns=0)
        target = self.output / 'private/app-debug.apk'
        target.write_bytes(b'do not overwrite')
        with self.assertRaisesRegex(smoke.Refused, 'new_staged_apk_required'):
            smoke.stage_apk(self.state, self.output, self.source, started_ns=0)
        self.assertEqual(target.read_bytes(), b'do not overwrite')

    def test_stale_build_and_changed_copy_source_are_refused(self):
        with self.assertRaisesRegex(smoke.Refused, 'fresh_build_apk_required'):
            smoke.stage_apk(self.state, self.output, self.source, started_ns=self.source.stat().st_mtime_ns)
        copy = shutil.copyfileobj

        def mutate_after_copy(source, destination, length):
            copy(source, destination, length)
            self.source.write_bytes(b'changed during copy')

        with patch.object(smoke.shutil, 'copyfileobj', side_effect=mutate_after_copy), self.assertRaisesRegex(smoke.Refused, 'staged_apk_hash_mismatch'):
            smoke.stage_apk(self.state, self.output, self.source, started_ns=0)

    def test_changed_job_nonce_source_defines_or_hook_state_is_refused(self):
        built = smoke.stage_apk(self.state, self.output, self.source, started_ns=0)
        changes = {'job': 'another-job', 'nonce': 'f' * 32, 'source_hashes': {}, 'defines_sha256': '0' * 64, 'native_hooks_enabled': False, 'apk': str(self.source), 'source_apk': str(self.root / 'other.apk')}
        for key, value in changes.items():
            with self.subTest(key=key), self.assertRaises(smoke.Refused):
                smoke.validate_staged_apk(self.state, self.output, dict(built, **{key: value}))

    def test_changed_staged_binary_cannot_be_installed(self):
        built = smoke.stage_apk(self.state, self.output, self.source, started_ns=0)
        (self.output / 'private/app-debug.apk').write_bytes(b'tampered')
        with self.assertRaisesRegex(smoke.Refused, 'staged_apk_hash_mismatch'):
            smoke.validate_staged_apk(self.state, self.output, built)

    def test_image_download_is_refused_before_sdk_access_for_wrong_job(self):
        built = smoke.stage_apk(self.state, self.output, self.source, started_ns=0)
        smoke.write_json(self.output / 'private/build.json', dict(built, job='another-job'))
        with patch.dict(os.environ, GITHUB_JOB='android-emulator'), patch.object(smoke, 'load_state', return_value=(self.state, self.output)), patch.object(smoke, 'sdk_tool') as tool, patch.object(smoke.subprocess, 'run') as execute:
            with self.assertRaisesRegex(smoke.Refused, 'staged_apk_owner_mismatch'):
                smoke.install_tools(argparse.Namespace(state='unused'))
        tool.assert_not_called()
        execute.assert_not_called()


class TransferApkTest(ApkFixture):
    def test_profile_transfer_preserves_mode_and_rejects_a_debug_consumer(self):
        self.state['build_mode'] = 'profile'
        self.source = self.source.with_name('app-profile.apk')
        header = b'\x7fELF\x02\x01' + bytes(12) + struct.pack('<H', 62)
        with zipfile.ZipFile(self.source, 'w') as archive:
            for library in ('libclash.so', 'libflutter.so', 'libapp.so'):
                archive.writestr('lib/x86_64/' + library, header)
        receipt = self.exported()
        self.assertEqual(receipt['build_mode'], 'profile')
        self.assertEqual(receipt['schema'], 2)
        self.assertEqual({file.name for file in (self.output / 'export').iterdir()}, {'app-profile.apk', 'build-receipt.json'})
        state, output = self.consumer()
        with self.assertRaises(smoke.Refused):
            smoke.validate_provenance({**state, 'build_mode': 'debug'}, receipt)
        with patch.object(smoke, 'load_state', return_value=(state, output)):
            smoke.import_apk(argparse.Namespace(state='unused'))
        built = json.loads((output / 'private/build.json').read_text())
        self.assertEqual(built['build_mode'], 'profile')
        self.assertEqual(Path(built['apk']).name, 'app-profile.apk')
        self.assertEqual(smoke.sha(smoke.validate_staged_apk(state, output, built)), receipt['apk_sha256'])

    def setUp(self):
        super().setUp()
        self.env = {'GITHUB_REPOSITORY': 'owner/example', 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': 'a' * 40, 'GITHUB_JOB': 'android-apk', 'XCLIENT_ANDROID_APK_ARTIFACT_ID': '456'}
        self.env_patch = patch.dict(os.environ, self.env, clear=True)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)
        self.state['job'] = '123:1:android-apk:' + 'a' * 40

    def exported(self):
        built = smoke.stage_apk(self.state, self.output, self.source, started_ns=0)
        smoke.write_json(self.output / 'private/build.json', built)
        with patch.object(smoke, 'load_state', return_value=(self.state, self.output)):
            smoke.export_apk(argparse.Namespace(state='unused'))
        return json.loads((self.output / 'export/build-receipt.json').read_text())

    def consumer(self):
        output = self.root / 'out/android-consumer'
        (output / 'private').mkdir(parents=True)
        (output / 'receipts').mkdir()
        shutil.copytree(self.output / 'export', output / 'incoming')
        os.environ['GITHUB_JOB'] = 'android-emulator'
        state = dict(self.state, output=str(output), job='123:1:android-emulator:' + 'a' * 40, nonce='e' * 32, prepared_ns=smoke.time.time_ns())
        return state, output

    def test_export_contains_only_two_files_and_no_private_identity(self):
        receipt = self.exported()
        self.assertEqual({path.name for path in (self.output / 'export').iterdir()}, {'app-debug.apk', 'build-receipt.json'})
        encoded = json.dumps(receipt)
        self.assertNotIn(self.state['nonce'], encoded)
        self.assertNotIn(str(self.output), encoded)
        self.assertNotIn('private', encoded)
        self.assertEqual(receipt['producer_job'], 'android-apk')
        self.assertEqual(receipt['repository'], 'owner/example')

    def test_import_rebinds_new_nonce_and_survives_producer_output_removal(self):
        self.exported()
        state, output = self.consumer()
        shutil.rmtree(self.output)
        shutil.rmtree(self.root / 'build')
        with patch.object(smoke, 'load_state', return_value=(state, output)):
            smoke.import_apk(argparse.Namespace(state='unused'))
        built = json.loads((output / 'private/build.json').read_text())
        self.assertEqual(built['nonce'], 'e' * 32)
        self.assertEqual(built['job'], state['job'])
        self.assertEqual(built['origin'], 'same-run-artifact')
        self.assertEqual(built['artifact_id'], '456')
        smoke.validate_staged_apk(state, output, built)

    def test_cross_repository_run_attempt_sha_producer_and_defines_are_rejected(self):
        receipt = self.exported()
        os.environ['GITHUB_JOB'] = 'android-emulator'
        changes = {'repository': 'other/project', 'run_id': '124', 'run_attempt': '2', 'sha': 'f' * 40, 'producer_job': 'untrusted-job', 'source_hashes': {}, 'defines_sha256': 'f' * 64, 'brand': '98k', 'version': '2.0.0', 'build_number': '10000402', 'package': 'other.package', 'target': 'android-arm64', 'apk_size': 0, 'apk_sha256': 'not-a-hash', 'schema': True, 'build_mode': 'profile'}
        for key, value in changes.items():
            with self.subTest(key=key), self.assertRaises(smoke.Refused):
                smoke.validate_provenance(self.state, dict(receipt, **{key: value}))

    def test_unknown_receipt_fields_and_false_native_checks_are_rejected(self):
        receipt = self.exported()
        with self.assertRaises(smoke.Refused):
            smoke.validate_provenance(self.state, dict(receipt, nonce='not-allowed'))
        for key in receipt['checks']:
            failed = dict(receipt, checks=dict(receipt['checks'], **{key: False}))
            with self.subTest(key=key), self.assertRaises(smoke.Refused):
                smoke.validate_provenance(self.state, failed)

    def test_extra_downloaded_file_and_tampered_apk_block_import(self):
        self.exported()
        state, output = self.consumer()
        extra = output / 'incoming/private-state.json'
        extra.write_text('{}')
        with patch.object(smoke, 'load_state', return_value=(state, output)), self.assertRaisesRegex(smoke.Refused, 'artifact_file_allowlist_required'):
            smoke.import_apk(argparse.Namespace(state='unused'))
        extra.unlink()
        (output / 'incoming/app-debug.apk').write_bytes(b'tampered')
        with patch.object(smoke, 'load_state', return_value=(state, output)), self.assertRaises(smoke.Refused):
            smoke.import_apk(argparse.Namespace(state='unused'))
        self.assertFalse((output / 'private/build.json').exists())

    def test_export_and_import_roles_and_artifact_id_cannot_be_omitted(self):
        self.exported()
        os.environ['GITHUB_JOB'] = 'other-job'
        with patch.object(smoke, 'load_state', return_value=(self.state, self.output)), self.assertRaises(smoke.Refused):
            smoke.export_apk(argparse.Namespace(state='unused'))
        state, output = self.consumer()
        os.environ['GITHUB_JOB'] = 'other-job'
        with patch.object(smoke, 'load_state', return_value=(state, output)), self.assertRaisesRegex(smoke.Refused, 'artifact_consumer_required'):
            smoke.import_apk(argparse.Namespace(state='unused'))
        os.environ['GITHUB_JOB'] = 'android-emulator'
        os.environ.pop('XCLIENT_ANDROID_APK_ARTIFACT_ID')
        with patch.object(smoke, 'load_state', return_value=(state, output)), self.assertRaises(smoke.Refused):
            smoke.import_apk(argparse.Namespace(state='unused'))

    def test_producer_local_receipt_cannot_be_used_directly_by_consumer(self):
        self.exported()
        built = json.loads((self.output / 'private/build.json').read_text())
        state, output = self.consumer()
        with self.assertRaisesRegex(smoke.Refused, 'staged_apk_owner_mismatch'):
            smoke.validate_staged_apk(state, output, built)

    def test_apk_native_validation_is_required_even_with_matching_transfer_hash(self):
        receipt = self.exported()
        state, output = self.consumer()
        apk = output / 'incoming/app-debug.apk'
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('assets/flutter_assets/kernel_blob.bin', b'not-native')
        receipt.update(apk_sha256=smoke.sha(apk), apk_size=apk.stat().st_size)
        (output / 'incoming/build-receipt.json').write_text(json.dumps(receipt))
        with patch.object(smoke, 'load_state', return_value=(state, output)), self.assertRaisesRegex(smoke.Refused, 'x64_runtime_library_required'):
            smoke.import_apk(argparse.Namespace(state='unused'))
        self.assertFalse((output / 'private/build.json').exists())

    def test_compile_and_emulation_cannot_accidentally_run_in_the_same_job(self):
        with patch.object(smoke, 'load_state', return_value=(self.state, self.output)), patch.object(smoke, 'sdk_tool') as tool:
            for action in (smoke.install_tools, smoke.run):
                with self.subTest(action=action.__name__), self.assertRaisesRegex(smoke.Refused, 'artifact_consumer_required'):
                    action(argparse.Namespace(state='unused'))
        tool.assert_not_called()
        os.environ['GITHUB_JOB'] = 'android-emulator'
        with patch.object(smoke, 'load_state', return_value=(self.state, self.output)), patch.object(smoke.subprocess, 'run') as execute, self.assertRaisesRegex(smoke.Refused, 'native_build_producer_required'):
            smoke.build(argparse.Namespace(state='unused'))
        execute.assert_not_called()


class InstalledApkPathTest(unittest.TestCase):
    def test_exact_package_random_directories_accept_the_standard_nested_parent(self):
        random = base64.urlsafe_b64encode(bytes(range(16))).decode()
        leaf = smoke.PACKAGE + '-' + random + '/base.apk'
        for directory, schema in (('/data/app/', 'flatRandom'), ('/data/app/~~' + random + '/', 'nestedRandom')):
            with self.subTest(schema=schema):
                path = directory + leaf
                self.assertEqual(smoke.installed_base_apk(('package:' + path + '\n').encode()), (path, schema))

    def test_noncanonical_or_unowned_install_paths_are_rejected(self):
        random = base64.urlsafe_b64encode(bytes(range(16))).decode()
        path = '/data/app/~~' + random + '/' + smoke.PACKAGE + '-' + random + '/base.apk'
        for invalid in (path.replace(smoke.PACKAGE, 'com.other.app'), path.replace('/~~', '/../'), path.replace('==', ''), path.replace('/base.apk', '/split.apk'), path + '/extra', 'data/app/' + smoke.PACKAGE + '-' + random + '/base.apk'):
            with self.subTest(invalid=invalid), self.assertRaises(smoke.Refused):
                smoke.installed_base_apk(('package:' + invalid).encode())

    def test_multiple_or_whitespace_pm_results_grant_no_path_authority(self):
        random = base64.urlsafe_b64encode(bytes(range(16))).decode()
        line = 'package:/data/app/' + smoke.PACKAGE + '-' + random + '/base.apk'
        for invalid in (line + '\n' + line, '\n' + line, ' ' + line, line + ' ', line + '\x00', line + '\npackage:/elsewhere/base.apk'):
            with self.subTest(invalid=invalid[-20:]), self.assertRaises(smoke.Refused):
                smoke.installed_base_apk(invalid.encode())


class EmulatorIdentityTest(unittest.TestCase):
    def test_link_diagnostic_preserves_policy_relevant_state_without_mac_addresses(self):
        data = '1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN mode DEFAULT group default link/loopback 00:00:00:00:00:00\n2: wlan0: <NO-CARRIER,BROADCAST,UP> mtu 1500 qdisc noop state DOWN mode DEFAULT group default link/ether SENSITIVE_ADDRESS\n'
        report = smoke.link_observation(data)
        self.assertEqual([item['name'] for item in report], ['lo', 'wlan0'])
        self.assertEqual(report[1]['state'], 'DOWN')
        self.assertNotIn('SENSITIVE', json.dumps(report))
        self.assertNotIn('00:00', json.dumps(report))

    def test_startup_probe_reports_only_known_stages_and_no_vm_auth_address(self):
        data = b'[xclient-startup] bindingReady\n[xclient-startup] SENSITIVE_VALUE\n[xclient-startup] rustReady\nThe Dart VM service is listening on http://127.0.0.1:5555/SENSITIVE_TOKEN=/\n'
        report = smoke.startup_observation(data)
        self.assertEqual(report['stages'], ['bindingReady', 'rustReady'])
        self.assertTrue(report['vm_service_announced'])
        self.assertNotIn('SENSITIVE', json.dumps(report))
        self.assertNotIn('5555', json.dumps(report))

    def test_native_stack_probe_exports_only_known_library_symbols(self):
        value = b' #00 pc 00000001 /SENSITIVE_PATH/libart.so (art::Thread::Wait+12)\n #01 pc 00000002 /SENSITIVE_PATH/libSENSITIVE.so (SENSITIVE_VALUE)\n'
        report = smoke.native_stack_observation(value)
        self.assertTrue(report['available'])
        self.assertEqual(len(report['recognized_frames']), 1)
        self.assertEqual(report['recognized_frames'][0]['library'], 'libart.so')
        self.assertNotIn('SENSITIVE', json.dumps(report))

    def test_launch_failure_diagnostics_keep_status_and_safe_words_without_raw_values(self):
        value = b'Starting: Intent { cmp=SENSITIVE_PACKAGE/SENSITIVE_CLASS }\nError type 3\nError: Activity class SENSITIVE_CLASS does not exist.\n'
        report = smoke.launch_observation(value)
        self.assertEqual(report['status'], 'unknown')
        self.assertEqual(report['error_type'], 3)
        self.assertIn('exist', report['message_words'])
        self.assertNotIn('SENSITIVE', json.dumps(report))
        self.assertEqual(smoke.launch_observation(b'Status: ok\n')['status'], 'ok')
        self.assertEqual(smoke.launch_observation(b'Status: timeout\n')['status'], 'timeout')

    def test_crash_diagnostic_exports_owned_classes_and_frames_without_messages(self):
        value = ('Process: ' + smoke.PACKAGE + ', PID: 321\njava.lang.RuntimeException: SENSITIVE_MESSAGE\nCaused by: java.lang.IllegalStateException: SENSITIVE_VALUE\n at com.follow.clash.MainActivity.onCreate(MainActivity.kt:42)\n').encode()
        report = smoke.crash_observation(value)
        self.assertTrue(report['owned_process_crash_seen'])
        self.assertIn('java.lang.IllegalStateException', report['exception_classes'])
        self.assertEqual(report['owned_frames'], [{'method': 'com.follow.clash.MainActivity.onCreate', 'file': 'MainActivity.kt', 'line': 42}])
        self.assertNotIn('SENSITIVE', json.dumps(report))
        self.assertFalse(smoke.crash_observation(value.replace(smoke.PACKAGE.encode(), b'com.someone.else'))['owned_process_crash_seen'])
        foreign = b'FATAL EXCEPTION: main\nProcess: com.someone.else, PID: 987\njava.lang.AssertionError: FOREIGN_MESSAGE\n'
        mixed = smoke.crash_observation(b'FATAL EXCEPTION: main\n' + value + foreign)
        self.assertNotIn('java.lang.AssertionError', mixed['exception_classes'])

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=LAUNCHER.parent)
        self.addCleanup(self.temporary.cleanup)
        self.sdk = Path(self.temporary.name).resolve()
        self.relative = {'launcher': 'emulator/emulator', 'qemuX64': 'emulator/qemu/linux-x86_64/qemu-system-x86_64', 'qemuX64Headless': 'emulator/qemu/linux-x86_64/qemu-system-x86_64-headless'}
        for name, relative in self.relative.items():
            path = self.sdk / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(('synthetic official candidate ' + name).encode())
        self.parent = os.getpid()
        self.identity = {'pid': 123, 'start': '100', 'ppid': self.parent, 'exe': str(self.sdk / self.relative['launcher'])}

    def test_headless_exec_retains_exact_popen_birth_and_pinned_image(self):
        images = smoke.snapshot_emulator_images(self.sdk)
        birth, owner, report = smoke.emulator_observation(self.identity, 123, None, images, self.sdk, self.parent)
        self.assertEqual(report['status'], 'verified')
        self.assertEqual(owner, self.identity)
        headless = dict(self.identity, exe=str(self.sdk / self.relative['qemuX64Headless']))
        next_birth, owner, report = smoke.emulator_observation(headless, 123, birth, images, self.sdk, self.parent)
        self.assertEqual(next_birth, birth)
        self.assertEqual(owner, headless)
        self.assertEqual(report['image_class'], 'qemuX64Headless')
        self.assertTrue(report['candidate_hash_matches'])

    def test_same_basename_at_another_sdk_path_is_not_an_owned_image(self):
        images = smoke.snapshot_emulator_images(self.sdk)
        unrelated = self.sdk / 'emulator/elsewhere/qemu-system-x86_64'
        unrelated.parent.mkdir()
        unrelated.write_bytes((self.sdk / self.relative['qemuX64']).read_bytes())
        identity = dict(self.identity, exe=str(unrelated))
        _, owner, report = smoke.emulator_observation(identity, 123, None, images, self.sdk, self.parent)
        self.assertIsNone(owner)
        self.assertEqual(report['observed_basename'], 'qemu-system-x86_64')
        self.assertEqual(report['image_class'], 'unknown')
        self.assertNotIn(str(self.sdk), json.dumps(report))

    def test_changed_start_pid_or_parent_cannot_reuse_the_birth_lease(self):
        images = smoke.snapshot_emulator_images(self.sdk)
        birth, _, _ = smoke.emulator_observation(self.identity, 123, None, images, self.sdk, self.parent)
        for changed in (dict(self.identity, start='101'), dict(self.identity, pid=124), dict(self.identity, ppid=self.parent + 1)):
            with self.subTest(changed=changed):
                _, owner, report = smoke.emulator_observation(changed, 123, birth, images, self.sdk, self.parent)
                self.assertIsNone(owner)
                self.assertNotEqual(report['status'], 'verified')

    def test_candidate_changed_after_prelaunch_hash_is_refused(self):
        images = smoke.snapshot_emulator_images(self.sdk)
        headless = self.sdk / self.relative['qemuX64Headless']
        headless.write_bytes(b'replaced after prelaunch')
        _, owner, report = smoke.emulator_observation(dict(self.identity, exe=str(headless)), 123, None, images, self.sdk, self.parent)
        self.assertIsNone(owner)
        self.assertEqual(report['status'], 'imageChanged')
        self.assertFalse(report['candidate_hash_matches'])

    def test_nonregular_sdk_candidates_are_not_hashed_or_accepted(self):
        target = self.sdk / self.relative['qemuX64Headless']
        target.unlink()
        target.mkdir()
        with self.assertRaisesRegex(smoke.Refused, 'regular_official_emulator_required'):
            smoke.snapshot_emulator_images(self.sdk)

    def test_cross_read_process_birth_race_is_refused(self):
        before = {'pid': 123, 'start': '100', 'ppid': self.parent}
        after = dict(before, start='101')
        with patch.object(smoke, 'process_stat', side_effect=[before, after]), patch.object(Path, 'resolve', return_value=self.sdk / self.relative['launcher']), self.assertRaisesRegex(smoke.Refused, 'process_birth_changed_during_read'):
            smoke.process_identity(123)

    def test_signal_escalation_rechecks_current_image_authority(self):
        from unittest.mock import Mock
        process = Mock()
        process.poll.return_value = None
        process.wait.side_effect = subprocess.TimeoutExpired('owned', 15)
        verify = Mock(side_effect=[True, False])
        self.assertFalse(smoke.stop_owned(process, self.identity, verify=verify))
        process.terminate.assert_called_once()
        process.kill.assert_not_called()

    def test_unknown_basename_never_leaves_memory_in_diagnostics(self):
        images = smoke.snapshot_emulator_images(self.sdk)
        _, owner, report = smoke.emulator_observation(dict(self.identity, exe='/outside/secret-url-token-credential'), 123, None, images, self.sdk, self.parent)
        self.assertIsNone(owner)
        self.assertEqual(report['observed_basename'], 'unknown')
        self.assertNotIn('secret', json.dumps(report))


if __name__ == '__main__':
    unittest.main()
