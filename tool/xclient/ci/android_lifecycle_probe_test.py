import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
import android_lifecycle_probe as probe


def event(token, tag, second=1, pid=321):
    return f'179377700{second}.123456 {pid} {pid} I {tag}: [{token},com.follow.clash.MainActivity,performTest,0]'


def vm(main_id='isolates/1', start=123):
    isolate = {'type': '@Isolate', 'id': main_id, 'number': '1', 'name': 'main', 'isSystemIsolate': False, 'isolateGroupId': 'isolateGroups/2'}
    return {'result': {'type': 'VM', 'pid': 321, 'startTime': start, 'isolates': [isolate]}}


class ProofTest(unittest.TestCase):
    def test_vm_discovery_filters_the_owned_buffer_without_the_stale_300_line_tail(self):
        device = Mock(package=probe.PROFILE_PACKAGE)
        def messages(*args):
            return b'' if '-t' in args else b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
        device.call.side_effect = messages
        test = probe.LifecycleProbe(device)
        test.guest = {'pid': 321, 'start': '100'}
        test.same_guest = Mock()
        with patch.object(probe, 'VmChannel') as channel:
            channel.return_value.read.return_value = {'owned': True}
            result = test.connect()
        self.assertEqual(result, {'owned': True})
        args = device.call.call_args.args
        self.assertIn('--pid=321', args)
        self.assertIn('--regex=Dart.VM.service.is.listening.on', args)
        self.assertNotIn('-t', args)
        channel.return_value.read.assert_called_once_with(321)
        self.assertGreaterEqual(test.same_guest.call_count, 2)
        self.assertNotIn('abcdefgh123', json.dumps(test.report))
        self.assertNotIn('4567', json.dumps(test.report))

    def test_vm_address_query_remains_bounded_and_rejects_a_changed_guest_before_forwarding(self):
        for oversized, changed in ((True, False), (False, True)):
            device = Mock(package=probe.PROFILE_PACKAGE)
            device.call.return_value = b'x' * (16 * 1024 + 1) if oversized else b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
            test = probe.LifecycleProbe(device)
            test.guest = {'pid': 321, 'start': '100'}
            test.same_guest = Mock(side_effect=[None, probe.ProofRefused('guest_process_changed')] if changed else None)
            with patch.object(probe, 'VmChannel') as channel, self.assertRaises(probe.ProofRefused):
                test.connect()
            channel.assert_not_called()
            self.assertNotIn('abcdefgh123', json.dumps(test.report))

    def test_profile_guest_identity_reads_only_its_exact_package(self):
        fields = ['S', '1'] + ['0'] * 17 + ['100'] + ['0'] * 5
        stat = ('7 (app) ' + ' '.join(fields)).encode()
        device = Mock(package='com.xclient.example')
        device.call.side_effect = [b'7', stat, b'7', stat]
        self.assertEqual(probe.guest_identity(device), {'pid': 7, 'start': '100'})
        for call in device.call.call_args_list:
            self.assertIn('com.xclient.example', call.args)
            self.assertNotIn('com.xclient.example.dev', call.args)
    def test_profile_activity_records_are_matched_only_to_the_profile_package(self):
        raw = b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example/com.follow.clash.MainActivity t5}'
        self.assertEqual(probe.resumed_record(raw, package='com.xclient.example'), 'aa22')
        self.assertFalse(probe.activities_absent(raw, package='com.xclient.example'))
        self.assertTrue(probe.activities_absent(raw, package='com.xclient.example.dev'))
        with self.assertRaises(probe.ProofRefused):
            probe.resumed_record(raw, package='com.xclient.example.dev')
    def test_service_uri_accepts_only_an_authenticated_local_debug_endpoint(self):
        self.assertEqual(probe.service_address(b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'), (4567, '/abcdefgh123=/'))
        for uri in ('http://example.invalid:4567/abcdefgh123=/', 'http://127.0.0.1:4567/', 'http://u@127.0.0.1:4567/abcdefgh123=/', 'http://127.0.0.1:4567/abcdefgh123=/?rpc=kill', 'https://127.0.0.1:4567/abcdefgh123=/', 'http://127.0.0.1:99999/abcdefgh123=/'):
            with self.subTest(uri=uri), self.assertRaises(probe.ProofRefused) as raised:
                probe.service_address(('The Dart VM service is listening on ' + uri).encode())
            self.assertNotIn(uri, str(raised.exception))

    def test_guest_birth_never_uses_the_host_emulator_identity(self):
        fields = ['S', '1'] + ['0'] * 17 + ['100'] + ['0'] * 5
        self.assertEqual(probe.parse_guest_stat(('321 (some process) ' + ' '.join(fields)).encode(), 321), {'pid': 321, 'start': '100'})
        with self.assertRaises(probe.ProofRefused):
            probe.parse_guest_stat(('322 (some process) ' + ' '.join(fields)).encode(), 321)

    def test_vm_rejects_foreign_pid_and_ambiguous_main_isolates(self):
        self.assertEqual(probe.vm_snapshot(vm(), 321)['main']['id'], 'isolates/1')
        response = vm()
        response['result']['pid'] = 322
        with self.assertRaises(probe.ProofRefused):
            probe.vm_snapshot(response, 321)
        response = vm()
        response['result']['isolates'].append(dict(response['result']['isolates'][0], id='isolates/3'))
        with self.assertRaises(probe.ProofRefused):
            probe.vm_snapshot(response, 321)

    def test_lifecycle_callbacks_use_only_the_owned_client_identifier_family(self):
        raw = '\n'.join([event(11, 'wm_on_create_called'), event(11, 'wm_on_resume_called', 2), event(999, 'wm_on_create_called', 2, 777)]).encode()
        events = probe.activity_events(raw, 321)
        self.assertEqual(probe.current_activity(events), 11)
        after = probe.activity_events(raw + ('\n' + event(12, 'wm_on_create_called', 3) + '\n' + event(11, 'wm_on_destroy_called', 4) + '\n' + event(12, 'wm_on_resume_called', 5)).encode(), 321)
        self.assertEqual(probe.current_activity(after), 12)
        self.assertEqual([item['token'] for item in probe.events_after(events, after) if item['tag'] == 'destroy'], [11])
        with self.assertRaises(probe.ProofRefused):
            probe.events_after(events, after[1:])

    def test_a_server_destroy_request_or_hide_is_not_a_client_destroy_callback(self):
        raw = (event(11, 'wm_on_create_called') + '\n' + event(11, 'wm_on_resume_called', 2) + '\n1793777003.123456 321 321 I wm_destroy_activity: [0,11,1,com.xclient.example.dev/com.follow.clash.MainActivity,finish]').encode()
        self.assertEqual(probe.current_activity(probe.activity_events(raw, 321)), 11)

    def test_resumed_record_and_absence_are_scoped_to_the_exact_package(self):
        raw = b'  mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t5}\n'
        self.assertEqual(probe.resumed_record(raw), 'aa22')
        self.assertFalse(probe.activities_absent(raw))
        self.assertTrue(probe.activities_absent(raw.replace(b'com.xclient.example.dev/', b'com.somewhere.else/')))

    def test_forward_refuses_an_existing_mapping_and_never_removes_a_replacement(self):
        device = Mock(serial='emulator-5554')
        device.call.return_value = b'emulator-5554 tcp:1234 tcp:5678\n'
        channel = probe.VmChannel(device, (4567, '/abcdefgh123=/'))
        with self.assertRaises(probe.ProofRefused):
            channel.open()
        self.assertFalse(any('--remove' in call.args for call in device.call.call_args_list))
        device.call.side_effect = [b'', b'1234\n', b'emulator-5554 tcp:1234 tcp:4567\n', b'emulator-5554 tcp:1234 tcp:9999\n']
        channel.open()
        with self.assertRaises(probe.ProofRefused):
            channel.close()
        self.assertFalse(any('--remove' in call.args for call in device.call.call_args_list))

    def test_rpc_uses_only_getvm_loopback_without_proxy_or_redirect_following(self):
        device = Mock(serial='emulator-5554')
        channel = probe.VmChannel(device, (4567, '/abcdefgh123=/'))
        channel.local = 1234
        device.call.return_value = b'emulator-5554 tcp:1234 tcp:4567\n'
        response = Mock(status=302)
        response.read.return_value = b'location secret URL'
        connection = Mock()
        connection.getresponse.return_value = response
        with patch.object(probe.http.client, 'HTTPConnection', return_value=connection) as http, self.assertRaises(probe.VmUnavailable):
            channel.read(321)
        http.assert_called_once_with('127.0.0.1', 1234, timeout=3)
        self.assertEqual(connection.request.call_args.args, ('GET', '/abcdefgh123=/getVM'))
        connection.close.assert_called_once()

    def test_uncertain_forward_creation_cannot_claim_cleanup_without_a_lease(self):
        device = Mock(serial='emulator-5554')
        device.call.side_effect = [b'', b'unknown allocated port\n']
        channel = probe.VmChannel(device, (4567, '/abcdefgh123=/'))
        with self.assertRaises(probe.ProofRefused):
            channel.open()
        with self.assertRaises(probe.ProofRefused):
            channel.close()
        self.assertFalse(any('--remove' in call.args for call in device.call.call_args_list))


class OrchestrationTest(unittest.TestCase):
    def setUp(self):
        self.device = Mock(serial='emulator-5554', package=probe.PACKAGE)
        self.test = probe.LifecycleProbe(self.device)
        self.test.guest = {'pid': 321, 'start': '100'}
        self.test.same_guest = Mock()
        self.test.channel = Mock()
        self.original = probe.vm_snapshot(vm(), 321)
        self.test.channel.read.return_value = self.original
        self.before = probe.activity_events((event(11, 'wm_on_create_called') + '\n' + event(11, 'wm_on_resume_called', 2)).encode(), 321)
        self.destroyed = self.before + probe.activity_events(event(11, 'wm_on_destroy_called', 4).replace('performTest', 'performDestroy').encode(), 321)
        self.reopened = self.destroyed + probe.activity_events((event(12, 'wm_on_create_called', 5) + '\n' + event(12, 'wm_on_resume_called', 6)).encode(), 321)
        self.device.capture.return_value = {'width': 1080, 'height': 1920, 'sha256': 'a' * 64}
        self.device.wait_label.return_value = (None, Mock())

    def test_replacement_waits_for_the_new_resume_after_the_real_old_destroy(self):
        pending = self.before + probe.activity_events((event(12, 'wm_on_create_called', 3) + '\n' + event(11, 'wm_on_destroy_called', 4).replace('performTest', 'performDestroy')).encode(), 321)
        after = pending + probe.activity_events(event(12, 'wm_on_resume_called', 5).encode(), 321)
        self.test.events = Mock(side_effect=[self.before, pending, after])
        self.test.record = Mock(side_effect=[b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t5}', b'mResumedActivity: ActivityRecord{bb33 u0 com.xclient.example.dev/com.follow.clash.MainActivity t6}'])
        self.device.call.return_value = b'Status: ok\n'
        with patch.object(probe.time, 'sleep'):
            self.test.replace(1, self.original)
        self.assertEqual(len(self.test.report['replacements']), 1)
        self.assertEqual(self.test.events.call_count, 3)
        self.assertIn('0x10008000', self.device.call.call_args.args)

    def test_replacement_cannot_accept_a_fresh_main_isolate_under_the_same_process(self):
        self.test.events = Mock(return_value=self.before)
        self.test.record = Mock(return_value=b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t5}')
        self.device.call.return_value = b'Status: ok\n'
        self.test.channel.read.return_value = probe.vm_snapshot(vm('isolates/99'), 321)
        with self.assertRaisesRegex(probe.ProofRefused, 'main_isolate_changed_during_replacement'):
            self.test.replace(1, self.original)
        self.assertEqual(self.test.report['replacements'], [])

    def test_a_changed_main_records_which_part_moved_without_any_identifier(self):
        self.test.events = Mock(return_value=self.before)
        self.test.record = Mock(return_value=b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t5}')
        self.device.call.return_value = b'Status: ok\n'
        self.device.ui.return_value = ET.fromstring('<hierarchy><node text="请输入邮箱" /><node text="登录" /></hierarchy>')
        changed = vm('isolates/99')
        changed['result']['isolates'].append({'type': '@Isolate', 'id': 'isolates/7', 'name': 'vm-service', 'isSystemIsolate': True})
        self.test.channel.read.return_value = probe.vm_snapshot(changed, 321)
        with self.assertRaisesRegex(probe.ProofRefused, '^main_isolate_changed_during_replacement$'):
            self.test.replace(1, self.original)
        change = self.test.report['main_change']
        self.assertGreaterEqual(change.pop('ms_since_launch'), 0)
        self.assertEqual(change, {
            'vm_start_changed': False, 'main_id_changed': True, 'main_number_changed': False, 'main_group_changed': False,
            'original': {'isolate_count': 1, 'non_system_isolate_count': 1, 'system_flag_missing_count': 0, 'main_named_count': 1},
            'observed': {'isolate_count': 2, 'non_system_isolate_count': 1, 'system_flag_missing_count': 0, 'main_named_count': 1},
            'replacement': 1, 'observation': 1, 'validation_hint_visible': True,
        })
        self.assertNotIn('isolates/', json.dumps(self.test.report))
        self.assertNotIn('isolateGroups/', json.dumps(self.test.report))

    def test_a_main_change_seen_only_after_the_replacement_names_that_observation(self):
        after = self.reopened
        self.test.events = Mock(side_effect=[self.before, after, after])
        self.test.record = Mock(side_effect=[b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t5}', b'mResumedActivity: ActivityRecord{bb33 u0 com.xclient.example.dev/com.follow.clash.MainActivity t6}'])
        self.device.call.return_value = b'Status: ok\n'
        self.device.ui.side_effect = probe.ProofRefused('ui_unavailable')
        self.test.channel.read.side_effect = [self.original, probe.vm_snapshot(vm(start=456), 321)]
        with patch.object(probe.time, 'sleep'), self.assertRaisesRegex(probe.ProofRefused, '^main_isolate_changed_during_replacement$'):
            self.test.replace(2, self.original)
        change = self.test.report['main_change']
        self.assertEqual({key: change[key] for key in ('vm_start_changed', 'main_id_changed', 'replacement', 'observation', 'validation_hint_visible')}, {'vm_start_changed': True, 'main_id_changed': False, 'replacement': 2, 'observation': 2, 'validation_hint_visible': None})
        self.assertEqual(self.test.report['replacements'], [])

    def test_isolate_counts_show_a_main_named_isolate_the_filter_skipped(self):
        response = vm()
        response['result']['isolates'] += [
            {'type': '@Isolate', 'id': 'isolates/5', 'name': 'main', 'number': '5', 'isolateGroupId': 'isolateGroups/6'},
            {'type': '@Isolate', 'id': 'isolates/7', 'name': 'vm-service', 'isSystemIsolate': True},
        ]
        snapshot = probe.vm_snapshot(response, 321)
        self.assertEqual(snapshot['main']['id'], 'isolates/1')
        self.assertEqual({key: snapshot[key] for key in ('isolate_count', 'non_system_isolate_count', 'system_flag_missing_count', 'main_named_count')}, {'isolate_count': 3, 'non_system_isolate_count': 1, 'system_flag_missing_count': 1, 'main_named_count': 2})

    def quit_fixture(self, reopened):
        self.test.events = Mock(side_effect=[self.before, self.destroyed, self.destroyed, self.reopened])
        self.test.record = Mock(return_value=b'mResumedActivity: ActivityRecord{cc44 u0 com.android.launcher/.Launcher t1}')
        self.test.channel.read.side_effect = probe.VmUnavailable('vm_endpoint_unavailable')
        self.test.connect = Mock(return_value=reopened)
        self.test.quit_button = Mock(return_value=Mock())

    def test_quit_socket_close_alone_cannot_make_a_generation_pass(self):
        self.quit_fixture(self.original)
        with patch.object(probe.time, 'sleep'), self.assertRaisesRegex(probe.ProofRefused, 'explicit_quit_fresh_generation_unconfirmed'):
            self.test.quit_and_reopen(self.original)
        self.assertIsNone(self.test.report['quit']['old_isolate_absent_before_reopen'])
        self.assertTrue(self.test.report['quit']['vm_endpoint_unavailable_after_quit'])
        self.assertNotIn('new_main_identity_verified', self.test.report['quit'])
        self.device.start.assert_called_once()

    def test_quit_reopen_uses_observed_new_vm_namespace_when_opaque_ids_repeat(self):
        self.quit_fixture(probe.vm_snapshot(vm(start=124), 321))
        with patch.object(probe.time, 'sleep'):
            self.test.quit_and_reopen(self.original)
        self.assertTrue(self.test.report['quit']['new_vm_instance_verified'])
        self.assertTrue(self.test.report['quit']['old_isolate_identity_absent_after_reopen'])
        self.assertFalse(self.test.report['quit']['new_main_id_differs'])

    def test_failed_ownership_cleanup_stays_red_and_drops_raw_errors(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).parent) as directory:
            self.device.output = Path(directory)
            (self.device.output / 'receipts').mkdir()
            self.test.connect = Mock(side_effect=OSError('PRIVATE_AUTH_TOKEN'))
            self.test.channel.close.side_effect = OSError('PRIVATE_AUTH_TOKEN')
            with patch.object(probe, 'guest_identity', return_value=self.test.guest):
                result = self.test.run()
            self.assertFalse(result['success'])
            self.assertFalse(result['vm_forward_cleanup'])
            self.assertNotIn('PRIVATE_AUTH_TOKEN', json.dumps(result))
            self.assertEqual(json.loads((self.device.output / 'receipts/lifecycle.json').read_text()), result)

    def test_offscreen_quit_is_scrolled_and_reobserved_before_it_can_be_tapped(self):
        def tree(bounds):
            return ET.fromstring('<hierarchy><node text="登录"/><node class="android.widget.EditText"/><node class="android.widget.EditText"/><node text="退出客户端" enabled="true" bounds="' + bounds + '"/></hierarchy>')
        self.test.record = Mock(return_value=b'mResumedActivity: ActivityRecord{aa22 u0 com.xclient.example.dev/com.follow.clash.MainActivity t5}')
        self.device.ui.side_effect = [tree('[10,2000][500,2100]'), tree('[10,1700][500,1800]')]
        button = self.test.quit_button()
        self.assertEqual(button.get('bounds'), '[10,1700][500,1800]')
        self.assertEqual(self.device.ui.call_count, 2)
        self.device.call.assert_called_once_with('shell', 'input', 'swipe', 540, 1440, 540, 640, '350')
        self.device.tap.assert_not_called()


if __name__ == '__main__':
    unittest.main()
