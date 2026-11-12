#!/usr/bin/env python3
import argparse
import ctypes
import http.server
import json
import os
from pathlib import Path
import re
import secrets
import ssl
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
import native_store_smoke as guard
import native_update_smoke as update

TARGET = guard.ROOT / 'test/xboard/native/tls_context_probe.dart'
SOURCES = (TARGET, Path(__file__).resolve(), Path(update.__file__), Path(guard.__file__))


def openssl_diagnostic(value):
    match = re.match(r'^(OpenSSL|LibreSSL) (\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:[a-z]?\b)', value)
    if match is None:
        return {'family': 'unknown'}
    return {'family': {'OpenSSL': 'openSSL', 'LibreSSL': 'libreSSL'}[match[1]], **dict(zip(('major', 'minor', 'patch'), map(int, match.groups()[1:])))}


def der_items(value):
    items, offset = [], 0
    while offset < len(value):
        guard.require(offset + 2 <= len(value), 'certificate_der_truncated')
        tag, size = value[offset:offset + 2]
        offset += 2
        guard.require(tag & 0x1f != 0x1f, 'certificate_der_tag')
        if size & 0x80:
            width = size & 0x7f
            guard.require(0 < width <= 3 and offset + width <= len(value) and value[offset] != 0, 'certificate_der_length')
            size = int.from_bytes(value[offset:offset + width], 'big')
            guard.require(size >= 128, 'certificate_der_nonminimal_length')
            offset += width
        guard.require(offset + size <= len(value), 'certificate_der_truncated')
        items.append((tag, value[offset:offset + size]))
        guard.require(len(items) <= 128, 'certificate_der_item_limit')
        offset += size
    return items


def one_der(value, tag):
    items = der_items(value)
    guard.require(len(items) == 1 and items[0][0] == tag, 'certificate_der_scope')
    return items[0][1]


def certificate_extension_diagnostic(der):
    guard.require(isinstance(der, bytes) and 0 < len(der) <= 65536, 'certificate_der_size')
    certificate = der_items(one_der(der, 0x30))
    guard.require(bool(certificate) and certificate[0][0] == 0x30, 'certificate_tbs_required')
    extensions = [value for tag, value in der_items(certificate[0][1]) if tag == 0xa3]
    guard.require(len(extensions) == 1, 'certificate_extensions_scope')
    counts = {}
    for tag, value in der_items(one_der(extensions[0], 0x30)):
        guard.require(tag == 0x30, 'certificate_extension_sequence')
        fields = der_items(value)
        guard.require(len(fields) in (2, 3) and fields[0][0] == 6 and fields[-1][0] == 4, 'certificate_extension_fields')
        if len(fields) == 3:
            guard.require(fields[1][0] == 1 and fields[1][1] in (b'\0', b'\xff'), 'certificate_extension_critical')
        oid = fields[0][1]
        guard.require(0 < len(oid) <= 32 and oid[-1] < 0x80, 'certificate_extension_oid')
        guard.require(all(byte != 0x80 for index, byte in enumerate(oid) if index == 0 or oid[index - 1] < 0x80), 'certificate_extension_oid_nonminimal')
        counts[oid] = counts.get(oid, 0) + 1
    guard.require(bool(counts), 'certificate_extensions_required')
    known = {b'\x55\x1d\x13': 'basicConstraints', b'\x55\x1d\x0f': 'keyUsage', b'\x55\x1d\x0e': 'subjectKeyIdentifier', b'\x55\x1d\x23': 'authorityKeyIdentifier', b'\x55\x1d\x25': 'extendedKeyUsage', b'\x55\x1d\x11': 'subjectAltName'}
    return {'extension_count': sum(counts.values()), 'distinct_oid_count': len(counts), 'duplicate_oid_count': sum(value > 1 for value in counts.values()), 'duplicate_extension_count': sum(value - 1 for value in counts.values()), 'unique': all(value == 1 for value in counts.values()), 'known_oid_counts': {name: counts.get(oid, 0) for oid, name in known.items()}, 'unknown_oid_count': sum(oid not in known for oid in counts)}


def trust_reason(description):
    value = description.lower()
    for fragments, reason in [(('hostname', 'host name', 'name mismatch'), 'hostname'), (('not yet valid',), 'notYetValid'), (('expired',), 'expired'), (('key usage', 'extended usage'), 'usage'), (('basic constraint', 'path length'), 'constraints'), (('untrusted', 'not trusted', 'unknown root', 'anchor', 'issuer'), 'untrustedAnchor'), (('revoked',), 'revoked'), (('algorithm', 'weak key'), 'algorithm')]:
        if any(fragment in value for fragment in fragments):
            return reason
    return 'unknown'


def native_trust_expected(report, trusted):
    if not (report['api_ok'] is True and report['os_status'] == 0 and report['cf_refs_released'] is True and report['anchor_only'] is True and report['network_fetch_disabled'] is True):
        return False
    if trusted:
        return report['trusted'] is True and report['trust_result'] in (1, 4) and report['error_code'] is None
    return report['trusted'] is False and report['trust_result'] in (3, 5, 6) and type(report['error_code']) is int and report['error_code'] != 0 and report['reason'] == 'untrustedAnchor'


class TrustProbeIssue(Exception):
    def __init__(self, reason):
        self.reason = reason


class MacTrustApi:
    def __init__(self):
        if sys.platform != 'darwin':
            raise TrustProbeIssue('nativeUnavailable')
        cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
        security = ctypes.CDLL('/System/Library/Frameworks/Security.framework/Security')
        pointer, index, status, boolean = ctypes.c_void_p, ctypes.c_long, ctypes.c_int32, ctypes.c_ubyte
        signatures = [
            (cf, 'CFDataCreate', pointer, [pointer, ctypes.POINTER(ctypes.c_ubyte), index]),
            (cf, 'CFArrayCreate', pointer, [pointer, ctypes.POINTER(pointer), index, pointer]),
            (cf, 'CFStringCreateWithCString', pointer, [pointer, ctypes.c_char_p, ctypes.c_uint32]),
            (cf, 'CFStringGetCString', boolean, [pointer, ctypes.POINTER(ctypes.c_char), index, ctypes.c_uint32]),
            (cf, 'CFErrorGetCode', index, [pointer]),
            (cf, 'CFErrorGetDomain', pointer, [pointer]),
            (cf, 'CFErrorCopyDescription', pointer, [pointer]),
            (cf, 'CFRelease', None, [pointer]),
            (security, 'SecCertificateCreateWithData', pointer, [pointer, pointer]),
            (security, 'SecPolicyCreateSSL', pointer, [boolean, pointer]),
            (security, 'SecTrustCreateWithCertificates', status, [pointer, pointer, ctypes.POINTER(pointer)]),
            (security, 'SecTrustSetAnchorCertificates', status, [pointer, pointer]),
            (security, 'SecTrustSetAnchorCertificatesOnly', status, [pointer, boolean]),
            (security, 'SecTrustSetNetworkFetchAllowed', status, [pointer, boolean]),
            (security, 'SecTrustEvaluateWithError', ctypes.c_bool, [pointer, ctypes.POINTER(pointer)]),
            (security, 'SecTrustGetTrustResult', status, [pointer, ctypes.POINTER(ctypes.c_uint32)]),
        ]
        for library, name, result, arguments in signatures:
            function = getattr(library, name)
            function.restype, function.argtypes = result, arguments
            setattr(self, name, function)


def evaluate_mac_trust(leaf, ca, trusted, *, api=None):
    report = {'api_ok': False, 'trusted': None, 'os_status': None, 'error_code': None, 'error_domain': 'unknown', 'reason': 'notEvaluated', 'trust_result': None, 'cf_refs_released': False, 'checkpoint': 'bind', 'anchor_only': False, 'network_fetch_disabled': False}
    owned = []

    def own(value):
        if not value:
            raise TrustProbeIssue('nullReference')
        owned.append(value)
        return value

    def status(value):
        report['os_status'] = int(value)
        if value != 0:
            raise TrustProbeIssue('apiStatus')

    def string(ref):
        buffer = ctypes.create_string_buffer(8192)
        if not ref or not api.CFStringGetCString(ref, buffer, len(buffer), 0x08000100):
            raise TrustProbeIssue('diagnosticRead')
        return buffer.value.decode('utf-8', errors='replace')

    def array(values):
        pointers = (ctypes.c_void_p * len(values))(*values)
        # Members stay owned until after the array and trust are released.
        return own(api.CFArrayCreate(None, pointers, len(values), None))

    try:
        api = api if api is not None else MacTrustApi()
        certificates = []
        report['checkpoint'] = 'certificates'
        for der in (leaf, ca):
            data = (ctypes.c_ubyte * len(der)).from_buffer_copy(der)
            cf_data = own(api.CFDataCreate(None, data, len(der)))
            certificates.append(own(api.SecCertificateCreateWithData(None, cf_data)))
        chain = array(certificates)
        report['checkpoint'] = 'policy'
        hostname = own(api.CFStringCreateWithCString(None, b'localhost', 0x08000100))
        policy = own(api.SecPolicyCreateSSL(True, hostname))
        report['checkpoint'] = 'createTrust'
        output = ctypes.c_void_p()
        created = api.SecTrustCreateWithCertificates(chain, policy, ctypes.byref(output))
        trust = own(output.value) if output.value else None
        status(created)
        if trust is None:
            raise TrustProbeIssue('nullReference')
        report['checkpoint'] = 'setAnchors'
        anchors = array([certificates[1]] if trusted else [])
        status(api.SecTrustSetAnchorCertificates(trust, anchors))
        report['checkpoint'] = 'anchorOnly'
        status(api.SecTrustSetAnchorCertificatesOnly(trust, True))
        report['anchor_only'] = True
        report['checkpoint'] = 'networkFetch'
        status(api.SecTrustSetNetworkFetchAllowed(trust, False))
        report['network_fetch_disabled'] = True
        report['checkpoint'] = 'evaluate'
        error = ctypes.c_void_p()
        report['trusted'] = bool(api.SecTrustEvaluateWithError(trust, ctypes.byref(error)))
        if error.value:
            own(error.value)
        report['checkpoint'] = 'trustResult'
        trust_result = ctypes.c_uint32()
        status(api.SecTrustGetTrustResult(trust, ctypes.byref(trust_result)))
        report['trust_result'] = trust_result.value
        if error.value:
            report['checkpoint'] = 'errorDescription'
            report['error_code'] = int(api.CFErrorGetCode(error.value))
            domain = string(api.CFErrorGetDomain(error.value))
            report['error_domain'] = {'NSOSStatusErrorDomain': 'osStatus', 'NSPOSIXErrorDomain': 'posix', 'NSCocoaErrorDomain': 'cocoa'}.get(domain, 'unknown')
            description = own(api.CFErrorCopyDescription(error.value))
            report['reason'] = trust_reason(string(description))
            if report['error_domain'] == 'osStatus' and report['error_code'] == -67903:
                report['reason'] = 'duplicateExtension'
        elif not report['trusted']:
            raise TrustProbeIssue('missingEvaluationError')
        else:
            report['reason'] = 'accepted'
        if (report['trusted'] and (error.value or trust_result.value not in (1, 4))) or (not report['trusted'] and trust_result.value not in (3, 5, 6)):
            raise TrustProbeIssue('inconsistentEvaluation')
        report['api_ok'] = True
        report['checkpoint'] = 'complete'
    except TrustProbeIssue as error:
        report['reason'] = error.reason
    except Exception:
        report['reason'] = 'binding'
    finally:
        released = True
        for ref in reversed(owned):
            try:
                api.CFRelease(ref)
            except Exception:
                released = False
        report['cf_refs_released'] = released
    return report


def extension(text, label):
    lines = text.splitlines()
    for index, line in enumerate(lines):
        if 'X509v3 ' + label + ':' in line:
            following = []
            for value in lines[index + 1:]:
                if 'X509v3 ' in value or 'Signature Algorithm:' in value:
                    break
                following.append(value.strip())
            return True, 'critical' in line.lower(), ' '.join(following)
    return False, False, ''


def certificate_diagnostic(text):
    version = re.search(r'\bVersion:\s*(\d+)\b', text)
    algorithms = set(re.findall(r'Signature Algorithm:\s*([A-Za-z0-9_-]+)', text))
    allowed = {'sha256WithRSAEncryption': 'rsaSha256', 'sha384WithRSAEncryption': 'rsaSha384', 'sha512WithRSAEncryption': 'rsaSha512', 'ecdsa-with-SHA256': 'ecdsaSha256', 'ecdsa-with-SHA384': 'ecdsaSha384', 'ecdsa-with-SHA512': 'ecdsaSha512'}
    basic, critical, constraints = extension(text, 'Basic Constraints')
    usage, _, usages = extension(text, 'Key Usage')
    eku, _, purposes = extension(text, 'Extended Key Usage')
    san, _, names = extension(text, 'Subject Alternative Name')
    return {'x509_version': int(version[1]) if version else None, 'basic_constraints_present': basic, 'basic_constraints_critical': critical, 'ca': True if 'CA:TRUE' in constraints else False if 'CA:FALSE' in constraints else None, 'key_usage_present': usage, 'digital_signature': 'Digital Signature' in usages, 'key_encipherment': 'Key Encipherment' in usages, 'certificate_sign': 'Certificate Sign' in usages, 'eku_present': eku, 'eku_server_auth': 'TLS Web Server Authentication' in purposes or '1.3.6.1.5.5.7.3.1' in purposes, 'san_present': san, 'san_localhost': bool(re.search(r'\bDNS:localhost(?:,|\s|$)', names)), 'san_ipv4_loopback': bool(re.search(r'\bIP Address:127\.0\.0\.1(?:,|\s|$)', names)), 'signature_algorithm': allowed.get(next(iter(algorithms)), 'unknown') if len(algorithms) == 1 else 'unknown'}


class ProbeServer(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, handler):
        self.active = set()
        self.lock = threading.Lock()
        super().__init__(('127.0.0.1', 0), handler)

    def get_request(self):
        request, address = super().get_request()
        request.settimeout(5)
        try:
            request.do_handshake()
            return request, address
        except BaseException:
            request.close()
            raise

    def process_request(self, request, address):
        request.settimeout(5)
        with self.lock:
            self.active.add(request)
        try:
            super().process_request(request, address)
        except BaseException:
            with self.lock:
                self.active.discard(request)
            request.close()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request, address)
        finally:
            with self.lock:
                self.active.discard(request)

    def handle_error(self, request, address):
        pass

    def close_active(self):
        with self.lock:
            active = list(self.active)
        for connection in active:
            connection.close()
        return all(connection.fileno() == -1 for connection in active)


def checked_child(sdk, config, mode, nonce):
    child = None
    owner = None
    try:
        child = subprocess.Popen([str(sdk), '--disable-dart-dev', str(TARGET), str(config), mode], cwd=guard.ROOT, env=dict(os.environ, XC_NATIVE_TLS_PROBE_NONCE=nonce), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            owner = guard.process_identity(child.pid)
            guard.require(Path(owner['executable']).resolve() == sdk, 'sdk_process_identity_mismatch')
        except Exception:
            guard.require(child.poll() is not None, 'sdk_process_identity_unconfirmed')
        captured, errors = child.communicate(timeout=45)
        guard.require(len(captured) <= 16384, 'sdk_receipt_limit')
        report = json.loads(captured)
        guard.require(isinstance(report, dict) and set(report) <= {'success', 'checkpoint', 'checks', 'failure'} and type(report.get('success')) is bool and isinstance(report.get('checks'), dict), 'sdk_receipt_invalid')
        report['exit_code'] = child.returncode
        report['stderr_bytes'] = len(errors)
        report['child_stopped'] = child.poll() is not None
        return report
    finally:
        if child is not None and child.poll() is None:
            guard.require(owner is not None and guard.process_identity(child.pid) == owner, 'child_cleanup_identity_unconfirmed')
            child.terminate()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                guard.require(guard.process_identity(child.pid) == owner, 'child_cleanup_identity_unconfirmed')
                child.kill()
                child.wait(timeout=5)
        guard.require(child is None or child.poll() is not None, 'child_cleanup_unconfirmed')


def run(args):
    job = guard.ci_identity('macos')
    output = guard.scoped(args.output)
    guard.require(not output.exists() and not output.is_symlink(), 'new_output_required')
    ca = Path(args.mozilla_ca).resolve()
    guard.require(ca == guard.ROOT / 'core/Clash.Meta/component/ca/ca-certificates.crt' and ca.is_file() and not Path(args.mozilla_ca).is_symlink(), 'pinned_mozilla_file_required')
    guard.require(re.fullmatch('[0-9a-f]{64}', args.mozilla_sha256) and guard.digest(ca) == args.mozilla_sha256, 'mozilla_hash_mismatch')
    sdk = (Path(os.environ.get('FLUTTER_ROOT', '')) / 'bin/cache/dart-sdk/bin/dart').resolve()
    guard.require(sdk.is_file() and sdk.name == 'dart' and (sdk.parent.parent / 'version').read_text(encoding='utf-8').strip() == '3.13.5', 'locked_dart_sdk_required')
    hashes = {str(source): guard.digest(source) for source in SOURCES}
    before = guard.network_hash()
    output.mkdir(parents=True, mode=0o700)
    private = output / 'private'
    private.mkdir(mode=0o700)
    receipts = output / 'receipts'
    receipts.mkdir()
    nonce = secrets.token_hex(16)
    (output / '.native-tls-owned').write_text(nonce, encoding='utf-8')
    servers = []
    result = {'success': False, 'certificate_extensions_unique': False, 'native_trust_positive': False, 'native_trust_negative': False, 'same_isolate_append': False, 'mozilla_only_rejected': False, 'children_stopped': False, 'servers_closed': False, 'network_unchanged': False, 'inputs_unchanged': False, 'error_classes': []}
    try:
        openssl = update.generate_fixture_certificate(private)
        guard.write_new(receipts / 'openssl.json', openssl_diagnostic(update.command([openssl, 'version'])))
        description = update.command([openssl, 'x509', '-in', private / 'server.crt', '-noout', '-text'])
        guard.write_new(receipts / 'certificate.json', certificate_diagnostic(description))
        certificate_hashes = {str(private / name): guard.digest(private / name) for name in ('ca.crt', 'server.crt', 'server-chain.crt')}
        leaf_der = ssl.PEM_cert_to_DER_cert((private / 'server.crt').read_text(encoding='ascii'))
        ca_der = ssl.PEM_cert_to_DER_cert((private / 'ca.crt').read_text(encoding='ascii'))
        extension_counts = {'leaf': certificate_extension_diagnostic(leaf_der), 'ca': certificate_extension_diagnostic(ca_der)}
        guard.write_new(receipts / 'extensions.json', extension_counts)
        result['certificate_extensions_unique'] = all(value['unique'] is True for value in extension_counts.values())
        for trusted, name in [(True, 'positive'), (False, 'negative')]:
            evaluation = evaluate_mac_trust(leaf_der, ca_der, trusted)
            guard.write_new(receipts / ('sec-trust-' + name + '.json'), evaluation)
            result['native_trust_' + name] = native_trust_expected(evaluation, trusted)
        body = private / 'body'
        body.write_bytes(b'tls-probe-ok')
        ports = {}
        for name in ('fixture', 'afterMozilla', 'explicit', 'mozillaOnly'):
            server = ProbeServer(update.HttpsFixture)
            servers.append((server, None))
            server.allowed = {'/tls-probe': body}
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(private / 'server-chain.crt', private / 'server.key')
            server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
            server.socket.settimeout(5)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            servers[-1] = (server, thread)
            ports[name] = server.server_port
        guard.require(len(set(ports.values())) == 4, 'fresh_ports_required')
        config = private / 'config.json'
        guard.write_new(config, {'job': job, 'nonce': nonce, 'prepared_ms': time.time_ns() // 10**6, 'output': str(output), 'dart_executable': str(sdk), 'certificate': str(private / 'ca.crt'), 'server_certificate': str(private / 'server.crt'), 'mozilla_ca': str(ca), 'ports': ports})
        inputs = {**hashes, str(ca): args.mozilla_sha256, **certificate_hashes, str(config): guard.digest(config), str(sdk): guard.digest(sdk)}
        guard.write_new(receipts / 'inputs.json', {'job': job, 'target_sha256': hashes[str(TARGET)], 'launcher_sha256': hashes[str(Path(__file__).resolve())], 'fixture_sha256': hashes[str(Path(update.__file__))], 'guard_sha256': hashes[str(Path(guard.__file__))], 'mozilla_sha256': args.mozilla_sha256, 'certificate_sha256': inputs[str(private / 'ca.crt')], 'server_leaf_sha256': inputs[str(private / 'server.crt')], 'server_chain_sha256': inputs[str(private / 'server-chain.crt')], 'config_sha256': inputs[str(config)], 'dart_sha256': inputs[str(sdk)]})
        for mode, field in [('append', 'same_isolate_append'), ('mozillaOnly', 'mozilla_only_rejected')]:
            guard.require(all(guard.digest(Path(file)) == expected for file, expected in inputs.items()), 'probe_input_changed')
            report = checked_child(sdk, config, mode, nonce)
            guard.write_new(receipts / (mode + '.json'), report)
            result[field] = report.get('success') is True and report.get('exit_code') == 0 and report.get('stderr_bytes') == 0
            result['children_stopped'] = report['child_stopped'] is True
        result['inputs_unchanged'] = all(guard.digest(Path(file)) == expected for file, expected in inputs.items())
    except Exception as error:
        result['error_classes'].append(str(error) if isinstance(error, guard.Refused) else 'probe_io_or_process_error')
    finally:
        closed = True
        for server, thread in reversed(servers):
            try:
                active_closed = server.close_active()
                update.close_fixture(server, thread is not None)
                if thread is not None:
                    thread.join(timeout=5)
                closed = closed and active_closed and server.socket.fileno() == -1 and (thread is None or not thread.is_alive())
            except Exception:
                closed = False
        result['servers_closed'] = closed and len(servers) == 4
        try:
            result['network_unchanged'] = before == guard.network_hash()
        except Exception:
            result['error_classes'].append('network_snapshot_unconfirmed')
        required = [key for key in result if key not in ('success', 'error_classes')]
        result['success'] = all(result[key] is True for key in required) and not result['error_classes']
        guard.write_new(receipts / 'runner-result.json', result)
    print(json.dumps(result, sort_keys=True))
    return 0 if result['success'] else 1


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    parser.add_argument('--mozilla-ca', required=True)
    parser.add_argument('--mozilla-sha256', required=True)
    return run(parser.parse_args())


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print(json.dumps({'success': False, 'error_class': str(error) if isinstance(error, guard.Refused) else 'probe_setup_error'}))
        sys.exit(1)
