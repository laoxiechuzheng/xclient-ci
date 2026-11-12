# lib/xboard — XClient 核心（Task B）API 契约

本目录是 XClient 与面板交互的全部非 UI 代码，实现 `docs/DESIGN.md` §2–§7 的客户端部分和 §8 的配置改写。
UI（Task C/D/E）只通过本文列出的类、方法和 provider 使用核心；本文就是它们之间的契约。改签名先改本文。

- 纯 Dart 类 + 普通 Riverpod provider（无 freezed / json_serializable / riverpod_generator，不需要 build_runner）。
- 返回给 UI 的面板数据多为 `Map<String, dynamic>` / `List<Map<String, dynamic>>`，字段名与 Xboard 接口一致（见 `docs/research/02-xboard-user-api.md`）。
- 金额单位：分；流量：字节（套餐 `transfer_enable` 为 GB）；时间：Unix 秒。
- 永远不向 UI 暴露、不落盘：订阅 URL、订阅 token、密码。

## 1. 目录

```
lib/xboard/
  providers.dart                  Riverpod 入口（UI 只需 import 这一个文件，它 re-export 常用类型）
  brand/brand_config.dart         BrandConfig、ApiEndpointSpec、品牌 define 解析
  core/runtime.dart               XClientRuntime：组装并调度全部组件
  core/client_info.dart           ClientInfo：平台/架构/版本/系统版本/设备名
  core/ua.dart                    User-Agent（DESIGN §2）
  core/log.dart                   xcLog / xcLogSink（不得记录任何秘密）
  core/crypto/                    b64u、AEAD、X25519/HKDF、信封、签名文档、bootstrap 去混淆
  core/net/                       transport（dart:io，直连+pin）、ApiClient、EndpointPool、BootstrapResolver、DNS 编解码、SPKI
  core/auth/                      SecureStore、DeviceIdentity、Session
  core/api/xboard_api.dart        XboardApi：用户接口 + 插件设备接口
  core/sync/                      SubscriptionSync、ConfigRewrite、StatePoller、更新文档（策略/发布）、FlClashProfileSink
```

## 2. 品牌 define（`--dart-define-from-file`）

所有值都是**字符串**。`tool/xclient/brand_apply.dart` 从 `brands/<id>/brand.json` 生成 `xclient_defines.json`，`test/xboard/tool/brand_apply_test.dart` 做往返校验。

| define | 格式 | 说明 |
|---|---|---|
| `XC_BRAND_ID` | `[a-z0-9]{1,16}` | 品牌 id，如 `98k`；空 = 未品牌化构建（`dev`） |
| `XC_DISPLAY_NAME` | 文本 | 显示名，也是托管 Profile 的名称 |
| `XC_UA_PRODUCT` | `[A-Za-z0-9._-]+`，可空 | UA 产品段，默认 `{brandId}Client` |
| `XC_API_ENDPOINTS` | `url[|weight],…` | 内置 API 端点（L0），仅 https；weight 默认 100 |
| `XC_BOOTSTRAP_SOURCES` | `url,…` | OSS/CDN 上签名 bootstrap 的 URL（L2），仅 https |
| `XC_DOH_NAMES` | `name,…` | DoH 基础名；客户端查询 `_xc.<name>` 的 TXT（L3） |
| `XC_DOH_RESOLVERS` | `url,…`，可空 | RFC 8484 解析器；空则用 alidns、doh.pub、1.1.1.1、dns.google |
| `XC_CTRL_PUBKEYS` | `kid:b64u,…` | bootstrap / 策略文档 Ed25519 公钥（当前 + 备用） |
| `XC_REL_PUBKEYS` | `kid:b64u,…` | 发布事实文档公钥 |
| `XC_ENV_PUBKEYS` | `kid:b64u,…`，可空 | 订阅信封公钥（首启兜底；其余来自 bootstrap `env_keys`） |
| `XC_OBF_KEY` | b64u 32 字节 | bootstrap 混淆密钥 |
| `XC_PANEL_WEB_URL` | https URL | 站点网页（注册、找回密码在浏览器打开） |
| `XC_SUPPORT_URL` | https URL | 客服/工单网页 |
| `XC_CORE_VERSION` | `1.19.33` 或 `v1.19.33` | UA 中的 mihomo 版本，默认 `1.19.33` |

非 https 或格式错误的条目会被丢弃（不报错）。

## 3. Riverpod provider（`package:fl_clash/xboard/providers.dart`）

| provider | 类型 | 语义 |
|---|---|---|
| `xcBrandConfigProvider` | `Provider<BrandConfig>` | 本构建的品牌 |
| `xcRuntimeProvider` | `FutureProvider<XClientRuntime>` | 创建并 `start()` 运行时（L0 bootstrap → 恢复会话 → 后台刷新）。**App 启动时必须 watch/read 一次** |
| `xcApiProvider` | `Provider<XboardApi?>` | 运行时就绪后非空 |
| `xcSessionProvider` | `StreamProvider<XcSessionState>` | 会话状态；就绪前为 loading |
| `xcSyncStatusProvider` | `StreamProvider<SyncStatus>` | 节点同步状态 |
| `xcBootstrapProvider` | `StreamProvider<BootstrapState>` | 当前端点来源、是否 stale |
| `xcRemoteStateProvider` | `StreamProvider<RemoteState>` | `GET xclient/state` 的最新结果 |
| `xcPolicyProvider` | `Provider<XcPolicy?>` | 最新**已验签**的更新策略（§7.1） |
| `xcNoticeProvider` | `Provider<XcNotice?>` | 要展示的公告（签名策略内的优先） |
| `xcManagedProfileIdProvider` | `FutureProvider<int?>` | 托管 Profile 的 id（UI 用它隐藏编辑/导出/删除入口） |
| `xcActionsProvider` | `Provider<XcActions>` | UI 动作入口，见下 |
| `xcManagedAndroidProvider` | `Provider<bool>` | 私有品牌 Android 的原生生命周期分支 |
| `xcControlActiveProvider` | `Provider<bool>` | Android 为实际界面可见或 VPN 仍运行；其余平台为界面可见 |
| `xcClosingProvider` / `xcExitRetryProvider` | `NotifierProvider<…, bool>` | 显式退出的交互屏障与未确认停止后的重试提示 |
| `xcRuntimeShutdownProvider` | `Provider<XcRuntimeShutdown>` | 终态退出时关闭已创建或仍在初始化的运行时，禁止晚到异步步骤再创建资源 |

`lifecycle.dart` 的 `mountXcLifecycle(container)` 在 Bootstrap 初始化后保有一份强容器订阅，后台控制和硬停止不依赖 Widget 帧。Android 保留同一个 application-context engine；普通 Activity 销毁只解绑界面。Core 原生事件由连接 owner `CoreLib` 转发，界面卸载不会切断探测/故障转移或原生停止事实。

私有 Android 的停止请求等待代际所属 TUN 及服务释放确认后才清除显示运行时；失败或 30 秒等待超时保留控制并允许重试。迟到成功仅影响仍为最新意图的停止。显式退出在确认停止后关闭 XClient、等待有界 DIRECT 清理，再终结 Core 和 engine。OS 强停仍受尊重。这些是实现契约，实际设备后台、Doze 和物理 VPN 验收仍需独立证据。

`XcActions`（全部等待运行时就绪）：

```dart
Future<void> login(String email, String password); // 失败抛 XbApiException；状态同时变为 error(message)
Future<void> logout();                             // 服务端吊销 → 删 Profile、停内核、清安全存储
Future<void> registerDevice();                     // 设备数超限后，用户在设备管理移除旧设备再调用
Future<SyncStatus> syncNow();                      // 立即拉取节点（如 resetSecurity 之后）
Future<void> refreshUser();                        // 重新拉 /user/info 到 XcSessionState.user
Future<void> pollState();                          // 立即拉 state（策略/公告）
void setForeground(bool foreground);               // 前台 60s / 后台 15min 轮询
```

## 4. 会话 `Session`（core/auth/session.dart）

```dart
enum XcSessionStatus { restoring, loggedOut, loggingIn, loggedIn, error }
class XcSessionState {
  XcSessionStatus status; String? email; Map<String, dynamic>? user;   // user = /user/info
  bool deviceRegistered; XbApiException? deviceError;                 // deviceError.kind == deviceLimit → 引导到设备管理
  Map<String, dynamic>? device;                                       // {device_id, max_devices, active_devices, env_kid}
  String? message;                                                    // 中文：登录失败原因 / 会话结束原因
  bool get isLoggedIn;
}
class SessionMessages { expired; deviceRevoked; deviceLimit; network; storage; } // 中文常量
```

方法：`restore()`、`login(email, password)`、`registerDevice()`、`ensureRegistered()`、`withDevice<T>(action)`（409 `device_unknown` 时重注册并重试一次）、`refreshUser()`、`logout()`、`addLogoutHook(Future<void> Function())`、`state`、`changes`、`identity`。

- 登录：`POST /api/v1/passport/auth/login`（表单）→ 只保存 `auth_data`（`xc.auth`）和邮箱（`xc.email`，仅展示）；订阅 token 用完即丢；随后 `POST /api/v1/xclient/device/register`。
- 任何请求返回 401、或 Xboard “未登录或登陆已过期” 403 → 会话结束（`message = SessionMessages.expired`）；403 `device_revoked` → 结束（`SessionMessages.deviceRevoked`）。结束时依次执行 logout hook（删托管 Profile → FlClash 在无 Profile 时停内核）、清空 `xc.*` 安全存储。
- 退出后下次登录会生成新的 device_id 和 X25519 密钥（安全存储已清空）。

## 5. 面板接口 `XboardApi`（core/api/xboard_api.dart）

`XboardApi(api, checkoutWebUrl: optionalHttpsWebUrl)` 仅为 `checkout()` 发送
`Referer: https://host[:port]/`。构造时验证非空配置，丢弃路径、查询和片段，不允许
userinfo、非 HTTPS 或非法主机/端口；失败为不含输入值的 `FormatException`。
`XClientRuntime` 传入 `brand.panelWebUrl`。未传或空值保持独立调用兼容，不增加必需网页依赖。
账户及其他 API 不附带此头；Authorization、品牌 UA、POST 的重试规则不变。
此头用于面板 `source_base_url` 生成原 Web 订单返回地址，不改变商户 notify_domain、付款状态或 TLS 验证。

以下请求方法抛 `XbApiException`，构造配置校验异常如上。`XbPage { List<Map> items; int total; }`；`XbCheckoutResult { int type; Object? data; bool isPaid; String? qrContent; Uri? redirectUri; }`。
常量：`PlanPeriod`（旧键名 `month_price…reset_price` + 中文 `labels`）、`OrderStatus`（0–4 + 中文 `labels`）。

| 方法 | 接口 | 返回 |
|---|---|---|
| `guestConfig()` | GET guest/comm/config（免登录） | Map |
| `userInfo()` | GET user/info | Map |
| `stat()` | GET user/getStat | `[待付订单, 未关工单, 邀请人数]` |
| `subscribeSummary()` | GET user/getSubscribe | Map，**已删除 `subscribe_url`、`token`** |
| `commConfig()` | GET user/comm/config | Map（币种、提现方式…） |
| `changePassword(old, new)` | POST user/changePassword | — |
| `resetSecurity()` | GET user/resetSecurity | —（丢弃新订阅 URL；之后调用 `syncNow()`） |
| `updateRemind({bool? expire, bool? traffic})` | POST user/update | — |
| `notices({page})` | GET user/notice/fetch（无信封，5 条/页） | XbPage |
| `knowledge({language='zh-CN', keyword})` | GET user/knowledge/fetch | `{分类: [文章]}` |
| `knowledgeArticle(id, {language})` | 同上 `?id=` | Map，`body` 中的订阅链接/token 已替换为“（已隐藏）” |
| `plans()` / `plan(id)` | GET user/plan/fetch | List / Map（价格单位分，旧键名） |
| `checkCoupon({code, planId, period})` | POST user/coupon/check | Map |
| `saveOrder({planId, period, couponCode})` | POST user/order/save | trade_no（面板自动先扣余额） |
| `checkout({tradeNo, method})` | POST user/order/checkout（无信封） | XbCheckoutResult：-1 已付 / 0 二维码 / 1 跳转 |
| `checkOrder(tradeNo)` | GET user/order/check | 状态 int（轮询用） |
| `orderDetail(tradeNo)` / `orders({status})` / `cancelOrder(tradeNo)` | user/order/* | Map / List / — |
| `paymentMethods()` | GET user/order/getPaymentMethod | List |
| `createInviteCode()` / `invites()` / `inviteDetails({page, pageSize≥10})` | user/invite/* | — / Map / XbPage |
| `transferCommission(cents)` / `withdrawCommission({method, account})` | user/transfer、user/ticket/withdraw | — |
| `tickets()` / `ticket(id)` / `createTicket({subject, level, message})` / `replyTicket(id, msg)` / `closeTicket(id)` | user/ticket/* | List / Map / — |
| `trafficLog()` | GET user/stat/getTrafficLog | List |
| `loginLog({page, pageSize})` | GET user/loginLog/fetch | XbPage?（404 → null，隐藏功能） |
| `trafficCycle({historyPage, historySize, eventsSize})` | GET user/trafficCycle/fetch | Map?（404 → null） |
| `devices()` / `revokeDevice(deviceId)` | 插件 xclient/devices、devices/revoke | List / —（设备未注册也可用，用于超限时腾位置） |
| `ping()` | GET xclient/ping | `{time, boot_seq, policy_seq}` |

## 6. 错误 `XbApiException`（core/net/api_exception.dart）

`kind: XbErrorKind`：`unauthorized`(401/未登录 403)、`deviceRevoked`、`deviceLimit`、`deviceUnknown`、`replay`、`validation`(422，`errors`)、`rateLimited`(429，`retryAfter`)、`server`(5xx)、`network`、`tls`、`pinMismatch`、`notFound`、`badResponse`、`failed`(其他 4xx)。
字段：`status`、`code`（插件 error code）、`message`（面板文案）、`errors`、`retryAfter`；`displayMessage` 取第一条校验错误否则 `message`。UI 直接展示 `displayMessage`；`network/tls` 用自己的中文提示。

## 7. 节点同步 `SubscriptionSync`（core/sync/subscription_sync.dart）

```dart
enum SyncPhase { idle, syncing, ok, blocked, error }
class SyncStatus { SyncPhase phase; DateTime? lastSuccess; int? panelStatus; String? message; XbApiException? error; SubscriptionUsage? usage; DateTime? nextSync; }
class SubscriptionUsage { int upload, download, total, expire; }   // 来自信封内 subscription-userinfo
```

- `POST /api/v1/xclient/subscribe {device_id, ts, req_nonce}` → 打开信封（§4.1：kid ∈ 内置 + bootstrap `env_keys` → 验签 → 绑定/时间 → 解密）。
- `status==200`：`ConfigRewrite.apply`（`url-test/fallback/load-balance` 组 `lazy: true`、`interval ≥ 1800`；所有 API 端点主机加 DIRECT 规则置顶）→ `ManagedProfileSink.apply`。
- 其他 status：`phase = blocked`，`message` 为中文（403 = 账号不可用或被限制），不动现有 Profile。
- 周期：`profile-update-interval` 小时（至少 1h，缺省 24h）；失败退避 2–60 分钟；`X-XClient-Seq` 的 b/p 变大时 1–5s 后再拉一次；`syncNow()` 立即拉。
- 托管 Profile（`FlClashProfileSink`）：FlClash 的 file 型 `Profile`（`url` 为空、`autoUpdate=false`），id 存在 SharedPreferences `xc.managed_profile_id`；每次拉取后 `saveFile` → 内核校验 → 设为当前 → `applyProfileDebounce`。退出/吊销时 `deleteProfile`。

## 8. 端点与 bootstrap

- `BootstrapState { BootstrapPayload? payload; BootstrapSource source; bool stale; DateTime? checkedAt; endpoints(brand); envKeys(brand, now); pins; }`，`BootstrapSource { builtin, cache, panel, oss, doh }`。
- 可选 `BootstrapPayload.discovery` 是已签名的完整快照：`DiscoverySnapshot { apiPools, ossPools, dohNames, dohResolvers }`，每池有 `id/enabled` 和 `endpoints` 或 `urls`。整个对象严格验证后按配置顺序合并启用成员、URL 去重；禁用池也验证。显式空 API 池清空活动 API；没有 discovery 的旧 full 文档保留原来的空 API 兼容规则。新 full 文档替换远程 sources；新 mini 可暂时更新有效 API，但保留 full 的池、OSS、DoH、密钥和 pin 元数据。缓存保留 full/mini 签名原文，重启重新验签；损坏 mini 不丢弃有效 full。
- `BootstrapResolver.lastFullSeq/needsFull` 区分有效 mini 与完整快照进度。mini 比 full 新时，sources-only 轮询也查有效 API；Runtime 为每个新 mini 序号安排一次延后 full 追赶，跨序号至少间隔 10s，失败不会自行循环。后续提示以 full 序号判断是否还需补齐，采用文档仍以有效序号防回滚。同序号 full 可替换旧 full、补齐新 OSS/DoH；退出运行时取消追赶定时器。
- `BootstrapResolver.refresh()`：活动面板与 OSS → 远程 DoH → 编译内置 API/OSS 救援 → 内置 DoH。每轮总预算 15s，分给非空阶段；每阶段最多 4 个在途请求，等待中错开 250ms（面板到 OSS 为 300ms），完成后立即补位。预算耗尽记住下一成员，后续轮次公平尝试；已有同序号镜像不阻止查找更新。内置 API 仅用于免鉴权获取签名 bootstrap；无有效缓存时先发现再恢复账号，未签名响应不能改活动池。
- 面板与 HTTP bootstrap source 共用同一解析入口：支持原始签名文档，或单层 `{ok:true,data:<签名文档对象>}`，因此 API 镜像也可作为初始救援来源。出现 `ok` 或 `data` 包装字段时必须两者匹配，错误值/类型拒绝；拆包后仍完整执行以下去混淆、验签、品牌、序号和过期检查，外层 `ok` 不提供信任。
- 校验：kid ∈ 内置 ctrl 公钥 → 验签（OSS 混淆副本先解开，签名覆盖原始 payload 字符串）→ brand/schema/发现池 → `seq ≥ last_good`（同类型同 seq 须同 payload）→ 未过期。过期文档不替换 last-good，只标 `stale`；什么都没有时才临时采用过期文档并标 stale。last-good 原子写入 `<appData>/xclient/bootstrap.json`。
- `EndpointPool`：按 `weight / (1 + 延迟/300ms)` 排序，粘住当前端点；连接/TLS/5xx 连续失败 2 次切换并刷新 bootstrap；全挂先走远程 OSS/DoH，再允许内置免鉴权发现救援。Runtime 接受空池，配置 API URL/顺序或有效 pin 真正变化才重连推送，权重或重复状态不会反复断流；轮询间隔也仅在实变时重设。
- `ApiClient`：仅 https；不走本机代理、不接受无效证书（不受 FlClash 全局 `HttpOverrides` 影响）；GET 自动换端点重试，POST 只在请求确定未发出时换端点；每个响应的 `X-XClient-Seq` 通知运行时。
- 正常品牌应用由`xcDirectConnectorProvider`注入Core原始TCP桥，覆盖API/发现/DoH/推送/更新；`findProxy=DIRECT`本身不等于绕过自身TUN。Go复用原生socket protect/物理接口绑定，Dart仍对原始URI主机做TLS/CA/SPKI，Core断连时失败且轮换会话，不退回普通socket。关闭代理监听不关闭桥；SAFE_MODE控制HTTP不用该桥，全局启动仍可创建direct child Core。协议、资源界限及平台验证缺口见`DESIGN.md`§3.1。
- pin（§5.3）：`pins[host].mode` 为 `report/enforce` 时，TLS 握手后、发送请求前比对 leaf 证书 SPKI 的 SHA-256；`report` 只记日志，`enforce` 不发请求直接失败（`XbErrorKind.pinMismatch`）。bootstrap/DoH 拉取不 pin。

## 9. 状态轮询与更新文档

- `StatePoller`：`GET xclient/state`（`If-None-Match`），前台 60s / 后台 900s（bootstrap `poll` 可改）；p 变大立即拉。`RemoteState { bootSeq; policySeq; XcPolicy? policy; XcNotice? notice; checkedAt; effectiveNotice; }`。
- `XcPolicy { brand, seq, latest, minSupported, force, notes, releaseUrls, notice; hasUpdate(current); mustUpdate(current); }`：`mustUpdate` = `force && latest > current` 或 `current < min_supported`。策略 seq 不回退。
- 更新管理（Task D/E）用：`verifyReleaseDoc(doc, relKeys: brand.relKeys, brandId:, expectedVersion: policy.latest)` → `ReleaseManifest { version, build, publishedAt, assets: {key: ReleaseAsset{urls, sha256, size, kind}} }`；资产键 `android-arm64-v8a`、`android-armeabi-v7a`、`android-x86_64`、`windows-x64`、`macos-universal`。下载请用 `IoHttpTransport`（直连、严格证书）或等价实现，并校验 size + sha256。`compareSemver(a, b)` 可复用。

## 10. 其他公开工具

- `buildUserAgent(UaParts)`、`forbiddenSubstringsIn(ua)`、`currentArch()`、`currentPlatform()`；`XClientRuntime.userAgent`。
- `openEnvelope`、`verifySignedDoc`（前缀 `SignedDocKind.boot/policy/release`）、`TrustedKeys`、`deobfuscateBootPayload`、`DeviceKeyPair`、`b64uEncode/b64uDecode`。
- `xcLogSink`：运行时把它指向 FlClash `commonPrint.log`；日志里不得出现 token、密钥、邮箱、订阅内容。

## 11. 测试与向量

- `flutter test test/xboard/core`（本地需像 CI 一样把 `pubspec.yaml` 的 `hooks.user_defines.*.build_assets` 临时改为 `false`，否则会尝试编译 Go/Rust 原生资产）。
- 向量：`php test/xboard/vectors/gen_core_vectors.php` 生成 `envelope_v1_core.json`（固定测试密钥；同时用 libsodium 校验 RFC 8439、XChaCha 草案 A.3.1、RFC 8032、RFC 5869、RFC 7748 标准值）。面板插件生成的 `*_plugin.json` 也在 Dart 测试里交叉验证。

## 2026-11-04 integration contract additions

- Protocol: `DESIGN.md` in this directory. `REQUIREMENTS.md` is tracked in this private repository; detailed operational reports remain local.
- `XcAppHost` mounts runtime, login-owned navigation, probe settings and signed updater after upstream core initialization. `xcConnectionBlockProvider` supplies UI eligibility; SetupAction also calls `xcConnectionBlockNow` at each start seam to inspect live session/policy state before stream notifications. New starts require a current-session online signed policy,authentication/device registration and a successfully applied managed profile. Signed force/floor survives runtime restart in the policy cache; cache alone cannot grant a new session admission. `xcConnectionMustStopProvider` separates force/session end/subscription denial from temporary policy waiting. The existing cold-App initStatus takeover still stops an old native run; soft waiting preserves runs only within an already initialized App.
- `XboardApi.activeSessions/removeActiveSession/telegramBotInfo/giftCardCheck/giftCardRedeem/giftCardHistory/giftCardDetail/giftCardTypes` provide the remaining account features. Active session results whitelist display fields. Telegram binding stays on the site webpage because the legacy command exposes the subscription URL.
- Session generation prevents stale login/register/profile/state/error results from resurrecting an ended session or invalidating a newer one. Managed profile application awaits the core result; logout cleanup attempts every step even when stopping the core fails.
- Active push uses an independent strict HTTPS client and one-use same-endpoint tickets. `core/push/README.md` documents transport and lifecycle; polling remains available.
- Optional sealed subscription admission metadata is described in DESIGN §12. Implementation/verification status is kept in the local ledger and final test evidence; this document defines interfaces.

`ClientInfo.detect()`通过 `fromPackageInfo` 使用完整编译 `XC_VERSION_NAME` / `XC_BUILD_NUMBER`，避免macOS的数字化预发布名或Android ABI versionCode偏移污染UA/版本门禁。没有编译pair时保留PackageInfo，部分/非法值失败；不猜测OS字段、不放宽AppVersion。最低支持版本显式携带numeric build时，同SemVer比较build；无build策略兼容。启动日志只记录安全的platform/arch与逻辑版本/build，供实际native smoke核对，不记录设备名、账户或存储值。

品牌根导航使用单一 `XcRootBackScope/CommonPopScope`：优先返回内部页/弹层，根才走既有 `SystemAction.handleClose`，登录/初始化失败也覆盖。普通Back恢复默认退后台。C35已批准并实现单application-context引擎、独立NoView订阅及终态退出协调；Android的controlActive为visible||isStart，VPN运行时保持SSE/60秒兜底，界面和连接均不活跃时15分钟轮询。JVM/Dart/完整CI已验证，真实Activity/isolate/Quit与活跃VPN/Doze的范围及状态见需求台账，不能把普通Back当作这些OS证据。Android安装确认通知直接持有按session区分的系统Activity PendingIntent，避免只保static导致进程回收后无法继续；系统通知/安装确认仍待设备验证。
