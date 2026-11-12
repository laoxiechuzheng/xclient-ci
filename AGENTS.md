# AGENTS.md

> XClient fork: read `REQUIREMENTS.md` first, then `HANDOFF.md` and `lib/xboard/DESIGN.md` when present (requirements are tracked in this private repository; detailed operational handoff stays local). New XClient code lives in `lib/xboard/`, `tool/xclient/`, `test/xboard/`. The ledger distinguishes implementation, verification, and user acceptance; handoff reports alone are not current verification evidence.

This file is the entry point for AI coding agents working in this repository. Keep it small: detailed guidance lives under
`.agents/`, and discoverable repo skills live under `.agents/skills/*/SKILL.md`.

## Start Here

Read these files before making changes:

- [.agents/project.md](.agents/project.md): project overview, versions, and build dependencies.
- [.agents/commands.md](.agents/commands.md): build, development, code generation, and test commands.
- [.agents/rules.md](.agents/rules.md): lint, testing, generated-code, and workflow rules.

Read these only when the task touches their area:

- [.agents/architecture.md](.agents/architecture.md): core integration, providers, database, managers, build system, and
  local plugins.
- [.agents/setting-changes.md](.agents/setting-changes.md): whether a changed setting is patched live, re-applies the
  profile, or asks for an Android VPN restart.
- [.agents/surfaces.md](.agents/surfaces.md): fill levels, selection and status colors, and the few borders that
  remain, for any change to how a surface is colored.
- [.agents/agent-config.md](.agents/agent-config.md): how to choose between `AGENTS.md`, `.agents`, skills, Codex config,
  command rules, and hooks.
- [.agents/worktrees.md](.agents/worktrees.md): worktree hygiene across Claude Code, Codex, and Gemini.
- [.agents/flutter-upgrade.md](.agents/flutter-upgrade.md): SDK-pinned workarounds to recheck before changing the
  Flutter version.
- [.agents/skills.md](.agents/skills.md): index of repo-scoped skills in `.agents/skills/`.

## Highest Priority Rules

- When the user explicitly requests a scoped, low-risk change, inspect the relevant context and implement it directly.
  Do not require brainstorming, design documents, implementation plans, multiple-option proposals, or repeated confirmation.
  Ask only when material ambiguity, destructive impact, additional authority, or scope expansion could change the result.
- The request sets the scope. A pre-existing bug, cleanup, or refactor the task did not ask for is a follow-up in the
  summary, not part of the change. Edit a file surgically when a rewrite would give the same result, keep scratch checks
  out of the repository, and commit tests only where the task asks for them or the neighbouring code already keeps them.
- Comments are allowed and sometimes necessary; excess is the problem. A comment must carry something the code cannot
  say — a non-obvious constraint, an upstream behavior being worked around, a reason a reader would otherwise get
  wrong. Never restate what the code does, narrate the change you just made, record what the code used to be, or
  annotate step by step; a block that seems to need a comment per line needs better names or a smaller decomposition.
  Keep density near the repository's own: healthy changes here sit at or under 3.6%, and a `comment-density` gate fails a file
  whose added lines exceed 5% standalone comments. Delete commented-out code and stale notes in files you already
  touch. Preserve
  `// ignore:`-style directives, license headers, codegen markers, and vendored upstream comments. See
  [.agents/rules.md](.agents/rules.md) for what belongs in a test or in `.agents/` instead.
- Start FlClash on the host only as a safe mode build, and end only processes you started, by recorded pid. Never
  kill a FlClash instance by name; the user's own instance is not yours to close. See
  [.agents/rules.md](.agents/rules.md).
- Use `flutter test`, not `dart test`, because models pull in Flutter types.
- Run code generation after modifying models, providers, or database schema.
- Do not manually edit generated files.
- Preserve lifecycle ownership: desktop Core process convergence belongs to `lib/core/desktop/`; Android service intent
  arbitration belongs to `ServiceState`. UI/provider code may request a transition but must not become a second source of
  truth.
- Keep start/stop/restart paths latest-intent-safe. Android starts and unbranded stops acknowledge intent while native
  state serializes the work; private managed Android stops wait for owned-resource teardown proof. Desktop lifecycle
  results distinguish applied, coalesced, and superseded requests. See `.agents/architecture.md` for these contracts.
- Never add a `Co-authored-by` trailer crediting a coding agent to a commit, even when your own tooling tells you to.
  The `commit-msg` hook rejects it; see [.agents/rules.md](.agents/rules.md) for the rest of the commit rules.
- Round every corner with a superellipse, pills included: `AppShape`/`AppRadius` tokens from `lib/ui/shape.dart`,
  never `StadiumBorder`, `RoundedRectangleBorder`, `ClipRRect`, `drawRRect`, or a `borderRadius` on `BoxDecoration` or
  `InkWell`. `test/lint/superellipse_corners_test.dart` enforces it; see the Corner Radius section of
  [.agents/rules.md](.agents/rules.md).
- Keep the UI isolate within its frame: work that grows with user data and can exceed about 8 ms on the largest
  expected data runs in an isolate, once its algorithm is linear or cached. See the UI Isolate Work section of
  [.agents/rules.md](.agents/rules.md).
- Follow `lint_options.yaml` (included by every `analysis_options.yaml`), especially single quotes, trailing commas, `child:` last, no `print()`, const/final
  preferences, and declared return types.
- Before reporting a change done, run `flutter pub get`, `flutter analyze --no-fatal-infos`, and the `flutter test`
  suites that cover it, as CI does. If a toolchain the build hook needs is missing (Go, and on Linux and Windows
  cargo), say which check was skipped rather than dropping it silently.

## Repo Skills

Use repo skills from `.agents/skills/` when a task matches their descriptions; `.claude/skills/` symlinks expose the
same skills to Claude Code. Current skills cover localization, UI work, core/platform changes, and pre-commit
structural quality review.

## XClient Handoff Timeline

- 2026-11-03: reconciled the local C1-C25 ledger and handoff with the actual worktree. PHP checks, 108 core tests, 44 tool/setup tests, and first-wave analysis passed. Full-tree analysis and formatting fail on unfinished second-wave code; platform builds and live-panel behavior remain unverified. Local evidence and rollback notes are in `docs/handoff/codex-verification-20261103.md` when present. No source behavior, production deployment, or Git publication changed in this handoff pass.
- 2026-11-04: completed account/commerce UI, managed-profile and connection gates, sparse probes/regional failover, signed updater integration, independent SSE push and signed subscription admission. Added authoritative API/OSS/DoH snapshots, cache/mini catch-up and safe discovery rescue;fixed async session/transport/pin boundaries. Final checks:306 tests,23 branded checks,full analysis and format/density gates passed. Real isolated HTTPS tests covered subscriptions,SSRL JSONL,40 push streams,revocation/polling/pins and3941ms pool migration → new OSS recovery → cache restart. Local evidence:ignored `docs/handoff/codex-integration-20261104.md`. Original Windows static-guard failures and one upstream LinkReceiver failure are documented;no guards were weakened. Native hooks were restored with matching snapshot hash. Native packages/installations,real brand rescue resources,Git publication and production remain pending. Preserve project-local snapshots and do not add agent co-author trailers.

- 2026-11-04 user update: client and brand repositories must be private (supersedes the original public-source plan). New commits use neutral anonymous author metadata; preserve upstream history/license. Credentials/deploy-key setup and build-only Actions are now authorized;no tag/Release or production changes. Track REQUIREMENTS.md here,keep detailed operational handoff/research/live fixtures and all signing secrets local.

- 2026-11-04 CI follow-up: first private run compiled Windows debug and passed PHP. Fixed missing checksum-pinned CA preparation, migrated Android scripts to current typed AGP APIs without suppressing diagnostics, and added safe-mode desktop debug artifacts. Scoped per-brand secure-store physical keys/Darwin services;313 local tests and analysis passed. macOS arm64 scheduling failed before compilation,so CI uses verified macOS15/Xcode26 images. TUN control-plane egress still needs investigation:do not treat HTTP DIRECT/Rule-only host rules as a Global-mode guarantee.

- 2026-11-04 DIRECT/CI follow-up: added a bounded one-use loopback TCP broker in the existing Go Core and a shared cancellable Dart connector for all control HTTP consumers. Target TCP uses resolved IP plus existing native socket protect/interface control; Dart preserves original-host TLS/CA/SPKI. No Mihomo submodule patch or new dependencies. Local416 tests/6 conditional skips,Go scoped27 groups/7 subtests,stdlib16 groups x10,three-target vet and real Go-Dart TLS component passed;physical TUN and the existing SystemResolver numeric-nameserver-hosts edge remain unverified/limited as recorded in REQUIREMENTS.md. CI3 compiled all three safe example platforms;safe Windows UI moved to Profile after debug-CRT loader failure. The dead-file guard now counts top-level functions and normalizes Windows paths,with actual RED/GREEN and no exemptions. Build-only release runs now sign/verify facts into private Artifacts;only tag-push publish has write permission. No tag/Release/production change;local detailed evidence is in docs/handoff/codex-direct-*.md/log when present.

- 2026-11-04 native/account follow-up: CI4 all7 jobs passed,including Linux Go full/race/real TLS. Inspected the actual safe Windows Profile login frame from its own read-only Flutter engine after RDP sessionDisc blocked OS capture;only recorded app/Core PIDs were stopped and proxy/TUN snapshots were unchanged. Real isolated account/commerce scenario passed with balance/free orders and decrypted nodes1→2→3;initial main-only SQLite copy missed WAL and was never restored,consistent logical cleanup/backup is documented. Added strict raw/Gateway-envelope bootstrap compatibility and Android per-ABI collector. The first three-brand release run hit Android disk at 3ABI AAR packaging;18job per-ABI matrix and Mac native frame capture are prepared. C21 audit found native automatic health-check bypass;do not claim sparse scheduling fully enforced until the core admission feature is fixed. Production public-HTTP backhaul is an explicit C3 blocker;verified TLS-origin/6202x transport-upgrade materials and isolated cache/Caddy gates are being prepared without production writes. No tag/Release or production permission is implied.

- 2026-11-04 managed admission follow-up: fixed the native automatic health-check bypass with a9-line pinned Mihomo feature hook, carried as a main-repo patch;gitlink stays c506292 and ordinary no-tag builds remain unchanged. This is a feature that has nowhere else to live,within the submodule patch budget:the hook runs before URLTest network/state updates. Brand apply validates/applies it and adds xclient to existing Core tags;never stage a new gitlink or reset others' module edits. Added current-session signed policy admission,verified cache/floor and same-turn live gates,plus managed Android cold-start deferral before saved config/quickSetup;temporary in-App waits do not hard-stop an existing run,cold App takeover keeps its previous stop rule. Fresh488 tests/19 conditional skips and35 branded checks,full analysis/139-file format/density passed;independent C21 and C10 reviews found no reproducible P1/P2. Local JVM7 and API35 prompt checks do not replace Android OS/API37/AAR acceptance. Build-only CI5 earlier-source23 jobs succeeded including all brand packages/facts;Mac safe engine capture failed because Impeller rejects compressed screenshots,so safe build now matches shipping universal renderer and must rerun actual frame verification. Strict TLS/Web/distribution materials passed2457 structural checks and real isolated7-server/25-include nginx -t;production and native installation/TUN remain pending. No tag/Release/production action was performed.

- 2026-11-04 canonical identity follow-up: actual CI5 Mac package CFBundleShortVersionString1.0.0.1 exposed a prerelease connection blocker despite previous green tests. Brand tool now supplies a complete canonical SemVer/raw-build pair from the same effective version as pubspec,CLI overrides brand default;ClientInfo consumes it,UA preserves safe prerelease tokens,and explicit same-SemVer minimum build is enforced. Native installers/OS version rules and release-version grammar remain unchanged. Fresh523 tests/19 conditional skips plus59 branded/compiled-pair tests,full analysis/140-file format and independent review passed;new native packages and actual identity smoke remain pending. CI6 at6a8ab04 passed all7 jobs including Go feature/vet/race/TLS,Android full APK/JVM and both desktops;actual Mac login frames at6s/22s were inspected,owned processes cleaned and network snapshots unchanged. Do not confuse this earlier-source CI with validation of the subsequent canonical fix. Plugin deployment materials remain local-only;47-file LF/Git roundtrip and2506 checks passed after correcting Windows text hashes,with identical38 production operations/guards. Production and new Android emulator dependency approvals remain pending.

- 2026-11-04 native acceptance follow-up: CI7/61b7da1 all7 base jobs and23 build-only jobs passed;actualMac runtime reports pre.1+10000401 while OS plist is1.0.0.1,stable login frames inspected;Android JUnit XML confirms78 tests with7 managed cold-start cases,zero failures/skips. CI7 signedfacts independently verified with PHPlibsodium,21checksums/15assets and9APK library/CRC checks. Added CI-only synthetic native storage target/launcher with owner/nonce/generation gates,atomic receipts/UTF8 and strict cleanup;this is not yet native storage acceptance. Fixed Android pending-user notification to retain the system confirmation as immutable session-specific PendingIntent across app process death;local6-case real-body fixture/API35 compile and independent review pass,OS confirmation stillpending. Ordinary branded Back now reuses one CommonPopScope+existing close policy,inner navigation first;15new cases/70combined andWidget render pass,independent review foundnoP1/P2. Root staged-scope544 tests/19conditional skips,fullNoissues/read-onlyformat andPython10 guards pass. Do not claim whole-VPN-lifetime C9/C22:actualActivitydestroy leaves native VPN without Dart;the single-engine/background-control and explicit-Quit-disconnect proposal requires user alignment. Realself-update QA/localhost-nativefailover fixtures are separate in-progress work,not accepted products.

- 2026-11-04 native storage result: CI8/563b8c2 passed all7 jobs. Its real Windows Credential Manager and macOS Keychain QA passed synthetic write/read, reopen, replacement, isolation and deletion; actual native frames and structured receipts were inspected, bundle/network hashes unchanged and owned processes stopped normally. Cross-version storage remains a separate pending update test. New C22 loopback integration demonstrated real Core log delivery, production Dart recovery and actual HTTP through the same-region replacement; the negative log-delivery control failed convergence. Full runtime/lifecycle, real nodes and TUN are outside this component result. New manual-only native update workflow and failure guards passed independent review:6 Dart/17 Python plus10 existing guard cases, full analysis and shell checks passed. The exit-failure receipt and frozen packaging-input/real-registry checks address review findings; actual installer execution remains pending. Production, official Android emulator and background-engine approvals remain pending; no dependent action is authorized by silence.

- 2026-11-04 default recovery follow-up: actual App defaults error, so the previous debug-only Core fixture missed suppressed WARN dial failures. Managed logPump now forwards at least WARNING through internal RPC without changing stdout/user level or ordinary builds; branded CoreManager filters display/buffer independently. Settings actual value changes invalidate both failover generation and multi-hop intent, preserving already-sent RPC boundaries and no-op settings. Real error-config failure RED→GREEN+HTTPviaB, Go tagged/default matrices,7 setting cases and independent review pass. Root fresh568 tests/27 conditional skips+66 branded+1 logging/runtime,fullNoissues/149format0;hooks restored7F31/two true. Added explicit actual-Core failover and branded log checks to base CI. This remains component/runtime evidence,not physicalTUN/OSbackground acceptance. Native-update QA36d922e manual run41764178646 is still pending:Mac first build used old Xcode16.4 because the new workflow omitted the established26 selection;fixing that test setup,not weakening Swift checks.

- 2026-11-04 native update diagnostic follow-up: real Windows initial Inno installation/registration/version/files and synthetic storage write succeeded,then update handoff failed;Mac Xcode26 correction compiled both releases and initial bundle/runtime/store checks passed,but handoff failed with a generic cause and cleanup unconfirmed. No successful native update is claimed. Added only finite QA diagnostics(checkpoint,typed exception category,allowlisted manager phase/code/progress/has_manifest),excluding URLs/details/messages/keys;product behavior and RED gates unchanged. Real-manager controlled HTTP test rules out early busy return,9 QA cases and fresh fullNoissues/format passed,independent review found no leak/P1/P2. Test branch keeps main6d3e467 CI running while the next manual native run gathers the actual cause.

- 2026-11-04 TLS diagnosis: finite native receipts isolate Mac failure to policyFetch/handshake and Windows to helperIdentity after verified download. Added manual SDK-only Mac TLS mode to compare default fixture trust, appended Mozilla trust, explicit fixture context and an independent untrusted negative control using new loopback ports. All certificate callbacks reject,original certificate argv is shared unchanged,no system CA/App install/new dependency;receipt whitelist and local refusal guards reviewed. Exact SDK native source adds certificates,so replacing/loosening product trust is unsupported. Actual runtime probe remains pending;Windows harmless process lifecycle diagnosis is separate.

- 2026-11-04 certificate fixture correction: real SDK TLS probe rejected fixture trust in all positive contexts;public certificate receipt showed a CA certificate used as leaf without EKU/KU. QA now creates a constrained one-day RSA2048/SHA256 RootCA and separate CA:false serverAuth leaf with DNS/IP SAN,serves full chain and imports only ca.crt. No product TLS or bad-certificate policy changed. Actual offline certificate RED→18 Python GREEN,purpose/hostname/IP checks and wrong-host rejection passed;real Mac SDK GREEN remains pending.

- 2026-11-04 Windows update helper correction: exact-SDK harmless PowerShell tests showed detached and detachedWithStdio exit before script start,while normal uses CREATE_NO_WINDOW and survives parent exit. Product startDetached and native QA now share spawnUpdateHelper;Windows closes stdin/drains output without waiting for helper exit,other platforms retain detached and existing injection interfaces. Identity/force/installer arguments unchanged. Root31 update/native-contract cases including actual parent-exit witness,full analysis/format passed;real Inno update,restart and cross-version storage still require native CI.

- 2026-11-04 approved Android retained-engine integration: branded builds retain one application-context engine through Activity detach. Bootstrap anchors NoView control,and CoreLib owns native event forwarding independently of AndroidManager widgets. Managed stops preserve actual runtime until generation-owned TUN/service teardown is confirmed;unknown close,failed partial start and service-switch cleanup retain ownership and permit retry. Explicit Quit closes runtime/DIRECT/Core only after confirmation. Existing unbranded acknowledgements and PackageInstaller confirmation ownership remain compatible. Component evidence:617 Dart pass/30 conditional skips,4 branded raw-Service→Core→region cases,full analysis Noissues;root137 critical+4 branded andJVM14+4 pass. Actual API37/AAR/OS retention,visible logged-out Quit and active-VPN/Doze acceptance remain pending. See local `docs/handoff/codex-android-engine-integrated-20261104.md`;Git holds the rollback source. Production remains on hold underC34.

- 2026-11-04 native follow-up: real API37 APK/AAR and103 Android JUnit cases pass in41796547170;Go full/race/DIRECT TLS/recovery and Windows/Mac builds also pass. Fixed fresh-checkout screenshot-parent creation and registered only App's two new process-lifetime notifiers in the existing exact-field lint policy;normalized lint keys across Windows/POSIX. Added Android-only visible Quit before login and in client settings,using the existing confirmed-stop coordinator. Root47 UI/back/exit/lint regressions,8 final action cases and scoped Noissues pass;320px login/settings/failure frames inspected. Full CI and actual OS Activity/isolate/quit still pending;no TUN/production action was performed.

- 2026-11-04 C35/native acceptance follow-up: complete CI41801669779/source9356ec1 passed all7 jobs,including103 Android JUnit tests and actual API37/AAR/full upstream/XClient/desktop/Go tests. C38 explicitly permits only a fresh owned CI data Keychain and generated password for one scoped AlwaysAllow;default disabled,no original-login password/noTCC request. Read-only AX41810306003 passed. First control41816424731 reached V2hello but failed on a disappearing child;data cleanup refused a live unadopted V2,so restore/material cleanup remains unconfirmed. Added narrow gone-candidate proof,strict late-V2 adoption and final residual-process refusal;108 Mac guards pass. Mac41817889073/source86c5f82 remains under test. Android41810201223 installed/hash verified but native splash only/bindingReady;68 guarded startup/lifecycle tests plus SDK analysis/format passed for network-readiness and owned read-only VM diagnostics,actual41817782069 pending. C34 production hold/private/no tag/Release unchanged. Detailed local evidence and remaining boundaries are in REQUIREMENTS.md.


## 2026-11-04 原生验收与C35三品牌复核（继续进行中）

私有QA分支继续，main暂保原状态，生产按C34不改。C35三品牌刷新41837661746/source018cbeb的23任务成功/publish跳过；已独立复核实际3发行签名、21SHA256、15资产绑定、9APK的90ELF/证书/元数据及21双架构MachO。三Windows安装包Authenticode实测NotSigned，未安装正式品牌包。证据为本机docs/handoff/c35-package-refresh-20261104/REPORT.md。

Mac shipping-ad-hoc SAFE对照41851246018/sourcefb0cead真实出现自有临时dataKeychain/nonce服务系统框，C38范围内一次AlwaysAllow后跨版读改删、原始更新/身份/退出、网络/owned进程/安装及原default-login-search恢复/临时材料删除全部通过。根已读回执并看PNG；原login密码未访问、AX权限未申请。仅CI宿主架构单合成项有系统确认实测，非所有真实会话键或无人值守兼容；报告codex-native-macos-owned-accepted-20261104.md，110Mac工具守卫通过。

Android实际b659ae1/run41846671528健康桌面/冷启/ANR/网络与清理通过，输入框已滚动曝光且首8字PNG正确，但15s观察预算截断。观察工具独立缺陷已补：唯一nonce XML文件与确切生成成功标志、有限重读/耗时诊断；每段45s/总≤600s，完整prefix/焦点/ownership仍必需，106工具守卫通过。完整确认/登录/Activity-isolate连续性/明确退出仍待真实同源CI；不改App同意条件，不开TUN/代理，不把预览构建当用户验收。后续准确run和状态始终读REQUIREMENTS.md进行中。

- 2026-11-05 Android QA:separated only the one confirmed-consent transition from bounded restatement input;actual67147c4 had full195characters/Confirm but expired the pre-consent100s deadline. Exact2f274e6 normal-main CI41868452571 remains active. Added a separate minimal SAFE production-installer/synthetic-store component,pairedProfileAPK/V2digest/same-certificate/source-run-artifact gates,and exact preinstalled system-UI ownership before permission/update actions. Default lifecycle gates preserved. Root126Python+7Dart/3-file Noissues/format0/40bash blocks and YAML guards pass;actual component OS execution remains pending. No production/tag/Release/Appdependency/CIsecret changes;pubspec7F31 and Mihomo carrier preserved.

- 2026-11-05 actualAndroid result:41868452571/source2f274e6 passed consent/login/empty-form/Home-Back/samePID and network/ownedcleanup;root inspected3nativePNGs. Lifecycle0replacements/Quitnotreached,owned_vm_address_unavailable. New owned-PID regex/no300-tail query keeps16KiB/authURI/getVM gates,128Python guards pass;actual cause/query stillunverified. Androidcomponent95e9eea/run41871377423 failed before runner allocation due GitHub payment/spending limit;step_count0. UserActionsrestoration pending,no billing/visibility/runner changes or retryloop. Detailed local report codex-android-login-and-billing-20261105.md. C34productionHOLD;goalactive/no completion notification.

- 2026-11-05 installation handover:added Chinese INSTALLATION.md for the three brands,platform package choice,system confirmations,account/restriction/pool/update flows and exact verified/pending scope. Linked both READMEs and tool guide;corrected NotSigned/self-signing conflation.18 actual artifact names/2local links/3entry points checked;official Apple/Google/Microsoft instructions consulted. No runtime/dependency/credential/production change. Android actual CI remains awaiting userActionsbilling restoration.

- 2026-11-05 blocked audit:the Actions payment/spending-limit condition recurred for3 consecutive goal turns. Existingruns41871377423/41868452571 are terminal;no livejob. LocalapprovedSDK has noemulator and noVSInstaller/vswhere onWindows10.0.26100. Authorizedlocalpreparation and installationguide are saved/pushed;actualAndroid lifecycle/update and formalbrand/production gates remainunproven. Await userActionsrestoration;no blinddispatch/billing/visibility/runner/dependency/production changes. This is an external blocker,not completion;see REQUIREMENTS.md CURRENT_WORK and local billingreport.
