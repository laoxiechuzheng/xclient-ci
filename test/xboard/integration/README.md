# Isolated instance probe

This opt-in Flutter test runs the real XClient runtime against a throwaway panel. It uses memory-only credentials/profile storage and never starts FlClash, mihomo, the system proxy or TUN. Only loopback HTTPS endpoints are accepted; reach a remote isolated instance through an explicit SSH port forward. Ordinary CI skips the test when the input paths are absent.

Set these environment variables before running:

- `XCLIENT_TEST_CONFIG`: private JSON containing `email`, `password`, `brand`, `endpoint`, `ctrl_pub_keys` and `env_pub_keys`. The brand must match the server configuration. Optional `obf_key` and a complete `defines` map are supported.
- `XCLIENT_TEST_CERT`: PEM certificate explicitly trusted only inside the probe process. Product TLS verification is unchanged.
- `XCLIENT_TEST_WATCH_NOTICE`: a unique test marker that the changed signed notice title must contain.
- `XCLIENT_TEST_ARM_FILE`: optional path to a new flag file. After the probe emits `READY`, create the flag and immediately mutate the isolated panel's notice. The signed change must arrive within ten seconds of the flag being observed. An existing flag is rejected.
- `XCLIENT_TEST_REQUIRE_PIN`: optional `report` or `enforce`; requires the verified bootstrap's host pin to match the supplied certificate.

Run from the repository root:

```powershell
flutter test --no-pub test/xboard/integration/probe_instance_test.dart --reporter expanded
```

To run only the short TLS pin regression, set the config and certificate paths and use:

```powershell
flutter test --no-pub test/xboard/integration/probe_instance_test.dart --plain-name 'real isolated TLS SPKI pin policy and push rejection' --reporter expanded
```

This derives the supplied leaf certificate's SPKI and checks matching enforce, mismatched report and mismatched enforce policies against the real HTTPS endpoint. The mismatched enforce request must fail before sending HTTP. It also checks that a push request carrying a synthetic ticket fails at the pin check, rather than reaching an HTTP unauthorized response. This case does not log in or require notice mutation. Certificate trust is added only to the test process; product certificate validation is unchanged.

The probe checks login/device registration, signed bootstrap, a nonempty decrypted subscription, a real SSE connection and a newly verified policy/notice. It temporarily uses a five-minute foreground polling interval during the ten-second push test, then a sixty-second background interval to exercise the actual polling timer quickly. The product's default 900-second background interval is unchanged. It checks foreground reconnection, logout cleanup and rejection of the revoked token.

Only safe event summaries are printed: versions, counters, timing, payload length/hash and fixed error classes/codes. Credentials, keys, device secrets, endpoint values, node names and subscription bodies are never printed. Private JSON, certificates, flags and live logs belong in ignored project-local operational storage, never in public source control.
