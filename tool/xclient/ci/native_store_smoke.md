# Native secure storage QA target (CI only)

This is an alternate, synthetic-data-only desktop target. It imports secure storage, ClientInfo and the existing window plugin; it never imports the normal application bootstrap, Rust initializer, XClient runtime, Core controller or proxy manager. Runner plugin registration alone does not start Core/VPN. No existing workflow is changed by these files.

Use a GitHub-hosted Windows/macOS job with the example brand already applied at version `1.0.0-pre.1`. All steps below run in the same job/workspace. `prepare` requires a new output directory and creates a fresh nonce/job-bound defines file before the build. `run` verifies fresh generated Flutter target/defines plus a newly generated Dart payload; it launches only a new copy inside that output directory, records PID/start/executable identity and manages only that child. Raw application output is never saved or printed; only typed boolean diagnostics survive. No permission dialog is accepted and no OS security setting is changed.

Windows (PowerShell, existing Profile runner and toolchain):

```powershell
python tool/xclient/ci/native_store_smoke.py prepare --platform windows --output "$env:GITHUB_WORKSPACE/out/native-store-windows"
flutter build windows --profile --no-pub --target=test/xboard/native/secure_store_app.dart --dart-define-from-file=out/native-store-windows/defines.json
python tool/xclient/ci/native_store_smoke.py run --platform windows --state out/native-store-windows/build.json --bundle build/windows/x64/runner/Profile
```

The optional `native_store_smoke.ps1` wrapper accepts `-Mode prepare -Output ...` or `-Mode run -State ... -Bundle ...` and supplies the platform after the same CI gate.

macOS (Bash, existing Debug/ad-hoc runner with `FLTEnableImpeller=false`):

```bash
bash tool/xclient/ci/native_store_smoke.sh prepare --output "$GITHUB_WORKSPACE/out/native-store-macos"
flutter build macos --debug --no-pub --target=test/xboard/native/secure_store_app.dart --dart-define-from-file=out/native-store-macos/defines.json
apps=(build/macos/Build/Products/Debug/*.app)
[ "${#apps[@]}" -eq 1 ]
bash tool/xclient/ci/native_store_smoke.sh run --state out/native-store-macos/build.json --bundle "${apps[0]}"
```

The app independently requires compiled `SAFE_MODE=true`, `XC_BRAND_ID=example`, `XC_NATIVE_STORE_QA=true`, matching compiled nonce/job/output, actual GitHub CI environment and a launch receipt naming its own PID/executable. It uses three nonce-derived `q...` brand IDs and one shared nonce-derived logical key, with distinct synthetic values. It verifies canonical ClientInfo, write/read/reopen/replace, cross-namespace absence and isolation, individual deletion, then finally attempts cleanup of every key confirmed initially absent. Existing colliding values are preserved and fail the run. Read failures swallowed by the production wrapper are detected through its existing safe log sink; they cannot count as absent/deleted. Every native operation is bounded; a timeout permanently marks cleanup unconfirmed and fails.

Output artifacts:

- `result.json`: only booleans and fixed error classes, written by the QA app before exit; every required check must be true.
- `qa.png`: a RepaintBoundary image after a real Flutter frame in the native runner. This is not an OS-window capture. Review the actual CI PNG before platform acceptance.
- `runner-result.json`: launcher success/cleanup/network/build booleans and safe errors. Missing receipt, permission/native errors, timeout or unconfirmed owner cleanup fail the job; there is no skip-to-pass path.
- `build.json`, `launch.json`, `defines.json`: synthetic job/nonce, own process/build identities and example compile inputs. They contain no real account values or signing material. Storage key/value contents and device names are never included.

The launcher compares hashes of system proxy settings and interface identities before/after without printing their contents. No socket listener, Core process, TUN or system proxy is requested by this target. It does not test account login, live network routing, update installation or real brand credentials. Native Credential Manager/Keychain behavior, permissions and the macOS process adapter still require actual CI; local mocked tests are not native acceptance. A forced timeout can leave only the recorded synthetic namespace unconfirmed; it is reported as failure and never hidden by broad credential deletion.
