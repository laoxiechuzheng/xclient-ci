import ctypes
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

spec = importlib.util.spec_from_file_location('native_tls_probe', Path(__file__).with_name('native_tls_probe.py'))
probe = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe)


class FakeTrustApi:
    def __init__(self, *, trusted=True, fail=None, missing_error=False, result=None, release_failure=False):
        self.trusted = trusted
        self.fail = fail
        self.missing_error = missing_error
        self.result = (4 if trusted else 5) if result is None else result
        self.release_failure = release_failure
        self.created, self.released, self.calls, self.arrays, self.strings = [], [], [], [], {}

    def new(self):
        value = 100 + len(self.created)
        self.created.append(value)
        return value

    def status(self, name, *args):
        self.calls.append((name, args))
        if self.fail == name:
            return -50
        return 0

    def CFDataCreate(self, allocator, data, size):
        return self.new()

    def SecCertificateCreateWithData(self, allocator, data):
        return self.new()

    def CFArrayCreate(self, allocator, values, size, callbacks):
        self.arrays.append([values[index] for index in range(size)])
        return self.new()

    def CFStringCreateWithCString(self, allocator, value, encoding):
        self.calls.append(('host', (value, encoding)))
        return self.new()

    def SecPolicyCreateSSL(self, server, host):
        self.calls.append(('policy', (server, host)))
        return self.new()

    def SecTrustCreateWithCertificates(self, chain, policy, output):
        ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = self.new()
        return self.status('createTrust', chain, policy)

    def SecTrustSetAnchorCertificates(self, trust, anchors):
        return self.status('setAnchors', anchors)

    def SecTrustSetAnchorCertificatesOnly(self, trust, only):
        return self.status('anchorOnly', only)

    def SecTrustSetNetworkFetchAllowed(self, trust, fetch):
        return self.status('networkFetch', fetch)

    def SecTrustEvaluateWithError(self, trust, output):
        if self.fail == 'binding':
            raise TypeError('DO_NOT_EXPORT_BINDING_DETAIL')
        if not self.trusted and not self.missing_error:
            ctypes.cast(output, ctypes.POINTER(ctypes.c_void_p))[0] = self.new()
        return self.trusted

    def SecTrustGetTrustResult(self, trust, output):
        ctypes.cast(output, ctypes.POINTER(ctypes.c_uint32))[0] = self.result
        return self.status('trustResult')

    def CFErrorGetCode(self, error):
        return -67843

    def CFErrorGetDomain(self, error):
        self.strings[9000] = 'NSOSStatusErrorDomain'
        return 9000

    def CFErrorCopyDescription(self, error):
        value = self.new()
        self.strings[value] = 'DO_NOT_EXPORT_CERTIFICATE_DETAIL untrusted root certificate'
        return value

    def CFStringGetCString(self, ref, buffer, size, encoding):
        data = self.strings[ref].encode() + b'\0'
        ctypes.memmove(buffer, data, len(data))
        return True

    def CFRelease(self, ref):
        self.released.append(ref)
        if self.release_failure and len(self.released) == 1:
            raise RuntimeError('DO_NOT_EXPORT_RELEASE_DETAIL')


class NativeTrustTest(unittest.TestCase):
    @staticmethod
    def der(tag, value):
        size = len(value)
        width = max(1, (size.bit_length() + 7) // 8)
        length = bytes([size]) if size < 128 else bytes([0x80 | width]) + size.to_bytes(width, 'big')
        return bytes([tag]) + length + value

    def certificate_with_extensions(self, oids):
        extensions = b''.join(self.der(0x30, self.der(6, oid) + self.der(4, b'\x30\x00')) for oid in oids)
        return self.der(0x30, self.der(0x30, self.der(0xa3, self.der(0x30, extensions))))

    def test_extension_counts_detect_duplicate_oids_without_exporting_values(self):
        basic, ski, unknown = b'\x55\x1d\x13', b'\x55\x1d\x0e', b'\x2a\x03\x04'
        result = probe.certificate_extension_diagnostic(self.certificate_with_extensions([basic, ski, basic, unknown, unknown]))
        self.assertEqual(result['extension_count'], 5)
        self.assertEqual(result['distinct_oid_count'], 3)
        self.assertEqual(result['duplicate_oid_count'], 2)
        self.assertEqual(result['duplicate_extension_count'], 2)
        self.assertFalse(result['unique'])
        self.assertEqual(result['known_oid_counts']['basicConstraints'], 2)
        self.assertEqual(result['known_oid_counts']['subjectKeyIdentifier'], 1)
        self.assertEqual(result['unknown_oid_count'], 1)
        self.assertNotIn('2a0304', str(result))

    def test_extension_parser_rejects_incomplete_or_out_of_scope_der(self):
        valid = self.certificate_with_extensions([b'\x55\x1d\x13'])
        for value in (b'', valid[:-1], valid + b'\0', b'\x30\x80\x00\x00', self.der(0x30, self.der(0x30, b''))):
            with self.subTest(size=len(value)), self.assertRaises(probe.guard.Refused):
                probe.certificate_extension_diagnostic(value)

    def test_tool_version_is_only_family_and_numeric_triplet(self):
        self.assertEqual(probe.openssl_diagnostic('LibreSSL 3.3.6 secret'), {'family': 'libreSSL', 'major': 3, 'minor': 3, 'patch': 6})
        self.assertEqual(probe.openssl_diagnostic('OpenSSL 3.5.9 29 Sep 2026'), {'family': 'openSSL', 'major': 3, 'minor': 5, 'patch': 9})
        self.assertEqual(probe.openssl_diagnostic('PRIVATE_TOOL_DATA'), {'family': 'unknown'})

    def test_system_bindings_use_the_published_abi_without_loading_libraries(self):
        cf, security = Mock(), Mock()
        with patch.object(probe.sys, 'platform', 'darwin'), patch.object(probe.ctypes, 'CDLL', side_effect=[cf, security]):
            probe.MacTrustApi()
        self.assertIs(security.SecTrustEvaluateWithError.restype, ctypes.c_bool)
        self.assertEqual(security.SecPolicyCreateSSL.argtypes, [ctypes.c_ubyte, ctypes.c_void_p])
        self.assertIs(security.SecTrustCreateWithCertificates.restype, ctypes.c_int32)
        self.assertEqual(security.SecTrustGetTrustResult.argtypes[-1], ctypes.POINTER(ctypes.c_uint32))
        self.assertIs(cf.CFErrorGetCode.restype, ctypes.c_long)

    def test_positive_uses_server_policy_local_anchor_and_releases_all_refs(self):
        api = FakeTrustApi()
        result = probe.evaluate_mac_trust(b'leaf', b'ca', True, api=api)
        self.assertTrue(probe.native_trust_expected(result, True))
        self.assertEqual(api.arrays, [[101, 103], [103]])
        self.assertIn(('host', (b'localhost', 0x08000100)), api.calls)
        self.assertIn(('policy', (True, 105)), api.calls)
        self.assertIn(('anchorOnly', (True,)), api.calls)
        self.assertIn(('networkFetch', (False,)), api.calls)
        self.assertEqual(api.released, list(reversed(api.created)))

    def test_negative_has_empty_anchors_and_real_failure_evidence(self):
        api = FakeTrustApi(trusted=False)
        result = probe.evaluate_mac_trust(b'leaf', b'ca', False, api=api)
        self.assertTrue(probe.native_trust_expected(result, False))
        self.assertEqual(api.arrays[-1], [])
        self.assertEqual(result['os_status'], 0)
        self.assertEqual(result['error_code'], -67843)
        self.assertEqual(result['error_domain'], 'osStatus')
        self.assertEqual(result['reason'], 'untrustedAnchor')
        self.assertNotIn('DO_NOT_EXPORT', str(result))
        self.assertNotIn(9000, api.released)
        self.assertEqual(api.released, list(reversed(api.created)))

    def test_duplicate_extension_refusal_does_not_establish_empty_anchor_control(self):
        api = FakeTrustApi(trusted=False)
        api.CFErrorGetCode = lambda error: -67903
        result = probe.evaluate_mac_trust(b'leaf', b'ca', False, api=api)
        self.assertTrue(result['api_ok'])
        self.assertEqual(result['reason'], 'duplicateExtension')
        self.assertFalse(probe.native_trust_expected(result, False))
        self.assertEqual(api.released, list(reversed(api.created)))

    def test_api_status_failures_are_not_certificate_refusals(self):
        for step in ('createTrust', 'setAnchors', 'anchorOnly', 'networkFetch', 'trustResult'):
            with self.subTest(step=step):
                api = FakeTrustApi(trusted=False, fail=step)
                result = probe.evaluate_mac_trust(b'leaf', b'ca', False, api=api)
                self.assertFalse(result['api_ok'])
                self.assertEqual(result['os_status'], -50)
                self.assertFalse(probe.native_trust_expected(result, False))
                self.assertEqual(api.released, list(reversed(api.created)))

    def test_binding_failure_is_not_certificate_refusal(self):
        api = FakeTrustApi(trusted=False, fail='binding')
        result = probe.evaluate_mac_trust(b'leaf', b'ca', False, api=api)
        self.assertFalse(result['api_ok'])
        self.assertFalse(probe.native_trust_expected(result, False))
        self.assertEqual(result['reason'], 'binding')
        self.assertNotIn('DO_NOT_EXPORT', str(result))
        self.assertEqual(api.released, list(reversed(api.created)))

    def test_false_with_missing_error_or_invalid_result_cannot_pass(self):
        for missing, result in ((True, 5), (False, 0), (False, 7)):
            with self.subTest(missing_error=missing, result=result):
                api = FakeTrustApi(trusted=False, missing_error=missing, result=result)
                report = probe.evaluate_mac_trust(b'leaf', b'ca', False, api=api)
                self.assertFalse(probe.native_trust_expected(report, False))
                self.assertEqual(api.released, list(reversed(api.created)))

    def test_release_failure_is_red_and_remaining_refs_are_released(self):
        api = FakeTrustApi(release_failure=True)
        result = probe.evaluate_mac_trust(b'leaf', b'ca', True, api=api)
        self.assertFalse(result['cf_refs_released'])
        self.assertFalse(probe.native_trust_expected(result, True))
        self.assertEqual(api.released, list(reversed(api.created)))

    def test_description_is_reduced_to_fixed_reason(self):
        self.assertEqual(probe.trust_reason('SENSITIVE hostname mismatch'), 'hostname')
        self.assertEqual(probe.trust_reason('SENSITIVE expired certificate'), 'expired')
        self.assertEqual(probe.trust_reason('SENSITIVE extended key usage'), 'usage')
        self.assertEqual(probe.trust_reason('SENSITIVE unexpected diagnostic'), 'unknown')

    def test_null_reference_or_failed_cfstring_conversion_is_red(self):
        for method, replacement in [('CFDataCreate', lambda *args: None), ('CFErrorCopyDescription', lambda *args: None), ('CFStringGetCString', lambda *args: False)]:
            with self.subTest(method=method):
                api = FakeTrustApi(trusted=False)
                setattr(api, method, replacement)
                result = probe.evaluate_mac_trust(b'leaf', b'ca', False, api=api)
                self.assertFalse(result['api_ok'])
                self.assertFalse(probe.native_trust_expected(result, False))
                self.assertEqual(api.released, list(reversed(api.created)))


if __name__ == '__main__':
    unittest.main()
