import json
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).parent))
import android_startup_probe as probe


class StartupProbeTest(unittest.TestCase):
    def test_startup_workers_may_change_while_the_same_main_isolate_is_observed(self):
        guest = {'pid': 321, 'start': '100'}
        vm = {'pid': 321, 'vm_start': 1000, 'main': {'id': 'isolates/1', 'number': '1', 'isolateGroupId': 'isolateGroups/1'}, 'isolate_ids': ['isolates/1']}
        channel = Mock()
        channel.read.side_effect = [vm, {**vm, 'isolate_ids': ['isolates/1', 'isolates/worker']}]
        isolate = {'type': 'Isolate', 'id': 'isolates/1', 'name': 'main', 'runnable': True, 'pauseEvent': {'kind': 'Resume'}}
        messages = b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
        with patch.object(probe.guard, 'VmChannel', return_value=channel), patch.object(probe.guard, 'guest_identity', return_value=guest), patch.object(probe, 'read_only_rpc', side_effect=[isolate, {'type': 'Stack', 'frames': []}]):
            report = probe.observe(Mock(), guest, messages)
        self.assertTrue(report['available'])
        self.assertTrue(report['other_isolates_changed'])
        self.assertTrue(report['owned_forward_cleanup'])

    def test_a_recomputed_vm_startTime_alone_does_not_change_the_vm(self):
        guest = {'pid': 321, 'start': '100'}
        vm = {'pid': 321, 'vm_start': 1000, 'main': {'id': 'isolates/1', 'number': '1', 'isolateGroupId': 'isolateGroups/1'}, 'isolate_ids': ['isolates/1']}
        isolate = {'type': 'Isolate', 'id': 'isolates/1', 'name': 'main'}
        messages = b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
        for start in (1001, 999, 6000):
            channel = Mock()
            channel.read.side_effect = [vm, {**vm, 'vm_start': start}]
            with patch.object(probe.guard, 'VmChannel', return_value=channel), patch.object(probe.guard, 'guest_identity', return_value=guest), patch.object(probe, 'read_only_rpc', side_effect=[isolate, {'type': 'Stack'}]):
                report = probe.observe(Mock(), guest, messages)
            self.assertTrue(report['available'], start)
            self.assertIsNone(report['error_class'])

    def test_changed_vm_pid_or_main_isolate_is_still_refused(self):
        guest = {'pid': 321, 'start': '100'}
        vm = {'pid': 321, 'vm_start': 1000, 'main': {'id': 'isolates/1', 'number': '1', 'isolateGroupId': 'isolateGroups/1'}, 'isolate_ids': ['isolates/1']}
        isolate = {'type': 'Isolate', 'id': 'isolates/1', 'name': 'main'}
        messages = b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
        for changed in ({**vm, 'pid': 999}, {**vm, 'main': {**vm['main'], 'id': 'isolates/2'}}, {**vm, 'main': {**vm['main'], 'number': '2'}}, {**vm, 'main': {**vm['main'], 'isolateGroupId': 'isolateGroups/2'}}):
            channel = Mock()
            channel.read.side_effect = [vm, changed]
            with patch.object(probe.guard, 'VmChannel', return_value=channel), patch.object(probe.guard, 'guest_identity', return_value=guest), patch.object(probe, 'read_only_rpc', side_effect=[isolate, {'type': 'Stack'}]):
                report = probe.observe(Mock(), guest, messages)
            self.assertFalse(report['available'])
            self.assertEqual(report['error_class'], 'startup_vm_changed')
            self.assertTrue(report['owned_forward_cleanup'])

    def test_only_public_startup_frames_are_reported_without_values_or_private_uris(self):
        frame = {'kind': 'AsyncCausal', 'function': {'name': 'RustLib.init'}, 'location': {'script': {'uri': 'package:rust_api/src/rust/frb_generated.dart'}, 'line': 33}, 'vars': [{'name': 'secret', 'value': {'valueAsString': 'SENSITIVE'}}]}
        stack = {'type': 'Stack', 'frames': [frame, {**frame, 'function': {'name': 'SECRET_FUNCTION'}, 'location': {'script': {'uri': 'file:///PRIVATE_SOURCE.dart'}}}], 'asyncCausalFrames': [frame], 'truncated': False}
        isolate = {'type': 'Isolate', 'id': 'isolates/1', 'name': 'main', 'runnable': True, 'pauseEvent': {'kind': 'Resume'}, 'libraries': [{'uri': 'SENSITIVE'}]}
        value = probe.summary(isolate, stack, 'isolates/1')
        self.assertEqual(value['pause_kind'], 'Resume')
        self.assertEqual(value['frames'][0]['function'], 'RustLib.init')
        self.assertNotIn('SENSITIVE', json.dumps(value))
        self.assertNotIn('PRIVATE_SOURCE', json.dumps(value))
        self.assertNotIn('SECRET_FUNCTION', json.dumps(value))

    def test_read_only_rpc_refuses_any_other_method_or_isolate_before_http(self):
        channel = Mock(local=1234, auth='/abcdefgh123=/')
        for method, isolate in [('evaluate', 'isolates/1'), ('getStack', 'isolates/1&method=resume'), ('resume', 'isolates/1')]:
            with self.subTest(method=method), patch.object(probe.http.client, 'HTTPConnection') as connection, self.assertRaises(probe.guard.ProofRefused):
                probe.read_only_rpc(channel, method, isolate)
            connection.assert_not_called()

    def test_rpc_uses_the_owned_forward_no_redirect_and_bounded_response(self):
        channel = Mock(local=1234, auth='/abcdefgh123=/')
        response = Mock(status=302)
        connection = Mock()
        connection.getresponse.return_value = response
        with patch.object(probe.http.client, 'HTTPConnection', return_value=connection) as create, self.assertRaises(probe.guard.VmUnavailable):
            probe.read_only_rpc(channel, 'getStack', 'isolates/1')
        create.assert_called_once_with('127.0.0.1', 1234, timeout=3)
        self.assertEqual(connection.request.call_args.args, ('GET', '/abcdefgh123=/getStack?isolateId=isolates%2F1&limit=32'))
        channel.verify.assert_called_once_with()
        connection.close.assert_called_once_with()

    def test_foreign_isolate_and_unbounded_frame_lists_are_refused(self):
        for isolate, stack in [({'type': 'Isolate', 'id': 'isolates/2', 'name': 'main'}, {'type': 'Stack'}), ({'type': 'Isolate', 'id': 'isolates/1', 'name': 'main'}, {'type': 'Stack', 'frames': [{}] * 65})]:
            with self.assertRaises(probe.guard.ProofRefused):
                probe.summary(isolate, stack, 'isolates/1')

    def test_stack_timeout_preserves_isolate_state_and_still_removes_only_the_owned_forward(self):
        guest = {'pid': 321, 'start': '100'}
        device, channel = Mock(), Mock()
        channel.read.return_value = {'main': {'id': 'isolates/1'}}
        isolate = {'type': 'Isolate', 'id': 'isolates/1', 'name': 'main', 'runnable': True, 'pauseEvent': {'kind': 'Resume'}}
        messages = b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
        with patch.object(probe.guard, 'VmChannel', return_value=channel), patch.object(probe.guard, 'guest_identity', return_value=guest), patch.object(probe, 'read_only_rpc', side_effect=[isolate, probe.guard.VmUnavailable('startup_rpc_unavailable')]):
            report = probe.observe(device, guest, messages)
        self.assertFalse(report['available'])
        self.assertTrue(report['isolate_state_observed'])
        self.assertEqual(report['pause_kind'], 'Resume')
        self.assertFalse(report['stack_observed'])
        self.assertTrue(report['owned_forward_cleanup'])
        channel.close.assert_called_once_with()

    def test_changed_guest_prevents_rpc_and_cannot_claim_forward_cleanup(self):
        guest = {'pid': 321, 'start': '100'}
        channel = Mock()
        messages = b'The Dart VM service is listening on http://127.0.0.1:4567/abcdefgh123=/\n'
        with patch.object(probe.guard, 'VmChannel', return_value=channel), patch.object(probe.guard, 'guest_identity', return_value={**guest, 'start': '200'}), patch.object(probe, 'read_only_rpc') as read:
            report = probe.observe(Mock(), guest, messages)
        self.assertFalse(report['available'] or report['owned_forward_cleanup'])
        read.assert_not_called()
        channel.open.assert_not_called()
        channel.close.assert_not_called()


if __name__ == '__main__':
    unittest.main()
