# XClient 设计系统

品牌客户端（`lib/xboard/ui/`）的界面约定。代码入口：`common/tokens.dart`（令牌）、`common/components.dart`（组件）、`common/motion.dart`（动效）。底层沿用上游 FlClash 的 `SurfaceLevel`、`AppShape`（superellipse）、`AppTextStyle`、`AppGlyphs`、`ElasticPress`，这里只做品牌层组合，不另起一套。

## 设计取向

- **一屏一个主角**：每页只有一个主按钮（渐变 + 柔光），其余操作用次级或文字按钮。首页主角是连接按钮。
- **状态先于数据**：先告诉新手"现在怎样、下一步做什么"（连接状态、智能提示），再给细节（套餐、流量、公告）。
- **安静的表面，鲜明的状态**：卡片靠表面层级区分，不加边框；颜色只用在状态（图标、徽章、进度环），大面积着色只留给阻断性提示。
- **动效解释变化**：只为状态切换、页面切换、数值变化做动画；系统"减少动画"开启时全部即时完成。

## 令牌

| 类别 | 令牌 | 值 |
|---|---|---|
| 间距 `XcSpace` | `xxs / xs / sm / md / lg / xl / xxl / huge` | 4 / 8 / 12 / 16 / 20 / 24 / 32 / 48 dp |
| 页边距 | `gutterOf(width)` | 宽 < 380：16；≥ 840：32；其余 20 dp |
| 尺寸 | `minTouch` / `formWidth` / `readingWidth` / `contentWidth` | 48 / 420 / 880（单列阅读页最大宽度）/ 1120 dp |
| 断点 `XcBreakpoint` | `desktop` / `wide` | 840（侧边导航）/ 1100（侧边导航展开） |
| 圆角 `XcRadius` | `control / tile / card / hero / pill` | `AppShape.md / lg / xl / xxl / full`（16 / 20 / 24 / 28 / 全圆，superellipse） |
| 时长 `XcMotion` | `quick / standard / emphasized` | 160 / 280 / 460 ms |
| | `tween / celebrate / orbit / stagger` | 900（数值滚动）/ 1200（连接成功涟漪）/ 1400（连接中旋转一周）/ 70 ms（入场错峰） |
| 曲线 | `standardCurve / emphasizedCurve / exitCurve / settleCurve` | easeOutCubic / Cubic(0.2,0,0,1) / easeInCubic / Cubic(0.34,1.36,0.64,1)（轻微回弹，仅导航指示块） |
| 阴影 `XcShadow` | `card / float / glow(color)` | 浅色卡片两层柔影、深色无影；浮层（底部导航）；主色柔光（主按钮、连接按钮） |
| 文字 `XcType` | `display / figure / metric / pageTitle / title / headline / body / secondary / caption / label / value` | 基于 `AppTextStyle`（随系统字号缩放）；数字类（display、figure、metric、value）用等宽数字，滚动时不抖动 |

### 颜色 `XcColors`

`XcColors.of(context)` 从主题 `ColorScheme` 派生并缓存，**品牌只提供主色**，其余全部推导：

- 表面：`page / card / block / inset / float`（对应 `SurfaceLevel`），`hairline` 分隔线。
- 文字：`title`（onSurface）、`muted`（onSurfaceVariant）。
- 品牌：`accent`（primary）、`onAccent`、`accentLight`（色相 −12、明度 +10~12）、`accentDeep`（色相 +16、明度 −12~14）、`accentGradient`（三者斜向渐变）、`accentSoft`（主色 10%/20% 叠在卡片上）。
- 状态：`XcTone { neutral, accent, success, warning, danger }`。`toneOf` 用于文字；`vividOf` 提亮后用于描边、进度、图标；`softOf` 是图标底和徽章底；`washOf` 是阻断性提示的整块底色（深色明度 18、浅色明度 94，彩度封顶，不刺眼）。

三个品牌（98k / mg / yzy）只是主色不同；`visual_test.dart` 用青、紫、琥珀三种种子色验证浅色/深色都成立。

## 组件

| 组件 | 用途 | 要点 |
|---|---|---|
| `XcButton` | 主 / 次 / 文字 / 危险按钮，大 54、中 46、小 38 dp 高 | 主按钮渐变 + 柔光；`loading` 时禁用并显示转圈和 `loadingLabel`；按压轻微膨胀（`ElasticPress`） |
| `XcTaskButton` | 执行异步任务的按钮（`widgets.dart`） | 自动 loading，失败走 `xcMessage` |
| `XcPanel` | 卡片 / 面板 | `elevated` 浮起一层；`onTap` 时整卡可点 |
| `XcBadge` | 状态徽章 | 圆点或图标 + 文字，颜色来自 tone |
| `XcGlyphWell` | 圆形图标底 | tone 的 soft 底 + vivid 图标 |
| `XcMetric` | 指标块（标签 / 值 / 说明） | 合并为一个无障碍节点 |
| `XcMeter` / `XcRing` | 线形进度 / 环形进度 | 环形用扫描渐变；数值变化用 `XcAnimatedNumber` |
| `XcCallout` | 提示条（公告、建议、限制、错误） | `filled` 仅用于阻断性提示；可带操作、关闭按钮（必须有 tooltip） |
| `XcStateView` | 整页空态 / 错误态 | 72 dp 图标 + 标题 + 说明 + 一个主操作（可选一个次操作） |
| `SkeletonText` / `SkeletonPill`（上游 `lib/ui/skeleton.dart`） | 已在屏卡片里单个值的占位 | 只用于形状确定的单块（如首页套餐卡），外层给读屏标签；列表页不做占位行骨架，数据齐了一次出现（`.agents/architecture.md` Page Arrival） |
| `XcSectionHeader` | 分组标题 | 可带右侧操作 |
| `XcBottomActionBar` | 底部固定操作栏 | 摘要 + 按钮；手机结账页的合计与“创建订单”固定在底部，宽屏改为右侧摘要卡 |
| `XcBannerSlot` | 页顶横幅容器 | 统一页边距和最大宽度 |
| `XcFieldTheme` | 表单输入框主题 | 填充式、无边框，聚焦 2 dp 主色描边；`floating: true` 让标签浮到框上方，用于多字段表单 |
| `XcConnectionOrb` | 首页连接按钮 | 未连接 / 连接中 / 已连接 / 断开中 / 受限五态，见下方动效 |
| `XcBottomNav` / `XcSideNav` | 手机悬浮底栏 / 桌面侧栏 | 选中项用中性色滑块指示，不用大块主色 |

### 页面骨架（`widgets.dart`）

| 组件 | 用途 | 要点 |
|---|---|---|
| `XcPage` | 二级页面 | 标题栏 + 内容，内容最大宽 `readingWidth` 居中；`bottom` 放 `XcBottomActionBar` |
| `xcList(children)` | 页面主列表 | 页边距随宽度变化；底部自动留出悬浮底栏和系统手势区（`context.bottomInset`）；子项依次 `XcEntrance` |
| `XcSection` | 带标题的卡片分组 | 可选图标、右侧徽章或操作；内容按 `sm` 间距排列 |
| `XcValue` | 标签 / 值一行 | `strong` 用于合计金额；值可选中复制 |
| `XcMenuRow` | 导航行 | 图标井 + 标题 + 说明 + 右箭头，可带右侧徽章；整行最小 52 dp |
| `XcToggleRow` / `XcToggleTile` | 开关行 | 与 `XcMenuRow` 同一排版；`Tile` 版本在异步保存期间禁用开关、失败给提示 |

### 节点卡片（品牌模式）

`lib/xboard/ui/nodes_view.dart`：地区徽记（地区缩写）+ 节点名 + 延迟徽章 + 选中态，按地区分组。延迟只读缓存结果并经 `display_delay.dart` 映射；超时显示红色“超时”，没有缓存时显示中性“未测速”，不触发测速。上游 `lib/views/proxies/common.dart` 的 `ProxiesViewOverride` 是注入点：只有品牌模式在树上放了它，非品牌 FlClash 的节点页完全不变。

`XcLoad`（`widgets.dart`）统一了"加载中 → `CommonCircleLoading`、失败 → `XcStateView` + 重试、无数据 → 空态 + 刷新"。

## 动效规则

1. **入场**：`XcEntrance(index)` 淡入并上移 14 dp，同组按 70 ms 错峰，最多错 8 级；只播一次。
2. **页面切换**：`XcPageSwitcher` 用 fade-through（旧页先淡出，新页再升起），两套布局不会重叠；页标题跟随页面一起切换。
3. **文字 / 小部件替换**：`XcSwap`，旧内容先退场、新内容再进场，避免叠字。
4. **数值**：`XcAnimatedNumber` 从旧值滚动到新值，900 ms。
5. **连接**：点击后立即进入"连接中"（光环旋转、按钮显示进度），内核确认后渐变填满并放一次涟漪；20 秒内没有确认则回到原状态。连接中不响应重复点击。
6. **按压**：可点击元素用 `ElasticPress` 轻微膨胀，不用水波纹铺满。
7. **减少动画**：所有动效通过 `XcMotion.of` / `XcMotion.reduced` 读取系统设置，开启时时长为 0、循环动画不启动。

## 使用约定

- 新页面只用 `XcSpace`、`XcRadius`、`XcType`、`XcColors` 取值，不写裸数字颜色或字号；长度单位一律 dp。
- 形状一律 superellipse（`AppShape` / `XcRadius`）；图标一律 `AppGlyphs` + `GlyphIcon`；加载转圈用 `CommonCircleLoading`。这些由 `test/lint` 守卫。
- 图标按钮必须有 tooltip；输入框、按钮的文字即无障碍名称，Android QA 脚本依赖登录页的"邮箱""密码""登录"等可见文字，改动前先改脚本。
- 金额用 `context.xcMoney`（分 → 面板配置的货币）；延迟只用 `lib/xboard/probe/display_delay.dart`。
- 页面只换呈现，不改业务：API、provider、连接闸门、更新、生命周期逻辑不在设计系统范围内。
- 手机悬浮底栏下面的内容会滑到底栏后面（`Scaffold.extendBody`）；滚动列表一律用 `xcList` 或自行加 `context.bottomInset` 底部留白，保证最后一项能滚出底栏。
- 截图回归：`test/xboard/ui/visual_test.dart`（登录、首页、节点）与 `visual_phase2_test.dart`（商店、订单、账户、工单、礼品卡、邀请、更新、启动 / 退出），设置环境变量 `XC_UI_SCREENSHOTS=<目录>` 后运行会输出各尺寸 × 浅/深色 × 各状态截图；不设置时只做渲染断言。共享的尺寸、主题、字体与首页 harness 在 `visual_support.dart`。
