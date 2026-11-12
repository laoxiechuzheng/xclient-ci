import importlib.util
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('macos_keychain_ax', Path(__file__).with_name('macos_keychain_ax.py'))
ax = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ax)


def dialog(text=None):
    return {'window': 1, 'nodes': [
        {'ref': 2, 'role': 'AXStaticText', 'subrole': '', 'text': text or 'ExampleClient wants com.xclient.qaaaaaaaaaaaa.secure-storage. Enter the xclient-qa-data-aaaaaaaaaaaa keychain password.', 'enabled': True},
        {'ref': 3, 'role': 'AXTextField', 'subrole': 'AXSecureTextField', 'text': '', 'enabled': True},
        {'ref': 4, 'role': 'AXButton', 'subrole': '', 'text': 'Always Allow', 'enabled': False},
        {'ref': 5, 'role': 'AXButton', 'subrole': '', 'text': 'Deny', 'enabled': True},
    ]}


class DialogGuardTest(unittest.TestCase):
    def select(self, value):
        return ax.select_dialog(value, 'xclient-qa-data-aaaaaaaaaaaa', 'com.xclient.qaaaaaaaaaaaa.secure-storage')

    def test_only_the_exact_owned_service_and_data_keychain_can_select_a_secure_field(self):
        selected = self.select(dialog())
        self.assertEqual(selected['field'], 3)
        self.assertEqual(selected['button'], 4)
        self.assertEqual(len(selected['fingerprint']), 64)
        for text in ('ExampleClient login keychain com.xclient.qaaaaaaaaaaaa.secure-storage', 'ExampleClient xclient-qa-data-aaaaaaaaaaaa com.xclient.qbbbbbbbbbbbb.secure-storage', 'ExampleClient xclient-qa-data-aaaaaaaaaaaa-other com.xclient.qaaaaaaaaaaaa.secure-storage', 'ExampleClient xclient-qa-data-aaaaaaaaaaaa com.xclient.qaaaaaaaaaaaa.secure-storage-other'):
            with self.subTest(text=text), self.assertRaises(ax.guard.Refused):
                self.select(dialog(text))

    def test_plain_or_ambiguous_password_fields_and_duplicate_allow_buttons_are_refused(self):
        for kind in ('plain', 'twoFields', 'twoButtons', 'disabledField'):
            value = dialog()
            if kind == 'plain':
                value['nodes'][1]['subrole'] = ''
            elif kind == 'twoFields':
                value['nodes'].append({**value['nodes'][1], 'ref': 6})
            elif kind == 'twoButtons':
                value['nodes'].append({**value['nodes'][2], 'ref': 7})
            else:
                value['nodes'][1]['enabled'] = False
            with self.subTest(kind=kind), self.assertRaises(ax.guard.Refused):
                self.select(value)

    def test_fingerprint_never_reads_a_field_value_and_allows_the_button_to_enable(self):
        first = dialog()
        second = dialog()
        second['nodes'][1]['text'] = 'SENSITIVE_PASSWORD_MUST_BE_IGNORED'
        second['nodes'][2]['enabled'] = True
        self.assertEqual(self.select(first)['fingerprint'], self.select(second)['fingerprint'])

    def test_native_tree_never_queries_value_or_children_of_any_text_field(self):
        for subrole in ('AXSecureTextField', ''):
            session = ax.Session.__new__(ax.Session)
            requested = []
            def attribute(element, name):
                requested.append(name)
                return {'AXRole': 'AXTextField', 'AXSubrole': subrole, 'AXEnabled': True}.get(name)
            session._attribute = attribute
            session._string = lambda value: value or ''
            session._boolean = bool
            session._array = lambda value: value or []
            self.assertEqual(session.tree(3)['nodes'][0]['text'], '')
            self.assertNotIn('AXValue', requested)
            self.assertNotIn('AXChildren', requested)

    def test_confirmation_rechecks_scope_and_owner_before_each_narrow_action(self):
        first, after = dialog(), dialog()
        after['nodes'][2]['enabled'] = True
        session = Mock()
        session.snapshots.side_effect = lambda: [after if session.set_password.called else first]
        session.same.side_effect = lambda one, two: one == two
        session.can_set_password.return_value = True
        calls = []
        result = ax.confirm_dialog(session, self.select(first), 'xclient-qa-data-aaaaaaaaaaaa', 'com.xclient.qaaaaaaaaaaaa.secure-storage', check_owner=lambda: calls.append('owner') or True, password_supplier=lambda: calls.append('password') or 'a' * 64, claim_attempt=lambda: calls.append('claim'), before_action=lambda: calls.append('capture') or True)
        self.assertTrue(result['confirmation_action_performed'])
        self.assertLess(calls.index('capture'), calls.index('claim'))
        self.assertLess(calls.index('claim'), calls.index('password'))
        session.set_password.assert_called_once_with(3, 'a' * 64)
        session.press.assert_called_once_with(4)

    def test_changed_window_or_non_settable_field_cannot_read_the_test_password(self):
        for changed in (True, False):
            session = Mock()
            session.snapshots.return_value = [dialog()]
            session.same.return_value = not changed
            session.can_set_password.return_value = False
            supplier, claim = Mock(), Mock()
            with self.subTest(changed=changed), self.assertRaises(ax.guard.Refused):
                ax.confirm_dialog(session, self.select(dialog()), 'xclient-qa-data-aaaaaaaaaaaa', 'com.xclient.qaaaaaaaaaaaa.secure-storage', check_owner=lambda: True, password_supplier=supplier, claim_attempt=claim, before_action=lambda: True)
            supplier.assert_not_called()
            claim.assert_not_called()
            session.set_password.assert_not_called()
            session.press.assert_not_called()

    def test_window_changing_during_capture_prevents_password_loading(self):
        session = Mock()
        session.snapshots.side_effect = [[dialog()], [dialog('ExampleClient login keychain')]]
        session.same.side_effect = lambda one, two: one == two
        session.can_set_password.return_value = True
        supplier, claim = Mock(), Mock()
        with self.assertRaises(ax.guard.Refused):
            ax.confirm_dialog(session, self.select(dialog()), 'xclient-qa-data-aaaaaaaaaaaa', 'com.xclient.qaaaaaaaaaaaa.secure-storage', check_owner=lambda: True, password_supplier=supplier, claim_attempt=claim, before_action=lambda: True)
        supplier.assert_not_called()
        claim.assert_not_called()
        session.set_password.assert_not_called()
        session.press.assert_not_called()

    def test_failed_owner_check_prevents_even_a_valid_dialog_from_receiving_input(self):
        session, supplier, claim = Mock(), Mock(), Mock()
        with self.assertRaises(ax.guard.Refused):
            ax.confirm_dialog(session, self.select(dialog()), 'xclient-qa-data-aaaaaaaaaaaa', 'com.xclient.qaaaaaaaaaaaa.secure-storage', check_owner=lambda: False, password_supplier=supplier, claim_attempt=claim, before_action=lambda: True)
        session.snapshots.assert_not_called()
        session.set_password.assert_not_called()
        session.press.assert_not_called()
        supplier.assert_not_called()
        claim.assert_not_called()


if __name__ == '__main__':
    unittest.main()
