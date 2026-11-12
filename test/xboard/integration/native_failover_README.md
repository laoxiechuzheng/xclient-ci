# Opt-in native Core / Dart same-region failover

This fixture uses the actual xclient-tagged Go Core, its mixed HTTP listener, real HTTP outbound adapters, the ordinary Core RPC handlers and event queue, `CoreController`, `ProbeScheduler` and `RegionFailover`. It does not launch FlClash, a helper, TUN or a system proxy. Every server and destination is a newly allocated `127.0.0.1` port in the owned test process. It never uses real nodes or a public delay-test URL.

The Core configuration now uses the App's default `log-level: error`. An xclient build forwards internal warning/error RPC events even when the user's console threshold is stricter; the native console threshold is unchanged. The branded `CoreManager` applies the user's requested level before saving/displaying those events, while the independently registered `XcProbeRuntime` still receives them for failure detection. The normal build without the xclient tag retains its previous RPC threshold.

Build with the repository's pinned Go toolchain/modules and the already-applied xclient mihomo carrier:

```powershell
$env:CGO_ENABLED = '0'
cd core
go test -mod=readonly -tags=xclient -c -o ../.dart_tool/xclient-native-failover.exe .
cd ..
$env:XC_FAILOVER_TEST_BINARY = (Resolve-Path .dart_tool/xclient-native-failover.exe).Path
flutter test --no-pub test/xboard/integration/native_failover_test.dart --reporter expanded
```

The standard test run skips only this fixture when `XC_FAILOVER_TEST_BINARY` is absent. Running the compiled Go test without `XC_FAILOVER_TEST_BRIDGE=1` also skips the harness. The Dart owner generates a fresh 32-hex nonce for every process and every command must match it. Its only additional commands stop the fixture's A server, perform a fixed HTTP request through the fixture Core and return bounded counters; none are shipping RPCs. EOF shuts down Core/listeners and the fixture servers, and the Dart test requires process exit zero. A deadline kill is failure containment, never a successful cleanup receipt.

The fixture proves US-A is available by one explicit Core probe, then runs one normal scheduled probe of JP-A. Actual traffic first reaches A. Closing A's listener causes three genuine Core traffic failures; native log frames travel through the existing Dart Core event dispatcher into `RegionFailover.observeLog`. The emergency queue confirms A, checks the same-region candidates with its existing limit of two, selects healthy B through the real `changeProxy` RPC and reads back the Core group's `now`. A final HTTP request must actually traverse B. JP-C deliberately accepts the proxy handshake and then fails, allowing the real emergency concurrency bound to be observed; US-A's dial count must not increase during recovery. The receipt includes A/B/C/US dial counts, normal/emergency RPC concurrency and real proxy-connection concurrency.

For the negative control, set `XC_FAILOVER_TEST_NEGATIVE_CONTROL=1` before the same Dart command. This disconnects only the fixture log-to-recovery delivery, preserving the actual native traffic failures. The unchanged convergence assertion must fail because the Core remains on A. Unset the variable for the positive run. This demonstrates a live failure oracle; it is not a product algorithm change.

The test composes the real scheduler/failover classes directly. It does not mount `XcProbeRuntime`, the account providers, a Flutter window or the complete App. Therefore it does not establish Android Activity retention, TUN/protect behavior, real-world latency, GFW behavior, arbitrary nested-group UI binding or OS background survival. The runtime binding unit tests and separate platform acceptance remain necessary.

## Initial fixture evidence, 2026-11-04

- Tagged Go build with `-mod=readonly` succeeded. Its default guard test returned exit zero with an explicit skip, and an actual nonce-owned subprocess produced a loopback-only ready frame and exited zero on EOF.
- Negative control returned exit one after 10 real connection-refused log events. Core read-back still selected A; native dial counts were A=12, B=0, C=0, US=1. The failure is the recovery convergence assertion, not a compile/TLS/fixture setup error.
- Positive control returned one passed test and a zero-exit Go child: selected B, HTTP actually through B, eight refused log events, dials A=11/B=3/C=1/US=1, normal RPC maximum=1, emergency RPC maximum=2, native proxy connections maximum=2. Native traffic may retry, so recovery can make a later fault-triggering HTTP request succeed through B; the trigger is counted from real failure logs rather than assuming three failed HTTP responses.
- Scoped Dart analysis reported no issues, formatting and the owned comment-density check passed. Local logs are `docs/handoff/codex-native-failover-{red,green,analyze,go,density}-20261104.log`; hooks were restored byte-for-byte after each Flutter test. This initial fixture stage changed no production source, but used debug logging and did not establish the App's default error threshold behavior.

## Production logging threshold regression, 2026-11-04

Changing the real fixture to the App's default error level exposed the missing internal failure events: actual Core read-back remained A, native dials were A=32/B=0/C=0/US=1 and no failure log reached Dart. This failed the explicit native-log assertion (`codex-native-failover-logfloor-red-20261104.log`). Only RPC log delivery and branded UI filtering were corrected; no probe or routing algorithm was changed. With the same error-level fixture, the test then passed: Core B, HTTP via B, eight refused events, A=11/B=3/C=1/US=1, normal maximum=1/emergency=2/native=2 and zero-exit child (`codex-native-failover-logfloor-green-20261104.log`).

Go tests exercise the pump's debug/info/warning/error/silent matrix in both tagged and default builds and assert that `log.Level()` remains unchanged. A branded widget test covers error and silent filtering with an actual, separately registered `XcProbeRuntime`: three warning events still cause its confirmation RPC while the UI buffer excludes them; silent also suppresses the raw error notification. These widget RPC replies are controlled test responses; the separate native fixture remains the evidence for actual network failure and Core selection.

The exact branded widget invocation is:

```text
flutter test --no-pub --dart-define=XC_BRAND_ID=example test/manager/core_manager_test.dart --plain-name "branded error and silent hide internal failure logs while runtime still confirms"
```

The focused branded widget passed; the ordinary complete manager file separately passed 17 tests with one branded skip. Both Go threshold matrices and both default/tagged `go vet` checks passed. Evidence uses `docs/handoff/codex-logfloor-{go-red,go-tagged-green,go-default-green,ui-red,ui-green,manager-baseline,analyze,density,vet}-20261104.log`. The native production-threshold regression uses the separate `codex-native-failover-logfloor-{red,green}-20261104.log` pair.
