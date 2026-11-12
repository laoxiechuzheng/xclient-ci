import hashlib
import http.client
import json
import re
import time

PACKAGE = 'com.xclient.example.dev'
PROFILE_PACKAGE = 'com.xclient.example'
SAFE_PACKAGES = (PACKAGE, PROFILE_PACKAGE)
ACTIVITY = 'com.follow.clash.MainActivity'
MAX_RESPONSE = 512 * 1024


class ProofRefused(Exception):
    pass


class VmUnavailable(Exception):
    pass


def require(condition, code):
    if not condition:
        raise ProofRefused(code)


def private_text(data, maximum=MAX_RESPONSE):
    require(isinstance(data, bytes) and len(data) <= maximum, 'bounded_private_observation_required')
    return data.decode('utf-8', errors='strict')


def service_address(data):
    lines = [line.strip() for line in private_text(data).splitlines() if 'Dart VM service is listening on ' in line]
    require(bool(lines), 'owned_vm_address_unavailable')
    match = re.fullmatch(r'(?:The )?Dart VM service is listening on http://127\.0\.0\.1:([1-9]\d{0,4})(/[A-Za-z0-9_-]{8,128}={0,2}/)', lines[-1])
    require(match is not None and int(match[1]) <= 65535, 'owned_vm_address_rejected')
    return int(match[1]), match[2]


def parse_guest_stat(data, pid):
    text = private_text(data, 8192)
    fields = text[text.rfind(')') + 2:].split()
    require(re.match(str(pid) + r' \([^\r\n]*\) ', text) is not None and len(fields) >= 20 and fields[19].isdigit(), 'guest_process_birth_unconfirmed')
    return {'pid': pid, 'start': fields[19]}


def guest_identity(device):
    package = device.package
    require(package in SAFE_PACKAGES, 'owned_example_package_required')
    def pidof():
        raw = device.call('shell', 'pidof', package).strip()
        require(re.fullmatch(rb'[1-9]\d*', raw) is not None, 'single_guest_app_process_required')
        return int(raw)

    pid = pidof()
    first = parse_guest_stat(device.call('shell', 'run-as', package, 'cat', '/proc/' + str(pid) + '/stat'), pid)
    require(pidof() == pid, 'guest_process_changed')
    require(parse_guest_stat(device.call('shell', 'run-as', package, 'cat', '/proc/' + str(pid) + '/stat'), pid) == first, 'guest_process_changed')
    return first


def vm_snapshot(response, pid, *, allow_empty=False):
    result = response.get('result') if isinstance(response, dict) else None
    require(isinstance(result, dict) and result.get('type') == 'VM' and type(result.get('pid')) is int and result['pid'] == pid and type(result.get('startTime')) is int and result['startTime'] > 0, 'owned_vm_identity_unconfirmed')
    isolates = result.get('isolates')
    require(isinstance(isolates, list) and len(isolates) <= 64, 'bounded_vm_isolates_required')
    for item in isolates:
        require(isinstance(item, dict) and item.get('type') == '@Isolate' and isinstance(item.get('id'), str) and re.fullmatch(r'isolates/[A-Za-z0-9_-]{1,128}', item['id']) is not None and isinstance(item.get('name'), str), 'vm_isolate_reference_rejected')
    mains = [item for item in isolates if item['name'] == 'main' and item.get('isSystemIsolate') is False]
    require(len(mains) == 1 or (allow_empty and not mains), 'single_main_isolate_required')
    main = None
    if mains:
        item = mains[0]
        require(isinstance(item.get('number'), str) and item['number'].isdigit() and isinstance(item.get('isolateGroupId'), str) and re.fullmatch(r'isolateGroups/[A-Za-z0-9_-]{1,128}', item['isolateGroupId']) is not None, 'main_isolate_identity_unconfirmed')
        main = {key: item[key] for key in ('id', 'number', 'isolateGroupId')}
    return {
        'pid': pid, 'vm_start': result['startTime'], 'main': main, 'isolate_ids': [item['id'] for item in isolates],
        'isolate_count': len(isolates),
        'non_system_isolate_count': sum(item.get('isSystemIsolate') is False for item in isolates),
        'system_flag_missing_count': sum('isSystemIsolate' not in item for item in isolates),
        'main_named_count': sum(item['name'] == 'main' for item in isolates),
    }


VALIDATION_HINTS = ('请输入邮箱', '请输入密码')


VM_START_DELTA_LIMIT_MS = 86_400_000


def vm_start_delta(original, observed):
    """Diagnostic only, never an identity.

    Dart's getVM computes startTime on every request as
    OS::GetCurrentTimeMillis() - Dart::UptimeMillis() (runtime/vm/service.cc,
    PrintJSONForVM), two separately truncated clocks, so one VM reports values
    a millisecond apart and follows any guest wall-clock step.
    """
    delta = observed['vm_start'] - original['vm_start']
    return {'vm_start_delta_ms': max(-VM_START_DELTA_LIMIT_MS, min(VM_START_DELTA_LIMIT_MS, delta)), 'vm_start_delta_clamped': abs(delta) > VM_START_DELTA_LIMIT_MS}


def main_change(original, observed):
    """Which identity part moved, and the shape of both isolate lists; no ids."""
    before, after = original['main'] or {}, observed['main'] or {}
    counts = ('isolate_count', 'non_system_isolate_count', 'system_flag_missing_count', 'main_named_count')
    return {
        'vm_start_changed': observed['vm_start'] != original['vm_start'],
        **vm_start_delta(original, observed),
        'main_id_changed': after.get('id') != before.get('id'),
        'main_number_changed': after.get('number') != before.get('number'),
        'main_group_changed': after.get('isolateGroupId') != before.get('isolateGroupId'),
        'original': {key: original.get(key) for key in counts},
        'observed': {key: observed.get(key) for key in counts},
    }


def activity_events(data, pid):
    events = []
    pattern = r'\s*(\d+\.\d{3,9})\s+(\d+)\s+(\d+)\s+I\s+wm_on_(create|resume|destroy)_called\s*:\s*\[(-?\d+),([^,\]]+),([^,\]]+),(\d+)\]\s*'
    for line in private_text(data).splitlines():
        match = re.fullmatch(pattern, line)
        if match is not None and int(match[2]) == pid and match[6] == ACTIVITY:
            events.append({'stamp': match[1], 'pid': pid, 'tid': int(match[3]), 'tag': match[4], 'token': int(match[5]), 'reason': match[7], 'duration': int(match[8])})
    require(len(events) <= 500, 'bounded_lifecycle_history_required')
    return events


def events_after(before, after):
    require(bool(before) and after[:len(before)] == before, 'lifecycle_cursor_lost')
    return after[len(before):]


def current_activity(events, *, allow_empty=False):
    active = set()
    resumed = None
    for event in events:
        if event['tag'] == 'create':
            require(event['token'] not in active, 'duplicate_activity_create')
            active.add(event['token'])
        elif event['tag'] == 'destroy':
            require(event['token'] in active, 'incomplete_activity_history')
            active.remove(event['token'])
        elif event['tag'] == 'resume':
            require(event['token'] in active, 'incomplete_activity_history')
            resumed = event['token']
    if allow_empty and not active:
        return None
    require(len(active) == 1 and resumed in active, 'single_resumed_activity_unconfirmed')
    return resumed


def resumed_record(data, package=PACKAGE):
    text = private_text(data, 2 * 1024 * 1024)
    pattern = r'(?:mResumedActivity:|topResumedActivity=)\s*ActivityRecord\{([0-9a-f]+)\s+u\d+\s+' + re.escape(package + '/' + ACTIVITY) + r'\s+t\d+\}'
    records = set(re.findall(pattern, text))
    require(len(records) == 1, 'owned_resumed_record_unconfirmed')
    return records.pop()


def activities_absent(data, package=PACKAGE):
    return re.search(r'ActivityRecord\{[^\r\n}]*\s' + re.escape(package) + '/', private_text(data, 2 * 1024 * 1024)) is None


class VmChannel:
    def __init__(self, device, address):
        self.device, (self.remote, self.auth) = device, address
        self.local = None
        self.creation_attempted = False

    def mappings(self):
        rows = private_text(self.device.call('forward', '--list'), 8192).splitlines()
        return [tuple(row.split()) for row in rows if row.strip()]

    def expected(self):
        return (self.device.serial, 'tcp:' + str(self.local), 'tcp:' + str(self.remote))

    def verify(self):
        require(self.local is not None and self.mappings() == [self.expected()], 'owned_vm_forward_changed')

    def open(self):
        require(self.local is None and not self.mappings(), 'fresh_vm_forward_required')
        self.creation_attempted = True
        port = self.device.call('forward', '--no-rebind', 'tcp:0', 'tcp:' + str(self.remote)).strip()
        require(re.fullmatch(rb'[1-9]\d{0,4}', port) is not None and 1024 <= int(port) <= 65535, 'owned_vm_forward_port_unconfirmed')
        self.local = int(port)
        self.verify()
        return self

    def close(self):
        if self.local is None:
            require(not self.creation_attempted, 'owned_vm_forward_cleanup_unconfirmed')
            return
        self.verify()
        self.device.call('forward', '--remove', 'tcp:' + str(self.local))
        require(not self.mappings(), 'owned_vm_forward_cleanup_unconfirmed')
        self.local = None
        self.creation_attempted = False

    def read(self, pid, *, allow_empty=False):
        self.verify()
        connection = http.client.HTTPConnection('127.0.0.1', self.local, timeout=3)
        try:
            connection.request('GET', self.auth + 'getVM')
            response = connection.getresponse()
            if response.status != 200:
                raise VmUnavailable('vm_endpoint_unavailable')
            data = response.read(MAX_RESPONSE + 1)
        except (OSError, http.client.HTTPException):
            raise VmUnavailable('vm_endpoint_unavailable') from None
        finally:
            connection.close()
        require(len(data) <= MAX_RESPONSE, 'bounded_vm_response_required')
        try:
            value = json.loads(data)
        except (ValueError, UnicodeError):
            raise ProofRefused('vm_response_unreadable') from None
        return vm_snapshot(value, pid, allow_empty=allow_empty)


def hash_identity(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()


class LifecycleProbe:
    def __init__(self, device):
        self.device = device
        self.package = device.package
        require(self.package in SAFE_PACKAGES, 'owned_example_package_required')
        self.guest = None
        self.channel = None
        self.report = {'success': False, 'scope': 'safe-stopped-normal-main-v1', 'replacements': [], 'quit': {}, 'captures': {}, 'vm_forward_cleanup': False, 'sustained_no_view_tested': False, 'active_vpn_or_doze_tested': False, 'java_engine_count_measured': False, 'errors': []}

    def same_guest(self):
        require(guest_identity(self.device) == self.guest, 'guest_process_changed')

    def events(self):
        self.same_guest()
        return activity_events(self.device.call('logcat', '-b', 'events', '-d', '--pid=' + str(self.guest['pid']), '-v', 'epoch', '-v', 'usec', '-t', '500', 'wm_on_create_called:I', 'wm_on_resume_called:I', 'wm_on_destroy_called:I', '*:S'), self.guest['pid'])

    def record(self):
        return self.device.call('shell', 'dumpsys', 'activity', 'activities')

    def validation_hint_visible(self):
        try:
            nodes = self.device.ui().iter('node')
            return any((node.get('text') or node.get('content-desc') or '').strip() in VALIDATION_HINTS for node in nodes)
        except Exception:
            return None

    def require_same_main(self, original, observed, *, index, observation, launched):
        # Same VM = the owned PID (vm_snapshot binds getVM.pid to the guest),
        # the guest birth rechecked by same_guest() before every read, and an
        # identical main {id, number, isolateGroupId}. startTime is not used.
        if observed['pid'] == original['pid'] and observed['main'] == original['main']:
            return
        self.report['main_change'] = dict(main_change(original, observed), replacement=index, observation=observation, ms_since_launch=int((time.monotonic() - launched) * 1000), validation_hint_visible=self.validation_hint_visible())
        raise ProofRefused('main_isolate_changed_during_replacement')

    def connect(self):
        self.same_guest()
        # Consent/input can outlive the recent 300-line window. Filter the
        # existing owned-PID buffer at the source and retain no raw auth URI.
        data = self.device.call('logcat', '-d', '--pid=' + str(self.guest['pid']), '-v', 'raw', '--regex=Dart.VM.service.is.listening.on', 'DartVM:I', 'flutter:I', '*:S')
        require(isinstance(data, bytes), 'bounded_vm_announcement_required')
        report = {'query': 'ownedPidRegex', 'bytes': len(data), 'authenticated_local_address_parsed': False, 'guest_birth_rechecked': False}
        self.report.setdefault('vm_address_observations', []).append(report)
        require(len(data) <= 16 * 1024, 'bounded_vm_announcement_required')
        self.same_guest()
        report['guest_birth_rechecked'] = True
        address = service_address(data)
        report['authenticated_local_address_parsed'] = True
        self.channel = VmChannel(self.device, address)
        self.channel.open()
        return self.channel.read(self.guest['pid'])

    def replace(self, index, original):
        before = self.events()
        old = current_activity(before)
        old_record = resumed_record(self.record(), package=self.package)
        launched = time.monotonic()
        result = self.device.call('shell', 'am', 'start', '-W', '-f', '0x10008000', '-n', self.package + '/' + ACTIVITY)
        require('Status: ok' in private_text(result), 'activity_replacement_launch_unconfirmed')
        deadline = time.monotonic() + 35
        observations = 0
        while time.monotonic() < deadline:
            self.same_guest()
            observed = self.channel.read(self.guest['pid'])
            observations += 1
            self.require_same_main(original, observed, index=index, observation=observations, launched=launched)
            after = self.events()
            changes = events_after(before, after)
            destroyed = any(item['tag'] == 'destroy' and item['token'] == old and item['reason'] == 'performDestroy' for item in changes)
            created = {item['token'] for item in changes if item['tag'] == 'create' and item['token'] != old}
            resumed = {item['token'] for item in changes if item['tag'] == 'resume'}
            if destroyed and len(created) == 1 and created <= resumed:
                current = current_activity(after)
                if current in created:
                    record = resumed_record(self.record(), package=self.package)
                    require(record != old_record, 'activity_record_not_replaced')
                    _, login = self.device.wait_label('登录')
                    self.device.tap(login)
                    self.device.wait_empty_validation()
                    self.report['captures']['replacement_' + str(index)] = self.device.capture('0' + str(4 + index) + '-activity-replaced')
                    self.same_guest()
                    final = self.channel.read(self.guest['pid'])
                    self.require_same_main(original, final, index=index, observation=observations + 1, launched=launched)
                    self.report['replacements'].append({'client_destroy_callback_returned': True, 'different_client_activity': True, 'different_server_record': True, 'same_guest_birth': True, 'same_vm_instance': True, 'same_main_isolate': True, 'main_observations': observations + 1, 'old_activity_sha256': hash_identity(old), 'new_activity_sha256': hash_identity(current), 'main_identity_sha256': hash_identity(original['main']), **vm_start_delta(original, final)})
                    return
            time.sleep(0.3)
        raise ProofRefused('activity_replacement_proof_timeout')

    def quit_button(self):
        for attempt in range(4):
            self.same_guest()
            resumed_record(self.record(), package=self.package)
            capture = self.device.capture('07-explicit-quit-action-' + str(attempt))
            tree = self.device.ui()
            nodes = list(tree.iter('node'))
            label = lambda node: (node.get('text') or node.get('content-desc', '')).strip()
            require(sum(label(node) == '登录' for node in nodes) == 1 and sum(node.get('class') == 'android.widget.EditText' for node in nodes) == 2, 'owned_login_for_quit_unconfirmed')
            matches = [node for node in nodes if label(node) == '退出客户端' and node.get('enabled') == 'true']
            require(len(matches) <= 1, 'ambiguous_explicit_quit_action')
            if matches:
                bounds = re.fullmatch(r'\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]', matches[0].get('bounds', ''))
                require(bounds is not None, 'quit_action_bounds_unreadable')
                left, top, right, bottom = map(int, bounds.groups())
                if 0 <= left < right <= capture['width'] and 0 <= top < bottom <= capture['height']:
                    self.report['captures']['quit_action'] = capture
                    return matches[0]
            if attempt < 3:
                self.device.call('shell', 'input', 'swipe', capture['width'] // 2, capture['height'] * 3 // 4, capture['width'] // 2, capture['height'] // 3, '350')
        raise ProofRefused('visible_explicit_quit_action_unconfirmed')

    def quit_and_reopen(self, original):
        before = self.events()
        old = current_activity(before)
        button = self.quit_button()
        self.device.tap(button)
        deadline = time.monotonic() + 40
        absent = 0
        prior_absent = None
        service_unavailable = False
        while time.monotonic() < deadline:
            self.same_guest()
            after = self.events()
            changes = events_after(before, after)
            destroyed = any(item['tag'] == 'destroy' and item['token'] == old and item['reason'] == 'performDestroy' for item in changes)
            if destroyed and current_activity(after, allow_empty=True) is None and activities_absent(self.record(), package=self.package):
                absent += 1
                try:
                    observed = self.channel.read(self.guest['pid'], allow_empty=True)
                    prior_absent = original['main']['id'] not in observed['isolate_ids']
                except VmUnavailable:
                    service_unavailable = True
                if absent >= 2:
                    break
            else:
                absent = 0
            time.sleep(0.4)
        require(absent >= 2, 'explicit_quit_activity_teardown_unconfirmed')
        self.report['quit'].update(button_clicked=True, client_destroy_callback_returned=True, own_activities_absent=True, old_isolate_absent_before_reopen=prior_absent, vm_endpoint_unavailable_after_quit=service_unavailable)
        self.channel.close()
        self.channel = None
        self.device.start()
        self.device.wait_label('登录')
        self.same_guest()
        reopened = self.connect()
        # The guest process is required to be the same one across Quit
        # (same_guest() above), so a fresh generation is a new main identity
        # whose response no longer lists the old main id; startTime proves
        # nothing about a new VM and is only reported.
        fresh_main = reopened['main'] != original['main']
        old_absent = original['main']['id'] not in reopened['isolate_ids']
        require(fresh_main and old_absent and current_activity(self.events()) != old, 'explicit_quit_fresh_generation_unconfirmed')
        self.report['quit'].update(same_guest_birth_on_reopen=True, new_main_identity_verified=fresh_main, new_main_id_differs=reopened['main']['id'] != original['main']['id'], old_isolate_identity_absent_after_reopen=old_absent, **vm_start_delta(original, reopened))
        self.report['captures']['quit_reopened'] = self.device.capture('08-explicit-quit-reopened')

    def run(self):
        try:
            self.guest = guest_identity(self.device)
            original = self.connect()
            for index in (1, 2):
                self.replace(index, original)
            self.quit_and_reopen(original)
            self.report['success'] = True
        except Exception as error:
            self.report['errors'].append(str(error) if isinstance(error, ProofRefused) else 'lifecycle_observation_unavailable')
        finally:
            try:
                if self.channel is not None:
                    self.channel.close()
                self.report['vm_forward_cleanup'] = True
            except Exception:
                self.report['errors'].append('owned_vm_forward_cleanup_unconfirmed')
            self.report['success'] = self.report['success'] and self.report['vm_forward_cleanup'] and not self.report['errors']
            path = self.device.output / 'receipts/lifecycle.json'
            require(not path.exists() and not path.is_symlink(), 'new_lifecycle_receipt_required')
            with path.open('x', encoding='utf-8') as stream:
                json.dump(self.report, stream, sort_keys=True)
        return self.report
