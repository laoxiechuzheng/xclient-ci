import http.client
import json
import re
from urllib.parse import urlencode

import android_lifecycle_probe as guard


def read_only_rpc(channel, method, isolate):
    guard.require(method in ('getIsolate', 'getStack') and isinstance(isolate, str) and re.fullmatch(r'isolates/[A-Za-z0-9_-]{1,128}', isolate) is not None, 'startup_rpc_rejected')
    channel.verify()
    arguments = {'isolateId': isolate}
    if method == 'getStack':
        arguments['limit'] = 32
    connection = http.client.HTTPConnection('127.0.0.1', channel.local, timeout=3)
    try:
        connection.request('GET', channel.auth + method + '?' + urlencode(arguments))
        response = connection.getresponse()
        if response.status != 200:
            raise guard.VmUnavailable('startup_rpc_unavailable')
        data = response.read(guard.MAX_RESPONSE + 1)
    except (OSError, http.client.HTTPException):
        raise guard.VmUnavailable('startup_rpc_unavailable') from None
    finally:
        connection.close()
    guard.require(len(data) <= guard.MAX_RESPONSE, 'bounded_startup_rpc_required')
    value = json.loads(data)
    guard.require(isinstance(value, dict) and isinstance(value.get('result'), dict) and 'error' not in value, 'startup_rpc_response_rejected')
    return value['result']


def summary(isolate, stack, expected_id):
    guard.require(isolate.get('type') == 'Isolate' and isolate.get('id') == expected_id and isolate.get('name') == 'main' and stack.get('type') == 'Stack', 'owned_startup_isolate_required')
    frames = []
    for name in ('frames', 'asyncCausalFrames'):
        values = stack.get(name) or []
        guard.require(isinstance(values, list) and len(values) <= 64, 'bounded_startup_frames_required')
        for frame in values:
            uri = ((frame.get('location') or {}).get('script') or {}).get('uri', '')
            public = isinstance(uri, str) and (re.fullmatch(r'package:(?:rust_api|flutter_rust_bridge|device_info_plus|device_info_plus_platform_interface)/[A-Za-z0-9_./-]+\.dart', uri) is not None or uri in ('package:fl_clash/main.dart', 'package:fl_clash/common/system.dart', 'package:flutter/src/services/platform_channel.dart', 'package:flutter/src/services/binding.dart', 'dart:async', 'dart:isolate', 'dart:ffi', 'dart:core', 'dart:_internal'))
            if not public or '..' in uri.split('/'):
                continue
            function = (frame.get('function') or {}).get('name', '')
            function = function if isinstance(function, str) and re.fullmatch(r'[A-Za-z0-9_.$<> =:-]{1,160}', function) else 'unknown'
            kind = frame.get('kind')
            frames.append({'list': name, 'kind': kind if kind in ('Regular', 'AsyncCausal', 'AsyncSuspensionMarker') else 'unknown', 'function': function, 'script': uri})
    pause = (isolate.get('pauseEvent') or {}).get('kind')
    return {'main_isolate_verified': True, 'runnable_reported': type(isolate.get('runnable')) is bool, 'runnable': isolate.get('runnable') is True, 'pause_kind': pause if pause in ('PauseStart', 'PauseExit', 'PauseBreakpoint', 'PauseInterrupted', 'PauseException', 'Resume') else 'unknown', 'frames': frames[:64], 'stack_truncated': stack.get('truncated') is True}


def observe(device, guest, messages):
    report = {'available': False, 'owned_forward_cleanup': False, 'error_class': None}
    channel = guard.VmChannel(device, guard.service_address(messages))
    def check_owner():
        device.verify_owned()
        guard.require(guard.guest_identity(device) == guest, 'startup_guest_changed')
    try:
        check_owner()
        channel.open()
        vm = channel.read(guest['pid'])
        isolate_id = vm['main']['id']
        check_owner()
        isolate = read_only_rpc(channel, 'getIsolate', isolate_id)
        check_owner()
        report.update(summary(isolate, {'type': 'Stack'}, isolate_id), isolate_state_observed=True, stack_observed=False)
        stack = read_only_rpc(channel, 'getStack', isolate_id)
        check_owner()
        after = channel.read(guest['pid'])
        guard.require(all(after[key] == vm[key] for key in ('pid', 'vm_start', 'main')), 'startup_vm_changed')
        report['other_isolates_changed'] = after['isolate_ids'] != vm['isolate_ids']
        report.update(summary(isolate, stack, isolate_id), available=True, stack_observed=True)
    except (guard.ProofRefused, guard.VmUnavailable) as error:
        report['error_class'] = str(error)
    except Exception:
        report['error_class'] = 'startup_vm_observation_unavailable'
    finally:
        try:
            check_owner()
            channel.close()
            report['owned_forward_cleanup'] = True
        except Exception:
            report['error_class'] = 'startup_vm_forward_cleanup_unconfirmed'
    return report
