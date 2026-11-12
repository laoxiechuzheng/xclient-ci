import ctypes
import hashlib
import json
import os
import re
import time

import native_store_smoke as guard


def accessibility_available():
    library = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
    query = library.AXIsProcessTrusted
    query.argtypes = []
    query.restype = ctypes.c_bool
    return bool(query())


def confirmation_job():
    job = guard.ci_identity('macos')
    guard.require(os.environ.get('GITHUB_WORKFLOW') == 'xclient-native-qa' and os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch' and os.environ.get('GITHUB_JOB') == 'desktop-update', 'manual_owned_confirmation_job_required')
    return job


def select_dialog(snapshot, label, service):
    guard.require(re.fullmatch(r'xclient-qa-data-[0-9a-f]{12}', label) is not None and service == 'com.xclient.q' + label[-12:] + '.secure-storage', 'confirmation_scope_invalid')
    nodes = snapshot['nodes']
    guard.require(isinstance(nodes, list) and 0 < len(nodes) <= 256, 'bounded_confirmation_nodes_required')
    texts = [node['text'] for node in nodes if node['role'] == 'AXStaticText']
    text = '\n'.join(texts)
    token = lambda value: re.search(r'(?<![A-Za-z0-9_.-])' + re.escape(value) + r'(?![A-Za-z0-9_-]|\.[A-Za-z0-9_-])', text) is not None
    named_keychain = any(token(value) for value in (label, label + '.keychain', label + '.keychain-db'))
    guard.require(named_keychain and token(service) and token('ExampleClient') and re.search(r'\blogin\b', text, re.I) is None, 'owned_confirmation_dialog_not_matched')
    fields = [node for node in nodes if (node['role'] == 'AXSecureTextField' or (node['role'] == 'AXTextField' and node['subrole'] == 'AXSecureTextField')) and node['enabled'] is True]
    buttons = [node for node in nodes if node['role'] == 'AXButton' and node['text'] == 'Always Allow']
    guard.require(len(fields) == 1 and len(buttons) == 1, 'unique_owned_confirmation_controls_required')
    identity = [(node['role'], node['subrole'], node['text'] if node['role'] in ('AXStaticText', 'AXButton', 'AXWindow', 'AXSheet') else '') for node in nodes]
    return {'window': snapshot['window'], 'field': fields[0]['ref'], 'button': buttons[0]['ref'], 'button_enabled': buttons[0]['enabled'], 'fingerprint': hashlib.sha256(json.dumps(identity, ensure_ascii=True).encode()).hexdigest()}


class Session:
    def __init__(self, pid):
        confirmation_job()
        guard.require(accessibility_available(), 'accessibility_permission_unavailable')
        self.pid = pid
        self.references = []
        self.deadline = time.monotonic() + 3
        self.cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        self.ax = ctypes.CDLL('/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices')
        ref, index = ctypes.c_void_p, ctypes.c_long
        signatures = {
            'CFRelease': ([ref], None), 'CFEqual': ([ref, ref], ctypes.c_bool),
            'CFGetTypeID': ([ref], ctypes.c_ulong), 'CFStringGetTypeID': ([], ctypes.c_ulong),
            'CFStringCreateWithCString': ([ref, ctypes.c_char_p, ctypes.c_uint], ref),
            'CFStringGetLength': ([ref], index), 'CFStringGetCString': ([ref, ref, index, ctypes.c_uint], ctypes.c_bool),
            'CFArrayGetTypeID': ([], ctypes.c_ulong), 'CFArrayGetCount': ([ref], index),
            'CFArrayGetValueAtIndex': ([ref, index], ref), 'CFBooleanGetTypeID': ([], ctypes.c_ulong),
            'CFBooleanGetValue': ([ref], ctypes.c_bool),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.cf, name)
            function.argtypes, function.restype = args, result
        signatures = {
            'AXUIElementCreateApplication': ([ctypes.c_int], ref),
            'AXUIElementSetMessagingTimeout': ([ref, ctypes.c_float], ctypes.c_int),
            'AXUIElementCopyAttributeValue': ([ref, ref, ctypes.POINTER(ref)], ctypes.c_int),
            'AXUIElementGetPid': ([ref, ctypes.POINTER(ctypes.c_int)], ctypes.c_int),
            'AXUIElementIsAttributeSettable': ([ref, ref, ctypes.POINTER(ctypes.c_bool)], ctypes.c_int),
            'AXUIElementSetAttributeValue': ([ref, ref, ref], ctypes.c_int),
            'AXUIElementPerformAction': ([ref, ref], ctypes.c_int),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.ax, name)
            function.argtypes, function.restype = args, result
        self.root = self._own(self.ax.AXUIElementCreateApplication(pid))
        try:
            guard.require(self.root is not None, 'security_agent_accessibility_unavailable')
            guard.require(self.ax.AXUIElementSetMessagingTimeout(self.root, 0.3) == 0, 'security_agent_timeout_setup_failed')
        except Exception:
            self.close()
            raise

    def _own(self, value):
        if value is not None:
            self.references.append(value)
        return value

    def _key(self, value):
        return self._own(self.cf.CFStringCreateWithCString(None, value.encode('utf-8'), 0x08000100))

    def _attribute(self, element, name):
        guard.require(time.monotonic() <= self.deadline, 'bounded_accessibility_observation_expired')
        value = ctypes.c_void_p()
        status = self.ax.AXUIElementCopyAttributeValue(element, self._key(name), ctypes.byref(value))
        return self._own(value.value) if status == 0 and value.value is not None else None

    def _string(self, value):
        if value is None or self.cf.CFGetTypeID(value) != self.cf.CFStringGetTypeID():
            return ''
        length = self.cf.CFStringGetLength(value)
        guard.require(0 <= length <= 8192, 'bounded_accessibility_text_required')
        buffer = ctypes.create_string_buffer(length * 4 + 1)
        guard.require(self.cf.CFStringGetCString(value, buffer, len(buffer), 0x08000100), 'accessibility_text_unreadable')
        return buffer.value.decode('utf-8')

    def _array(self, value):
        if value is None:
            return []
        guard.require(self.cf.CFGetTypeID(value) == self.cf.CFArrayGetTypeID(), 'accessibility_array_unreadable')
        count = self.cf.CFArrayGetCount(value)
        guard.require(0 <= count <= 256, 'bounded_accessibility_array_required')
        return [self.cf.CFArrayGetValueAtIndex(value, index) for index in range(count)]

    def _boolean(self, value):
        return value is not None and self.cf.CFGetTypeID(value) == self.cf.CFBooleanGetTypeID() and bool(self.cf.CFBooleanGetValue(value))

    def tree(self, window):
        queue, nodes = [(window, 0)], []
        while queue:
            element, depth = queue.pop(0)
            guard.require(len(nodes) < 256 and depth <= 10, 'bounded_confirmation_tree_required')
            role = self._string(self._attribute(element, 'AXRole'))
            subrole = self._string(self._attribute(element, 'AXSubrole'))
            secure = role == 'AXSecureTextField' or subrole == 'AXSecureTextField'
            text = ''
            if role == 'AXStaticText':
                text = self._string(self._attribute(element, 'AXValue')) or self._string(self._attribute(element, 'AXTitle')) or self._string(self._attribute(element, 'AXDescription'))
            elif role in ('AXButton', 'AXWindow', 'AXSheet'):
                text = self._string(self._attribute(element, 'AXTitle')) or self._string(self._attribute(element, 'AXDescription'))
            nodes.append({'ref': element, 'role': role, 'subrole': subrole, 'text': text, 'enabled': self._boolean(self._attribute(element, 'AXEnabled'))})
            if not secure and role != 'AXTextField':
                queue.extend((child, depth + 1) for child in self._array(self._attribute(element, 'AXChildren')))
        return {'window': window, 'nodes': nodes}

    def snapshots(self):
        self.deadline = time.monotonic() + 2
        windows = self._array(self._attribute(self.root, 'AXWindows'))
        guard.require(len(windows) <= 8, 'bounded_confirmation_windows_required')
        return [self.tree(window) for window in windows]

    def same(self, one, two):
        return bool(self.cf.CFEqual(one, two))

    def owned_element(self, element):
        pid = ctypes.c_int()
        guard.require(self.ax.AXUIElementGetPid(element, ctypes.byref(pid)) == 0 and pid.value == self.pid, 'confirmation_element_owner_changed')

    def can_set_password(self, element):
        self.owned_element(element)
        value = ctypes.c_bool()
        return self.ax.AXUIElementIsAttributeSettable(element, self._key('AXValue'), ctypes.byref(value)) == 0 and bool(value.value)

    def set_password(self, element, password):
        self.owned_element(element)
        guard.require(re.fullmatch('[0-9a-f]{64}', password) is not None, 'owned_confirmation_password_invalid')
        guard.require(self.ax.AXUIElementSetAttributeValue(element, self._key('AXValue'), self._key(password)) == 0, 'owned_secure_field_write_failed')

    def press(self, element):
        self.owned_element(element)
        guard.require(self.ax.AXUIElementPerformAction(element, self._key('AXPress')) == 0, 'owned_confirmation_press_failed')

    def close(self):
        for reference in reversed(self.references):
            self.cf.CFRelease(reference)
        self.references.clear()


def reobserve(session, selected, label, service):
    matches = []
    for snapshot in session.snapshots():
        try:
            current = select_dialog(snapshot, label, service)
        except guard.Refused as error:
            if str(error) == 'owned_confirmation_dialog_not_matched':
                continue
            raise
        if session.same(selected['window'], current['window']):
            matches.append(current)
    guard.require(len(matches) == 1 and matches[0]['fingerprint'] == selected['fingerprint'], 'owned_confirmation_window_changed')
    return matches[0]


def confirm_dialog(session, selected, label, service, *, check_owner, password_supplier, claim_attempt, before_action):
    guard.require(check_owner() is True, 'confirmation_owner_unconfirmed')
    selected = reobserve(session, selected, label, service)
    guard.require(session.can_set_password(selected['field']), 'owned_secure_field_not_settable')
    guard.require(before_action() is True, 'owned_confirmation_capture_unavailable')
    guard.require(check_owner() is True, 'confirmation_owner_unconfirmed')
    selected = reobserve(session, selected, label, service)
    guard.require(session.can_set_password(selected['field']), 'owned_secure_field_not_settable')
    claim_attempt()
    value = password_supplier()
    guard.require(check_owner() is True, 'confirmation_owner_unconfirmed')
    selected = reobserve(session, selected, label, service)
    session.set_password(selected['field'], value)
    value = None
    current = reobserve(session, selected, label, service)
    guard.require(current['button_enabled'] is True, 'owned_confirmation_button_disabled')
    guard.require(check_owner() is True, 'confirmation_owner_unconfirmed')
    current = reobserve(session, current, label, service)
    guard.require(current['button_enabled'] is True, 'owned_confirmation_button_disabled')
    session.press(current['button'])
    return {'confirmation_action_performed': True, 'owned_window_rechecked': True, 'owned_secure_field_only': True, 'password_value_read': False, 'permission_requested': False}
