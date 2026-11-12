# XClient 设计契约 v1

> 本文件是客户端（本仓库，FlClash v0.9.2 fork）与面板插件 `xclient_gateway` 之间的**唯一契约**。双端实现、测试向量、CI 都以本文为准；改契约先改本文。
> 本文可公开：不含任何面板域名、密钥、品牌私有资料。品牌资料（名称、图标、内置端点、公钥）在私有仓库 `xclient-brands`，CI 构建期注入。

## 0. 总体

```
┌────────── 客户端（Flutter，lib/xboard/）──────────┐        ┌──────── 面板（Xboard fork）────────┐
│ BrandConfig（构建期注入）                          │        │ 插件 xclient_gateway                 │
│ EndpointPool ← Bootstrap（内置 / 面板 / OSS / DoH） │ HTTPS  │  /api/v1/xclient/*                   │
│ ApiClient（仅 HTTPS、直连、证书校验、可选 SPKI pin）├───────►│  ├ device/register  subscribe(信封)  │
│ Session（账号密码登录，token→系统安全存储）         │        │  ├ state(推送捎带)  bootstrap  ping  │
│ SubscriptionSync（信封解密→Profile→内核）          │        │  └ logout devices                    │
│ Account / Plans / Orders / Tickets … 页面          │        │      │ 内部调用 ClientController::subscribe
│ ProbeScheduler + RegionFailover + 延迟展示          │        │      ▼                                │
│ UpdateManager（通知 / 强制）                        │        │ client.subscribe.before → subscription_smart_router_logger
└────────────────────────────────────────────────────┘        │   （分流 + jsonl 拉取记录，格式不变） │
                                                              │ 标准用户接口 /api/v1/user/* passport/*│
                                                              └──────────────────────────────────────┘
```

- 品牌：`98k`、`mg`、`yzy` 三个包（需求 C23）。包名 `com.xclient.b98k` / `com.xclient.mg` / `com.xclient.yzy`；产物名 `{brand}-{platform}-{arch}-v{ver}.{ext}`，如 `98k-android-arm64-v8a-v1.0.0.apk`、`98k-windows-x64-setup-v1.0.0.exe`、`98k-macos-universal-v1.0.0.dmg`。
- 不支持第三方订阅（C19）：去掉添加/导入订阅、扫码导入、URL scheme 导入等入口；唯一 Profile 由 SubscriptionSync 管理，不显示 URL，不可导出。

## 1. 编码约定

- `b64u` = 无填充 base64url。时间一律 Unix 秒。JSON 一律 UTF-8。
- 面板标准接口的响应壳 `{status,message,data,error}`；插件接口统一 `{"ok":true,"data":…}` / `{"ok":false,"error":"<code>","message":"…"}`，HTTP 状态码同时有意义（401 未登录、403 设备被吊销/超限、409 需重新注册、422 参数、429 限流、5xx）。
- 插件所有响应带头 `X-XClient-Seq: b=<boot_seq>;p=<policy_seq>`（“实时推送”捎带，§6）。

## 2. User-Agent（C6）

```
{Brand}Client/{appVersion} ({OS 段}; {arch}; b{build}) mihomo/{coreVersion} Clash.Meta
```

- OS 段：Android `Android {sdkRelease}; Mobile`；Windows `Windows NT 10.0; Win64; x64`；macOS `Macintosh; Mac OS X {major}_{minor}`。
- 例：`98kClient/1.0.0 (Android 14; Mobile; arm64-v8a; b100) mihomo/1.19.33 Clash.Meta`。
- 禁止子串（大小写不敏感）：`verge flclash clashmetaforandroid nekobox surge surfboard stash sing-box singbox hiddify sfm shadowsocks shadowrocket quantumult loon general v2rayn passwall ssrplus sagernet mozilla chrome safari edge okhttp dart`。单测对 3 品牌 × 3 平台 × 全部 arch 断言：不含禁止子串；按 Xboard `getClientInfo` 解析出 `clientName=clash`（Xboard 先匹配较长的 clash；服务端强制 flag=meta，仍使用 ClashMeta 格式）。
- 所有发往面板的请求（登录、用户接口、插件接口）都用这个 UA。插件的加密订阅在服务端额外强制 `flag=meta`，格式不依赖 UA；SSRL 按此 UA 做 UA 分组匹配并写进日志（C5、C7）。运营如需专属分组，在 SSRL 后台加规则 `98kClient/` 等。

## 3. 鉴权（C2、C3）

- 登录：标准 `POST /api/v1/passport/auth/login {email,password}` → `data.auth_data`（形如 `Bearer 1|xxx`）。客户端只保存 `auth_data`，**不保存**订阅 token、不保存密码。
- 存储：`flutter_secure_storage`（Android Keystore / Windows DPAPI / macOS Keychain）。键：`xc.auth`、`xc.device_id`、`xc.device_sk`（X25519 私钥 32B，b64u）、`xc.email`（仅用于显示，可选）。
- 传输：只允许 `https://`；使用独立 HttpClient 绕过全局 HttpOverrides，不接受无效证书；bootstrap 可下发 SPKI pin（§5.3）。正常品牌应用的控制连接经下述 Core 原始 TCP 桥，`findProxy: DIRECT` 仅负责绕过 HTTP 代理，不能单独保证绕过自身 TUN。
- 登录后立即 `device/register`；之后每个插件请求带 `X-XClient-Device: <device_id>`。
- 退出：`POST /api/v1/xclient/logout`（吊销当前 Sanctum token + 设备）→ 清空安全存储、删除本地配置文件、停内核。
- 401 → 清会话回登录页；403 `device_revoked` → 同上并提示；409 `device_unknown` → 重新注册一次。

### 3.1 控制连接与代理出口独立

- API、bootstrap/OSS、DoH、推送票据/SSE和更新下载共享 `CoreDirectConnector`。Go Core只提供原始TCP；Dart在该流上对**原始URI主机名**进行TLS/CA/SPKI校验，完成前不写HTTP凭据。`pin:false`只跳过SPKI，不跳过CA或原生出口。保留Global/Rule模式及正常节点选择能力。
- 复用既有RPC：`openDirectSocket {sessionId,host,port}` → `{connectionId,bridgePort,ticket,expiresInMs}`，随后连接Core的`127.0.0.1`随机端口并写32字节一次性票据，没有ACK。Go固定目标、原子消费票据、只读恰好32字节，随后透传TLS字节；不终止TLS、不接收账号明文。关闭接口为`closeDirectSocket {sessionId,connectionId}`、`closeDirectSession {sessionId}`。
- Go优先OS hosts/RFC6761 localhost，否则使用现有物理网络SystemResolver。已解析目标IP以显式tcp4/tcp6拨号，复用Mihomo公开`dialer.ICMPControl`的Android socket protect、桌面接口绑定和路由mark；目标TCP不再次经过profile hosts/DNS/DisableIPv6。双栈交错、第二路延后200ms，最多2个在途拨号，成功/取消清理其余连接。不改Mihomo子模块或全局resolver。
- 资源上限：16个活跃session、128个待消费票据、64个活动/拨号连接、16个未鉴权本地连接；票据10s、鉴权2s、拨号8s、无进展90s到期。临时accept错误有可取消的5ms–1s退避；永久错误关闭桥。会话/连接ID和票据使用安全随机数，RPC不经过参数日志助手。
- Core显式shutdown关闭桥；仅停代理/VPN监听不关闭账号连接。Core状态变化使Dart轮换epoch/session并销毁旧连接，延迟返回不能复活；Runtime释放自身会话，更新器只关闭自己的HTTP。普通构建Core不可用时请求失败，不回落普通Dart socket。SAFE_MODE禁用自身TUN，控制HTTP显式保留严格HTTPS的普通传输；既有全局启动流程仍可创建bundled direct child Core，但禁用helper及系统代理修改。
- 已有真实Go↔Dart组件测试覆盖DNS-only证书、未知CA/错误主机/错误pin在HTTP发送前拒绝、API/修复文档/DoH/SSE/下载；真实三平台TUN物理出口仍须独立平台验收。SystemResolver内部的上游数字nameserver拨号边界另行核实，不将本地组件测试称为所有网络环境已验证。

## 4. 插件接口 `/api/v1/xclient/*`

除 `ping`、`bootstrap` 外均需 `Authorization: <auth_data>`（Xboard 用户鉴权中间件）。

| 方法 路径 | 请求 | 响应 `data` |
|---|---|---|
| `GET ping` | — | `{time, boot_seq, policy_seq}` |
| `GET bootstrap?brand=98k` | — | 签名 bootstrap 文档（§5.1，整份 JSON，也是 OSS 上的同一份文件） |
| `POST device/register` | `{device_id, pub, platform, arch, app_version, build, os_version, device_name}` | `{device_id, max_devices, active_devices, env_kid}` |
| `POST subscribe` | `{device_id, ts, req_nonce}` | 信封 `{h, ct, sig}`（§4.1） |
| `GET state` | 头 `If-None-Match` 可选 | `{boot_seq, policy_seq, policy:<签名策略文档 §7.1>, notice?}`；未变返回 304 |
| `GET devices` | — | `[{device_id, platform, app_version, device_name, created_at, last_seen_at, current}]` |
| `POST devices/revoke` | `{device_id}` | `{}` |
| `POST logout` | — | `{}` |

- 设备表 `xclient_devices(id, user_id, token_id, device_id(uuid), x25519_pub, platform, arch, app_version, build, os_version, device_name, created_at, last_seen_at, last_ip, revoked_at)`，唯一键 `(user_id, device_id)`。活跃设备数上限为插件配置 `max_devices`（默认 5），超限 403 `device_limit`，客户端引导到“设备管理”。
- `subscribe`：`|ts-now| ≤ 300`；`req_nonce` 16B b64u，用缓存 `xclient:nonce:<user>:<nonce>` 去重 10 分钟（重复 → 409 `replay`）；设备不存在 409、已吊销 403。频率限制：同一用户 30 次 / 10 分钟。

### 4.1 订阅信封（C4）

服务端流程：
1. 在当前请求上 `merge(['token'=>$user->token,'flag'=>'meta'])`，清掉 `types/filter`，调用 `ClientController::subscribe($request)`；捕获 `InterceptResponseException`（SSRL 通过 `intercept()` 返回节点或拦截提示）取其 response。这样 `client.subscribe.before` 钩子、SSRL 的分流与 jsonl 记录照常发生（`request.path` 记为插件路由 `api/v1/xclient/subscribe`，其余字段结构不变，可据此区分加密拉取）。
2. 明文 `P` = JSON `{"status":<http 状态>,"headers":{"subscription-userinfo":…,"profile-update-interval":…,"content-disposition":…},"body_b64":"<b64u(正文)>"}`（被拦截的 403 空正文、提示节点 YAML 也照样封装）。
3. 加密：

```
eph       = X25519 新密钥对
shared    = X25519(eph.sk, device_pk)            // 全零则拒绝
salt      = random(32)   nonce = random(24)
info      = "xclient/v1/sub" ‖ 0x00 ‖ epk ‖ device_pk ‖ utf8(device_id)
key       = HKDF-SHA256(ikm=shared, salt=salt, info=info, L=32)
header    = {"v":1,"alg":"X25519-HKDF-SHA256-XCHACHA20POLY1305","kid":<env kid>,"epk":b64u,"salt":b64u,"nonce":b64u,
             "device_id":…,"req_nonce":…,"iat":now,"exp":now+600,"ctype":"application/json; xclient-sub","boot_seq":…,"policy_seq":…}
h         = b64u(json(header))
ct        = b64u(XChaCha20-Poly1305-IETF(key, nonce, P, aad=ASCII(h)))   // 密文‖16B tag
sig       = b64u(Ed25519(env_sk, ASCII("xclient-env-v1." ‖ h ‖ "." ‖ ct)))
```

客户端：kid 必须在受信 env 公钥集合（内置 + 有效 bootstrap 中的 `env_keys`）→ 验签 → `v==1`、`device_id`/`req_nonce` 与本次请求一致、`now ≤ exp+120`、`iat ≤ now+300` → 解密 → 按 `status` 处理：200 交给 Profile；其他按 SSRL 语义提示（403 = 账号不可用/被拦截）。
- 互操作：仓库 `test/xboard/vectors/envelope_v1.json` 由 PHP 生成（固定密钥），Dart 单测解密验签；CI 双向校验。

## 5. 端点发现（C8、C9）

### 5.1 bootstrap 文档

```json
{"v":1,"kid":"<ctrl kid>","payload":"<b64u(json)>","sig":"<b64u(Ed25519(ctrl_sk,\"xclient-boot-v1.\"‖payload))>"}
```

payload：

```json
{"schema":1,"brand":"98k","seq":1730000000,"issued_at":…,"expires_at":…,
 "api":[{"url":"https://…","weight":100}],
 "sources":["https://…/boot-98k.json", …],
 "env_keys":[{"kid":"env-1","pub":"<b64u>","not_after":…}],
 "pins":{"<host>":{"mode":"off|report|enforce","spki":["<b64 sha256>"]}},
 "poll":{"fg":60,"bg":900},
 "obf":true}
```

- 当 `obf=true`（默认），OSS 上的文件把 `payload` 再用品牌内置的 32B 混淆密钥做 XChaCha20-Poly1305 加密（`payload` 字段换成 `{"n":nonce,"c":ct}` 的 b64u JSON），避免公开存储里直接暴露域名。这只是混淆，安全性靠签名。
- 校验：kid ∈ 内置 ctrl 公钥（当前 + 备用）→ 验签 → `brand` 一致 → `seq ≥ last_good.seq`（防回滚）→ 未过期（过期则继续用 last-good 并标 stale）→ 所有 URL 必须 https。通过后原子写入 last-good 缓存（含签名原文）。

### 5.2 来源与回落顺序

L0 last-good 缓存 + 构建期内置 bootstrap（明文内置端点列表，随品牌注入）→ L1 当前可用 API `GET /api/v1/xclient/bootstrap` → L2 OSS/CDN 池（`sources`，S3 兼容、R2、GitHub raw/jsDelivr、自建静态站，均为同一份签名文件）→ L3 DoH TXT（`_xc.<品牌 DoH 名>`，多解析器：alidns、doh.pub、1.1.1.1、dns.google；TXT 值为 `xc1:` + b64u(签名 bootstrap 精简版，只含 api/seq/expires)，按 255 字节分段）。
- 竞速：L1 先发，300ms 无结果则并发 L2（源间错开 250ms），首个验签通过且 seq ≥ last_good 的胜出；单源 5s 超时，总预算 15s；全部失败再 L3。
- API 端点池：按 weight + 最近成功延迟排序；任一请求连接/TLS/5xx 连续失败 2 次 → 切下一个端点并触发 bootstrap 刷新；端点全挂 → L2/L3。

### 5.3 pinning

`pins[host].mode`：`off`（默认）/`report`（不一致只记录）/`enforce`（不一致拒绝）。SPKI = 证书公钥 DER 的 SHA-256（base64）。实现：`badCertificateCallback` 不用于 pin；在 TLS 握手成功后、发送任何请求字节前，从 SecureSocket.peerCertificate 提取叶子证书 SPKI 校验。dart:io 不提供完整证书链，不能宣称支持 CA pin；正常证书链校验始终开启，pin 不绕过自签/过期证书错误。

## 6. 远控实时推送（C9/C27）

C27 已授权的主动通道：独立 Swoole 进程承载 SSE，普通 Octane worker 不持有长连接。登录并完成设备注册后 POST `/api/v1/xclient/push/ticket`，获得60秒有效的一次性票据；向同一成功 API 端点 GET `/api/v1/xclient/events`，以 `Authorization: XClientPush <ticket>` 认证，禁止票据进入 URL。`event: seq` 的 data 为 `{boot_seq,policy_seq}`；它只触发拉取，所有文档继续验签。首次连接立即发送当前序号、20秒心跳、120秒轮换；注销/后台关闭，前台重连，错误采用带抖动退避。票据原子消费，定期复核账号token与设备吊销。现有轮询/OSS/DoH兜底保留。运行验证状态见 README，不把协议目标当作已完成证据。

- 插件把后台配置（API 列表、OSS 源、更新策略、公告）求值成 `boot_seq`、`policy_seq`（配置变化即变化），每个插件响应都带 `X-XClient-Seq`。
- 客户端：发现 `b` 大于本地 → 立即刷新 bootstrap；`p` 大于本地 → 立即拉 `state`。前台每 60s、后台每 15min `GET state`（ETag/304）。另外 OSS 层每 6h 校验一次。
- 插件在配置变化时（定时任务每分钟比对哈希）把签名 bootstrap 写到配置的 OSS 目标（S3 SigV4 PUT / GitHub contents API），实现“改一处，所有池同步”。

## 7. 更新（C10、C11）

### 7.1 策略文档（面板在线签名，远控开关）

```json
{"v":1,"kid":"<ctrl kid>","payload":"<b64u(json)>","sig":"<b64u(Ed25519(ctrl_sk,\"xclient-policy-v1.\"‖payload))>"}
```

payload：`{"brand","seq","latest":"1.2.0","min_supported":"1.1.0","force":false,"notes":"…","release_urls":["https://…/98k-release-v1.2.0.json", …],"notice":{"id","title","body","level"}?}`

- `latest > 当前` 且非强制 → 普通更新通知（可“稍后”，同一版本每 24h 最多提醒一次）。
- `force=true` 且 `latest > 当前`，或 `当前 < min_supported` → 强制更新：自动下载并安装；未完成前禁用“连接”，但账号、购买、工单页仍可用。

### 7.2 发布事实文档（CI 离线签名）

```json
{"v":1,"kid":"rel-1","payload":"<b64u(json)>","sig":"<b64u(Ed25519(rel_sk,\"xclient-rel-v1.\"‖payload))>"}
```

payload：`{"brand","version","build","published_at","assets":{"android-arm64-v8a":{"urls":[…],"sha256","size"},"android-armeabi-v7a":…,"android-x86_64":…,"windows-x64":…,"macos-universal":{"urls":[…],"sha256","size","kind":"zip"}}}`

- 客户端：rel kid ∈ 内置 → 验签 → brand/version 与策略一致 → 下载（多 URL 依次）→ 校验 size + sha256 → 安装。
- Android：PackageInstaller（自写 MethodChannel，需“安装未知应用”权限）；Windows：Inno Setup 安装包 `/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS` 后退出，安装器结束后重启 App；macOS：zip 解压到同卷临时目录 → `codesign --verify` → 脚本替换 `.app` 并重启。

## 8. 连通性探测、延迟展示与地区故障转移（C20–C22）

- **展示（C20）**：显示值 `d = round(10 + 100 * r / (r + 150))`，`r` 为最近一次真实连通探测耗时（ms）；结果恒在 [10,110)，单调；同一节点在两次真实探测之间显示值不变。超时/失败 → 红色“超时”。所有展示延迟的位置（节点卡片、分组、托盘、仪表盘）统一用此函数；排序按显示值（等价于真实值）。
- **探测（C21）**：`ProbeScheduler` 全局单队列，并发 1；节点间隔随机 2–8s；每节点最短复测间隔随机 20–40min；只在内核运行时工作。用户点“测速”只播放动画并读缓存，未知状态节点入队（不插队、不突发）。下发配置写入前改写：所有 `url-test`/`fallback`/`load-balance` 组 `lazy: true`、`interval ≥ 1800`。
- **故障转移（C22）**：`RegionFailover` 监视当前选中节点：
  - 判定信号：内核日志中当前节点的拨号失败（`dial … error`/超时）在 20s 内 ≥ 3 次；或有活动连接但 15s 内总流量为 0 且有新建连接失败；任一信号触发后对当前节点做 1 次真实探测确认（超时 5s）。
  - 确认故障后：在**同地区**节点里按“最近成功时间优先、其余随机”排序，并发 2、间隔 300–800ms 随机抖动探测，**第一个通过的立即切换**（`changeProxy`），并关闭经由旧节点的连接，让应用立即重连；其余候选继续低速补测更新缓存。同地区全部不通 → 通知用户并保持原选择（不跨地区自动切换，除非用户开启“允许跨地区”）。
  - 地区识别：节点名中的国旗 emoji / 中文地名 / 英文国家名或 ISO 代码（表驱动，可扩展），识别不到归入“其他”。
  - 故障转移期间的同地区探测是唯一允许的“突发”，单次故障最多探测该地区全部节点一轮。

## 9. 账号功能（C12–C14）

对标 LiquidNext / ez 主题（见 `docs/research/02` 页面对照表，本地资料）：
仪表盘（流量、到期、重置日、流量周期、公告）、套餐列表与详情、下单（周期、优惠券、余额抵扣）、支付（`checkout` type 0 二维码 / 1 跳转浏览器 / -1 已支付，轮询 `order/check`）、订单列表与详情（含支付截止时间、取消）、工单（列表、新建、回复、关闭）、公告、知识库、邀请（邀请码、佣金、明细、划转/提现）、流量明细、登录记录、流量周期、设备管理（插件）、修改密码、重置订阅（安全）、通知设置。注册/找回密码打开站点网页。

## 10. 构建与发布（C15、C16）

- 公开仓库只含源码与流程；品牌资料、内置端点、ctrl/rel/env 公钥和混淆材料放私有仓库 `xclient-brands`（CI 用只读 deploy key 检出）。签名私钥与 Android keystore 只保存在本地秘密目录及 CI secrets，不放入任何 Git 仓库。
- CI：`xclient-build.yaml`（push/PR：测试 + 各平台 debug 构建）、`xclient-release.yaml`（tag `v*`：3 品牌 × {android, windows, macos} 构建 → 发布事实文档签名 → GitHub Release）。
- 自签：Android 自有 keystore；macOS ad-hoc；Windows 不签（C24）。

## 11. 已核对的互通补充

- 插件目录为 `XclientGateway`，对应 `Str::studly(xclient_gateway)`；未登录返回401；设备保存 token_id，吊销时同步吊销该登录token。
- Bootstrap 混淆为 `b64u(json{n,c})`；n为24字节nonce，c为XChaCha20-Poly1305-IETF密文，AAD为空。签名始终覆盖未混淆的payload字符串。
- DoH mini payload带 `mini:true`，不能覆盖完整last-good缓存或清空其中的env_keys/sources。
- Subscribe明文headers仅包含实际存在的头；env_keys.not_after为签发后180天。Bootstrap半寿命重签并推进seq；seq取max(旧值+1,当前Unix秒)。
- macOS双runner分架构构建后合并universal并ad-hoc签名；更新事实只列zip，dmg供首次安装。ad-hoc包的真实性依赖离线发布签名与sha256，codesign验证内部完整性，不能比较不同版本的CDHash。
- 同版本预发布到正式发布的Android构建号必须严格递增，构建工具与CI用同一受限SemVer编码；具体范围以tool/xclient/README.md和测试为准。

## 12. 订阅准入与恢复（C28）

- Flux/SSRL仍是准入规则的唯一执行方；客户端HTTPS直连保留真实拉取来源，不绕过云IP/风险/停用/流量等限制。
- 已加密并签名的订阅明文可以附带 `admission:{status:"blocked",code,message,retry_after:60}`。被拒绝时body_b64为空，不下发真实或提示用节点；无此可选字段的v1文档保持兼容，HTTP403仍按明确拒绝处理。
- SSRL提示响应内部通过bounded的X-XClient-Admission头向网关传递结构化原因，正常订阅无此头；网关不把它暴露在未签名外层。旧版本严格的notice-only哨兵与尾句可作兼容回退，不能仅凭云厂商名称或节点名猜测。
- 明确拒绝先发布blocked门禁，再停止连接并清除托管缓存；清理失败也不能变为可连接。账号/套餐/工单仍可用。正常临时网络错误可保留此前已验证的配置。
- App显示真实原因与建议、一次性弹窗和持续状态；节点页不展示旧节点为可选状态。提供重新检查，中心节流与inflight合并防连点；自动重试默认60秒逐渐退避到5分钟并尊重429，网络变化/前台恢复可触发有节流复查。服务端重新允许且配置已成功apply后才解禁。

## 13. 远控发现池完整快照（C29）

完整bootstrap可附带`discovery`，受同一brand/签名/有效期/单调seq保护。存在时是完整替换，不能与旧池或内置地址合并：

```json
{
  "version": 1,
  "api_pools": [{"id": "primary", "enabled": true, "endpoints": [{"url": "https://api.example.invalid", "weight": 100}]}],
  "oss_pools": [{"id": "backup", "enabled": true, "urls": ["https://storage.example.invalid/bootstrap.json"]}],
  "doh": {"names": ["_xc.example.invalid"], "resolvers": ["https://dns.example.invalid/dns-query"]}
}
```

- 四个字段都必需；API/OSS池各最多32个、每池最多32地址，唯一id为1–64个ASCII字母/数字/点/横线/下划线；enabled为布尔值。API权重为整数1–1000；全部地址必须是有效HTTPS，无用户信息、片段、控制符或空白。DoH最多32域名/16解析器。停用池也需校验。去重后按配置顺序使用启用池。
- 面板可通过可选`discovery` JSON配置发布；缺失/空文本兼容旧flat配置。非空错误配置不发布坏快照、不推进boot seq、不镜像，保留此前签名last-good，其他账号API继续可用。有效快照同时派生旧`api`/`sources`字段，供旧客户端读取；现有v1向量保持不变。
- 客户端原子验整份文档，持久化签名原文。显式空API池清空活动API；无discovery的旧文档保留旧empty API兼容语义。mini仅更新有效API/seq，不得擦除完整池、OSS/DoH、pin/env元数据。
- 当前远控API/OSS优先，其次远控DoH；这些失败后才使用编译内置的最后救援入口。内置API只用于获取签名bootstrap，不能直接恢复成活动池。首次启动无有效缓存时也先发现再恢复账号；有缓存则先恢复已验签快照。被移除的非内置URL不会复活；救援仍拒绝回滚、错误品牌或无效签名。
- OSS竞速有并发和总时限限制；多个刷新轮次公平推进，后部地址不能永久饥饿。API URL/顺序或pin实际变化才重连推送；重复快照不反复断流。池变更继续通过推送序号、HTTP响应头及兜底轮询触发获取签名正文。
- mini更新API后会按序号安排一次延后完整文档追赶；失败不递归自旋，后续同序号提示可以节流重试。缺少完整文档时，sources-only刷新也会向有效API补取full。提示判断参考lastFullSeq，签名防回滚仍以有效序号为准，不能借补全文档采用旧full。
- 内置种子是最后救援锚点。发行品牌若未配置初始OSS/DoH且所有内置API同时不可达，首次安装仍无法取得任何远控文档；发行前必须配置并验证独立可用的救援资源。支持任意HTTPS存储商不代表已经部署或验证了各存储商上传。
