# tool/xclient：品牌、密钥、构建与发版

本目录是 XClient（FlClash v0.9.2 的 GPL-3.0 fork）的品牌化和发版工具。契约见 `docs/DESIGN.md`（§0 产物命名、§5.1 bootstrap、§7 更新、§10 构建与发布）。

| 文件 | 作用 |
|---|---|
| `brand_apply.dart` | 按 `brands/<id>/brand.json` 改写本次构建的原生标识，并生成 `xclient_defines.json` |
| `xsign.dart` | Ed25519 离线密钥与签名文档：`keygen` / `pub` / `sign-release` / `sign` / `verify` |
| `collect_artifacts.dart` | 把构建产物复制成 DESIGN §0 的发布文件名 |
| `macos_universal.sh` | 合并 arm64 与 x86_64 两份 .app 为 universal，ad-hoc 重签，打 dmg 和更新用 zip |
| `gen_placeholder_icons.dart` | 生成占位图标 overlay（`brands/example` 就是用它生成的） |
| `src/` | 上面几个工具共用的库（brand.json 解析、改写规则、命名、签名） |

测试在 `test/xboard/tool/`。

产物收集 CLI：

```bash
dart tool/xclient/collect_artifacts.dart --brand example --version 1.0.0 \
  --platform android --android-abi x86_64 --from dist --to out
```

可选 `--android-abi` 只适用于 Android，接受 `arm64-v8a`、`armeabi-v7a`、`x86_64`，供每品牌/ABI独立构建 job 使用；分别对应 `setup.dart --arch arm64`、`arm`、`amd64`。提供该参数时必须存在选定 ABI 的 APK，任何其它 ABI、无法识别 ABI 或混合 ABI 名称的 APK 都会在复制前拒绝，普通 metadata 文件仍忽略。不提供时保持原行为：要求 arm64 APK，同时允许收集其它 ABI。Windows/macOS 不接受此参数。

## 1. 品牌资料从哪里来

公开仓库只放 `brands/example`（演示品牌，占位域名和用后即弃的演示公钥）。真实品牌放在私有仓库 `laoxiechuzheng/xclient-brands`，CI 用只读 deploy key 检出到 `brands/`。`.gitignore` 已忽略 `brands/*`（`brands/example` 除外）、`xclient_defines.json`、`*.jks`、`*.keystore`、`*.seed`、`/keys/`。

私有仓库布局：

```
xclient-brands/
├── 98k/
│   ├── brand.json
│   └── overlay/                      # 可选，按仓库根目录的相对路径放图标
│       ├── android/app/src/main/res/mipmap-{mdpi,hdpi,xhdpi,xxhdpi,xxxhdpi}/ic_launcher.png
│       ├── android/app/src/main/res/mipmap-*/ic_launcher_round.png
│       ├── android/app/src/main/res/drawable/ic_launcher_foreground.xml   # 自适应图标前景
│       ├── android/app/src/main/res/values/ic_launcher_background.xml     # 自适应图标背景色
│       ├── windows/runner/resources/app_icon.ico
│       ├── macos/Runner/Assets.xcassets/AppIcon.appiconset/app_icon_{16,32,64,128,256,512,1024}.png
│       └── assets/images/icon.png                                         # 关于页图标
├── mg/
└── yzy/
```

overlay 只能写进 `android/app/src/main/res/`、`windows/runner/resources/`、`macos/Runner/Assets.xcassets/AppIcon.appiconset/`、`assets/images/`。Android 资源同名不同扩展名时（如上游的 `ic_launcher.webp` 和品牌的 `ic_launcher.png`），brand_apply 会删掉旧的那个，避免资源重复。新品牌可以先用 `dart tool/xclient/gen_placeholder_icons.dart <brand>/overlay 3F6FD8` 生成一套占位图标再替换。

## 2. brand.json

示例见 `brands/example/brand.json`。以 `_` 开头的键视为注释；其他未知键会报错。

| 键 | 必填 | 说明 | 生成的 define |
|---|---|---|---|
| `schema` | 是 | 固定 `1` | — |
| `brand_id` | 是 | `[a-z0-9]{1,16}`，必须等于目录名，如 `98k` | `XC_BRAND_ID` |
| `display_name` | 是 | 显示名，可含中文；不能含 `" \ < > &` | `XC_DISPLAY_NAME` |
| `ua_product` | 否 | UA 首段产品名，默认 `{brand_id}Client`（DESIGN §2） | `XC_UA_PRODUCT` |
| `app_id_android` | 是 | Android applicationId，如 `com.xclient.b98k`（不改 Kotlin 包名和 namespace） | `XC_APP_ID_ANDROID` |
| `bundle_id_macos` | 是 | macOS PRODUCT_BUNDLE_IDENTIFIER | `XC_BUNDLE_ID_MACOS` |
| `windows_app_name` | 是 | ASCII，Windows exe 名、安装目录名、产物前缀，如 `98kClient` | `XC_WINDOWS_APP_NAME` |
| `macos_product_name` | 否 | macOS PRODUCT_NAME（.app 名），默认同 `windows_app_name` | — |
| `windows_app_guid` | 是 | Inno Setup AppId，大写 GUID，**每个品牌固定不变**（变了就装成另一个程序） | — |
| `windows_company` | 否 | Runner.rc CompanyName，默认 `com.xclient`；数据目录为 `%APPDATA%\<company>\<brand_id>` | — |
| `publisher` | 是 | ASCII 发布者名（安装器、版权） | — |
| `publisher_url` | 否 | https | — |
| `url_scheme` | 是 | 品牌自有 URL scheme，如 `xc98k`；不能用 `clash/clashmeta/flclash/http/https/file` | `XC_URL_SCHEME` |
| `builtin_api_endpoints` | 是 | `[{"url":"https://…","weight":100}]`，非空 | `XC_API_ENDPOINTS`（`url\|weight,…`） |
| `bootstrap_sources` | 是 | OSS/CDN 上签名 bootstrap 的 https URL 列表，可空 | `XC_BOOTSTRAP_SOURCES`（逗号分隔） |
| `doh_names` | 是 | DoH TXT 的基础域名，读 `_xc.<name>`，可空 | `XC_DOH_NAMES` |
| `doh_resolvers` | 否 | 自定义 DoH 解析器 https URL；不填用客户端默认四个 | `XC_DOH_RESOLVERS` |
| `ctrl_pub_keys` | 是 | `{"ctrl-1":"<b64u 32B>", "ctrl-2": …}`，当前 + 备用，非空 | `XC_CTRL_PUBKEYS`（`kid:pub,…`） |
| `rel_pub_keys` | 是 | 发布事实文档公钥，非空 | `XC_REL_PUBKEYS` |
| `env_pub_keys` | 是 | 订阅信封在线公钥（首启兜底），可为 `{}` | `XC_ENV_PUBKEYS` |
| `obf_key` | 是 | 32 字节 b64u，bootstrap 混淆密钥（DESIGN §5.1） | `XC_OBF_KEY` |
| `panel_web_url` | 是 | 站点网页（注册、找回密码） | `XC_PANEL_WEB_URL` |
| `support_url` | 是 | 客服/工单网页 | `XC_SUPPORT_URL` |
| `version_name` | 否 | 默认发行版本，CLI `--version` 优先；同步 pubspec 与编译身份 | `XC_VERSION_NAME` / `XC_BUILD_NUMBER` |
| `release_url_bases` | 否 | 除 GitHub Release 外的下载镜像目录，可含 `{version}`、`{tag}`；写进发布事实文档的 `urls` | — |
| `icons_dir` | 否 | overlay 目录名，默认 `overlay` | — |

另外 brand_apply 从 `build_config.yaml` 的 `core_version` 生成 `XC_CORE_VERSION`（UA 里的 mihomo 版本）。

**两边必须一致**：defines 的键名和格式由 `lib/xboard/brand/brand_config.dart` 的 `BrandConfig.fromDefines` 解析（列表逗号分隔、端点 `url|weight`、公钥 `kid:b64u`）。`test/xboard/tool/brand_apply_test.dart` 会把 example 的 defines 喂给客户端解析器做往返校验，改任何一边都要跑这条测试。所有 URL 都必须是 https，且不能含逗号、`|` 或空白。

## 3. brand_apply 改什么

```
dart tool/xclient/brand_apply.dart <brand_id> [--version 1.2.3] [--check] [--brands-dir brands] [--root .]
```

- `--check` 只打印计划，不写任何文件；`--root` 可以指向一份临时拷贝做实验。
- 先算出全部改动再写，任何一处匹配失败（比如上游改了文件结构）都会在写之前报错退出，不会留下半改的树。
- 幂等：重复执行、或者换另一个品牌再执行都安全。
- **改动只用于本次构建，不要提交。**

| 平台 | 改写内容 |
|---|---|
| Android | `applicationId`、`app_name` / 通知渠道名、debug 版标签、URL scheme（替换 `clash/clashmeta/flclash`）、launcher 图标 |
| Windows | `BINARY_NAME`（exe 名）、Runner.rc（CompanyName/ProductName 决定数据目录，及文件描述）、初始窗口标题、品牌专属 core/helper 二进制、Windows 服务名与动态端口注册表键、IPC pipe 前缀、Inno Setup 的 AppId / AppMutex / 显示名 / 发布者 / 安装目录 `{autopf}\<windows_app_name>`、卸载时删除的数据目录和 URL scheme、图标 |
| macOS | `PRODUCT_NAME`、`PRODUCT_BUNDLE_IDENTIFIER`、版权、CFBundleDisplayName、debug bundle id、URL scheme、定位权限说明里的应用名、AppIcon、dmg 配置 |
| 共用 | `distribute_options.yaml` 的 `app_name`；`--version` 时 `pubspec.yaml` 版本；生成 `xclient_defines.json` |

`setup.dart` 会把 `xclient_defines.json`（存在时）合并进 `env.json`，经 `--dart-define-from-file` 传给 Flutter。

core/helper 文件名分别为 `XClient<brand_id>Core` 和 `XClient<brand_id>HelperService`（Windows 加 `.exe`），服务注册、Dart 路径/IPC、Rust 的服务/pipe 校验与端口注册表键、setup hook 默认值与 `build_config.yaml`、CMake/Inno、macOS Core 引用同步改写。Windows helper 使用动态端口，Dart 每次从该品牌服务的 `Runtime\\Port` 读取；旧版 fallback 47890 保留，readiness 另核对完整 helper 路径，避免把用户原有 FlClash helper 当成当前品牌。Inno `AppMutex=XClient-<windows_app_guid>` 与 runner 全生命周期 RAII mutex 同名，仅供安装器检测；应用单实例继续由 WindowPlugin 管理。品牌更换时旧标识会替换，重复应用无变化；同文件多项变换先串联合成再统一写入，匹配失败时不写文件。

**刻意没改的**（执行时也会打印）：Kotlin 包名 / namespace，以及 Dart `packageName`（原生 MethodChannel 的固定命名空间，与 Android applicationId 分开）；helper 的旧版 fallback 47890；默认混合端口 7890；上游 repository 元信息；Android TV 图标和 banner；托盘图标（可放进 overlay）。本项目仅出 Android、Windows、macOS 品牌包，未验证 Linux 品牌安装。

## 4. 本地构建

本机需要：Flutter 3.47.6、Go 1.27.1、Rust（rustup）、Android SDK + NDK r28c、Java 17+；Windows 桌面包需要 Visual Studio 2022 C++ 工具链和 Inno Setup 6；macOS 包需要 Xcode 26。

建议在单独的 worktree 里做，构建完直接删掉，不污染主工作区：

```bash
git worktree add ../xclient-build HEAD
cd ../xclient-build
git -c 'url.https://github.com/.insteadOf=git@github.com:' submodule update --init --recursive
flutter pub get
dart tool/xclient/brand_apply.dart example            # 或私有品牌：先把 xclient-brands/98k 放到 brands/98k
XCLIENT_BRAND=example flutter build apk --debug --target-platform android-arm64 \
  --dart-define-from-file=xclient_defines.json --dart-define=APP_ENV=dev
# 发版式构建：dart setup.dart android --env stable
```

在主工作区试过 brand_apply 后，用 `git checkout -- android windows macos assets distribute_options.yaml pubspec.yaml` 和 `git clean -fd android/app/src/main/res` 还原，再删掉 `xclient_defines.json`。

## 5. 密钥

| 密钥 | 用途 | 私钥放哪 | 公钥放哪 |
|---|---|---|---|
| ctrl（`ctrl-1`、备用 `ctrl-2`） | 签 bootstrap（§5.1）和策略文档（§7.1） | 面板插件 `xclient_gateway` 配置 + 离线备份 | 每个品牌 `ctrl_pub_keys` |
| rel（`rel-1`、备用 `rel-2`） | 签发布事实文档（§7.2） | GitHub secret `XCLIENT_REL_SEED` + 离线备份 | 每个品牌 `rel_pub_keys` |
| env | 订阅信封签名（§4.1） | 面板插件（在线） | bootstrap 下发；可在 `env_pub_keys` 内置一份 |
| obf | bootstrap 混淆（不是安全边界） | 面板插件 | 每个品牌 `obf_key` |

生成（seed 文件新建、不覆盖已有文件，POSIX 上权限 0600；seed 只写文件，不会打印）：

```bash
dart tool/xclient/xsign.dart keygen rel-1 --out keys/rel-1.seed      # 打印 {"kid":"rel-1","pub":"…"}
dart tool/xclient/xsign.dart keygen ctrl-1 --out keys/ctrl-1.seed
dart tool/xclient/xsign.dart pub keys/rel-1.seed                     # 再次查看公钥
python -c "import os,base64;print(base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip('='))"   # obf_key
```

`keys/` 已在 `.gitignore` 中。三个品牌可以共用一套 ctrl/rel（DESIGN 未要求分开），也可以各自一套。备用 kid 先内置进 App，主密钥泄露时用备用 kid 签新文档即可，不用等所有用户升级。

签名与校验：

```bash
XCLIENT_REL_SEED="$(cat keys/rel-1.seed)" dart tool/xclient/xsign.dart sign-release 98k 1.0.0 dist \
  https://github.com/<owner>/<repo>/releases/download/v1.0.0 https://mirror.example.com/xclient/{tag}
dart tool/xclient/xsign.dart verify dist/98k-release-v1.0.0.json brands/98k/brand.json
CTRL_SEED="$(cat keys/ctrl-1.seed)" dart tool/xclient/xsign.dart sign boot payload.json --kid ctrl-1 --seed-env CTRL_SEED
```

`verify` 的第二个参数可以是 brand.json（rel 文档用 `rel_pub_keys`，其他用 `ctrl_pub_keys`）、`kid=pub`，或单独一个公钥。

Android 签名证书（每个品牌长期固定，丢了用户只能卸载重装）：

```bash
keytool -genkeypair -keystore 98k.jks -alias xclient -keyalg RSA -keysize 4096 -validity 36500
base64 -w0 98k.jks        # 填进 secret XCLIENT_KEYSTORE_B64_98K
```

## 6. GitHub secrets

| secret | 说明 |
|---|---|
| `BRANDS_DEPLOY_KEY` | `xclient-brands` 的只读 deploy key（SSH 私钥） |
| `XCLIENT_REL_SEED` | rel 私钥 seed（b64u），只有签名事实 job 读取；手动仅出包也签验事实以便自验 |
| `XCLIENT_KEYSTORE_B64` / `XCLIENT_KEYSTORE_PASSWORD` / `XCLIENT_KEY_ALIAS` / `XCLIENT_KEY_PASSWORD` | Android keystore（base64）及口令，三品牌共用时填这一组 |
| `XCLIENT_KEYSTORE_B64_98K` 等（后缀 `98K`、`MG`、`YZY`） | 可选，按品牌覆盖上面四项 |

仓库变量（Variables，可选）：`XCLIENT_REL_KID`，默认 `rel-1`。

Android release 构建设置 `XCLIENT_REQUIRE_RELEASE_SIGNING=true`，keystore 不全时 Gradle 直接失败，不会偷偷发出 debug 签名的包；本地不设这些变量时仍是上游行为（debug 签名 + `.dev` 后缀）。`XCLIENT_BRAND` 存在时，Gradle 原始 APK 命名为 `{brand}-android-{abi}-v{ver}.apk`。

## 7. CI

- `xclient-build.yaml`（push / PR 到 main）：XClient格式/分析/品牌/回归、上游完整测试、PHP互操作向量，以及Go完整包/受限拨号与broker race/真实Go↔Dart TLS组件。example品牌安全构建为Android/macOS debug与Windows Profile；Windows使用发行CRT以便在没有开发环境的主机渲染。所有示例产物均`SAFE_MODE=true`，不可用来验真实TUN。
- `xclient-release.yaml`（手动构建或推送 tag `v*`）：
  1. 手动运行填写不带 `v` 的 `version`，默认 `1.0.0-pre.1`；先加 `v`，与推送 tag 共用同一严格解析器。接受 `vX.Y.Z`、`vX.Y.Z-pre` 或明确的 `-alpha.N` / `-beta.N` / `-pre.N` / `-rc.N`（带 `-` 时 `APP_ENV=pre`）。
  2. 品牌 {98k, mg, yzy} × {android-arm64, android-arm, android-x64, windows, macos-arm64, macos-x64} 共18个job；Android按ABI分开构建，保留三架构、减小Go/JNI/AAR峰值磁盘。各job检出私有品牌、HTTPS拉submodule、品牌化，再按上游`setup.dart`流程构建（Flutter3.47.6/Go1.27.1/NDKr28c/Java17/Xcode26.x）。仅Android一次性runner清理非选定预装NDK，选定版本保留并验证。每APK检查对应ABI的Flutter/AOT/Core/Rust库及签名，事实签发前再要求三品牌全部三ABI齐备。
  3. 每个品牌一个 `macos-universal` job：lipo 合并两份 .app、ad-hoc 重签、打 `{brand}-macos-universal-v{ver}.dmg`（首装）和 `.zip`（应用内更新）。
  4. `facts` job下载全部产物，逐品牌签发并用该品牌`rel_pub_keys`验签发布事实，生成摘要与收据；手动和tag构建都执行，seed/内置公钥不匹配即失败。URL只采用各品牌明确配置的`release_url_bases`，缺失则拒绝签发，不自动插入私有GitHub地址。
  5. 手动运行仅上传私有Artifacts：Android为`xclient-pkg-<brand>-android-{arm64,arm,x64}`，Windows/macOS为`xclient-pkg-<brand>-<platform>`，聚合产物为`xclient-signed-packages`。聚合保留`dist/`与说明，可自验包/事实/签名/摘要。只有`publish`具备`contents:write`且必须是`push`+`refs/tags/v*`，才创建Release；手动运行不创建tag/Release或上传生产镜像。
- 上游的 `build.yaml` 已改为只能手动触发（其发布 job 本来就限定 `chen08209/FlClash`）；`pages.yaml` 的 job 同样限定上游仓库，不会在本仓库运行。
- 所有 action 都钉在提交 SHA（注释里是对应版本号）。

手动 `xclient-native-qa.yaml` 的 Mac 更新对照可选 `platform=macos`、`macos_signing=ephemeral-self-signed`、`macos_confirmation=confirm-owned`。该模式仅在已有 Accessibility 权限的全新托管 CI 中，为本轮 nonce 合成项创建临时数据钥匙串并模拟一次系统“Always Allow”；检查 Apple SecurityAgent、已安装 V2 的进程与文件、精确服务/钥匙串对话框及截图后，才输入新生成的测试密码。默认 `disabled`，不申请权限、不读取或输入原 login 密码、不改 App 存储实现。恢复原默认/login/search 状态并删除自有材料是独立成功门禁；即使通过，也只证明模拟系统确认后的跨版本存储，不代表用户自签更新无需确认。

产物名（DESIGN §0）：`98k-android-arm64-v8a-v1.0.0.apk`、`98k-android-armeabi-v7a-v1.0.0.apk`、`98k-android-x86_64-v1.0.0.apk`、`98k-windows-x64-setup-v1.0.0.exe`、`98k-macos-universal-v1.0.0.dmg`、`98k-macos-universal-v1.0.0.zip`、`98k-release-v1.0.0.json`。

构建号 = `major×10000000 + minor×100000 + patch×1000 + stage`（`1.2.3` → `10203999`），由品牌化和发布事实文档共用同一个函数生成，也是 UA 的 `b{build}`、Android versionCode 的基数（Flutter 按 ABI 添加偏移）。major 范围 0–200，minor/patch 为 0–99，数字不得有前导零。stage 依次为 `alpha.N` → N、`beta.N` → 200+N、`-pre` → 400、`pre.N` → 400+N、`rc.N` → 600+N、正式版 → 999。alpha/beta/pre 的 N 为 1–199，rc 的 N 为 1–398；其它后缀和 `+build` 均拒绝。这样同一版本的 alpha → beta → pre → rc → 正式版都有独立递增构建号，正式版也可覆盖预发布版。CI 校验与 Dart API 的接受范围、构建号由测试逐项对比。项目尚未发布成品，因此这次编码调整没有已安装 XClient 的兼容迁移；以后不得随意更改编码。

### macOS SAFE_MODE 窗口截图

`ci/macos_safe_smoke.sh` 只接受同一个 GitHub Actions macOS job 新编译的 example debug `.app`。它要求 `GITHUB_ACTIONS=true`、`RUNNER_OS=macOS` 和显式 `XCLIENT_SAFE_MODE_BUILD=1`，并核对 workspace 内的 Debug 路径、`com.xclient.example.debug`、生成配置中的唯一 `SAFE_MODE=true` / `XC_BRAND_ID=example`，以及构建前 marker 的 job 身份和产物时间。不能对下载的 Artifacts、普通品牌包或本机安装运行该脚本。这些检查是可信 CI 的构建出处收据，不是对任意二进制的 SAFE_MODE 密码学证明。

在现有安全构建步骤前创建 marker，构建后直接启动：

```bash
export XCLIENT_SAFE_MODE_BUILD=1
marker="$RUNNER_TEMP/xclient-macos-safe-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT.stamp"
bash tool/xclient/ci/macos_safe_smoke.sh --prepare "$marker"
flutter build macos --debug --dart-define-from-file=xclient_defines.json \
  --dart-define=APP_ENV=dev --dart-define=SAFE_MODE=true
mkdir -p out
shopt -s nullglob
apps=(build/macos/Build/Products/Debug/*.app)
test "${#apps[@]}" -eq 1
bash tool/xclient/ci/macos_safe_smoke.sh "${apps[0]}" out/macos-safe-smoke "$marker"
```

它直接执行 `CFBundleExecutable`，只枚举记录 PID 的可见主窗口，最多等待 25 秒；出现后等两秒采首帧，再约 15 秒后采最终帧。每帧均重新核对同 PID/启动身份、窗口 ID 和构建 hash。主图像取自该应用自己的 Flutter 引擎只读 `/_flutter.screenshot`，不注入 UI、不采系统桌面或其它窗口。随附 Python3 工具只用标准库，从本次应用 stdout 在内存提取唯一 `127.0.0.1` VM Service，先后用系统 lsof 验证监听 PID 正是本次应用，禁代理、禁重定向，以五秒上限请求并校验 JSON/base64/PNG，再由 Swift ImageIO 实际解码。URI/鉴权路径不输出；应用结束后会从 stdout 日志移除 loopback VM URI，再供 Artifacts 保存。脱敏失败或进程清理无法确认时，会失败并移除原始 stdout，防止上传尚可用的 VM URI。

Swift 使用系统 CoreGraphics / ImageIO / CryptoKit，Python 使用 runner 已有 Python3，不安装包、不请求屏幕录制或辅助功能权限。OS 录屏权限只作 preflight 收据，缺少该权限不阻挡 Flutter 引擎截图；默认不调用系统 screencapture。没有图形会话、进程退出、无窗口、VM Service 缺失/不唯一/监听者不匹配、引擎截图或 PNG 校验失败都会明确失败；不会点击系统提示、修改安全策略或把缺失截图算通过。启动后的观察/截图共用 45 秒预算，届满明确失败后清理自己进程，不为等第二帧无限延长。Swift 编译在启动前执行，编译时间不算应用观察预算。

脚本仅对本次应用进程传入既有 `FLCLASH_ACCEPT_DISCLAIMER=1`；应用会在一次性 example debug 偏好中记录接受版本。SAFE_MODE 允许应用按现有链路创建 bundled direct Core，但禁用 helper、代理监听、TUN、系统代理/DNS等主机写入。脚本不会调用 Core/helper；它只按 example 品牌生成规则匹配 `Contents/MacOS/XClientexampleCore`，记录应用及当场验证为其直接子进程的 Core 的 PID、可执行路径和启动身份，只清理这些仍匹配身份的进程。子 Core 即使重新挂到系统父进程，仍须原 PID/启动时间/路径一致才能清理。

输出目录必须新建于 workspace 的 `out/` 下。失败时也应由调用方 `always()` 上传该目录，保留 `receipt.txt`、首帧 `window-first.png` / 最终帧 `window.png`（若成功）、每帧图像尺寸/SHA256、截图前后构建 hash/窗口元数据、proxy/interface 名单的前后 hash、应用输出及仅匹配本次 PID/路径/启动时间的崩溃报告；不会保存代理或接口原值。网络 hash 改变和进程归属无法确认都会失败。空崩溃目录只表示当时未找到匹配报告，不能证明稍后没有系统诊断。

退出 0 仅代表取得两帧图像且收据检查通过，`manual_png_review` 始终为 `pending`。即使两帧都只是初始化 spinner，也不会自动算页面通过。维护者须实际查看 PNG，确认 SAFE MODE 标识和预期页面后再记录 UI 验收。该脚本不证明真实登录、TUN、代理转发、更新安装、钥匙串权限或多品牌隔离；Windows 本机只可做 Bash 语法/静态检查，真实 macOS 运行结果必须以 CI 为准。

## 8. 发版步骤

1. 确认 main 上 `xclient-build` 全绿。
2. 在 Actions 手动运行 `xclient-release`，选择待验分支，填写版本（如 `1.0.0-pre.1`），下载构建 artifacts，先完成三品牌三端自验并记录结果；此步骤不公开发行。
3. 自验通过并获得发布授权后，更新 `CHANGELOG`（可选）、提交，再执行 `git tag v1.0.0 && git push origin v1.0.0`（版本按实际批准值）。
4. 等 tag 触发的 `xclient-release` 完成，检查 Release 里每个品牌 7 个文件 + `SHA256SUMS.txt`。
5. 如果 `release_url_bases` 配了镜像，把 Release 里的文件同步到镜像目录（CI 不上传镜像）。
6. 经生产配置变更授权后，在面板插件里把策略文档的 `latest` / `min_supported` / `force` / `release_urls` 指向新版本的 `{brand}-release-v{ver}.json`，客户端据此提示或强制更新（DESIGN §7.1）。

私有仓库的Release不是普通客户端可匿名读取的下载源。正式发行前，`release_url_bases`和面板策略必须指向经过严格HTTPS/完整文件校验的独立镜像；App不得携带GitHub token。仅签名成功不代表URL已可用，未获生产上传授权的测试Artifacts只供内部自验。

## 9. 同步上游 FlClash

```bash
git remote add upstream https://github.com/chen08209/FlClash.git   # 只需一次
git fetch upstream --tags
git checkout -b sync/v0.9.3 main
git merge v0.9.3                                                   # 用 merge，不用 rebase
```

冲突通常集中在少数接缝：`.github/workflows/build.yaml` 的触发器、`android/app/build.gradle.kts` 的签名段、`setup.dart` 的 `createBuildEnvironment`、`windows/packaging/exe/inno_setup.iss` 的进程名，以及 `lib/` 里接入 `lib/xboard/` 的几处。解决后：

```bash
flutter pub get
dart tool/xclient/brand_apply.dart example --check   # 上游改了被改写文件的结构时这里会报错，按提示更新 src/brand_edits.dart
flutter analyze --no-fatal-infos
dart run tool/test.dart                               # 本机需要先关掉 build hook，CI 会自动处理
```

上游升级 Flutter / Go / NDK / CA 证书包版本时，同步修改两个 xclient workflow 顶部的 `env`。

## 10. 已知限制

品牌构建会应用 `tool/xclient/patches/mihomo-managed-probes.patch`，并在既有 Core tags 中追加 `xclient`。这是 C21 的原生探测准入功能：Mihomo 在 URLTest 更新 alive/history 或联网之前调用可选 hook，正式单节点请求携带绑定节点和 URL 的单次许可；自动 health-check 和分组批测没有许可。Dart 稀疏队列与同区恢复仍决定何时发起正式请求。这个入口必须位于 Mihomo 的 URLTest 边界，应用层的 lazy/interval 无法约束首次、拨号失败和 provider 更新触发的探测；它属于功能补丁，不是上游修错。

carrier 固定校验 `c5062921054902b25215a6a933e72ccd714c9bfa`，只应用两个 adapter 文件共9行；重复应用只核对已就绪状态，错误版本、部分补丁或冲突会拒绝并保留现有改动。子模块 gitlink 不变，生成后的 worktree dirty 是预期状态，不能把它当作新 fork 提交。`brand_apply --check` 只读；未初始化时报告 deferred，真正构建必须先初始化。上游升级需重新审查和重建 carrier，再跑默认/tagged Go 回归、品牌工具和原生 CI；普通未启用 tag 的 FlClash 保留原探测路径。无 Flutter 引擎时不会运行 Dart 同区恢复，不能将这个 hook 称为独立原生故障转移实现。

- macOS universal 由两份单架构构建 lipo 合并而成，ad-hoc 签名，未公证；首次打开要在“系统设置 → 隐私与安全性”里放行。合并脚本只在 macOS CI 上跑，本机（Windows）无法验证。
- Windows 安装包 Authenticode 实测为 `NotSigned`。C24 的不采购／自签选择不等于 Windows 已有发布者签名；系统可能提示或按管理策略阻止。平台安装与实际验收边界见 [安装指南](../../INSTALLATION.md)。
- Windows品牌构建会隔离helper服务/注册表、core文件/管道及安装mutex；工具回归已通过，多品牌真实安装与TUN行为仍需Windows成品验证（见第3节）。

版本身份以品牌工具生成的完整 `XC_VERSION_NAME` / `XC_BUILD_NUMBER` 为准，同一有效版本同步写入 pubspec；CLI `--version` 优先于品牌默认。逻辑 build 是 `buildNumberFor` 的原始值。Android split-per-ABI OS versionCode另有1000/2000/4000偏移，macOS会把预发布名规范化为数字字段，不能据此反推逻辑SemVer。客户端身份、UA与更新比较使用编译 pair；原生安装器继续比较真实OS元数据。未设置版本时不生成部分 pair，普通PackageInfo路径保留；部分或非法pair明确失败。显式带数字+build的min_supported按同SemVer build比较，不带build的策略维持原语义；发布工作流仍每SemVer固定一个raw build，不新增任意同版本重发能力。
