<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views

## Purpose
所有 SwiftUI 视图，按功能域组织。界面方向已定稿（Liquid Glass 的控件层 + 中性的内容层 + 一个强调色），设计常量、玻璃包装和共享组件都在 `Theme/`，页面只用它们拼。

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `MainWindow/` | 主窗口外壳：`NavigationSplitView`、工具栏、会话标签栏、检查器（见 `MainWindow/AGENTS.md`） |
| `Sidebar/` | 系统侧边栏（见 `Sidebar/AGENTS.md`） |
| `Terminal/` | 终端标签内容：分屏窗格树、状态卡片、代码片段检查器（见 `Terminal/AGENTS.md`） |
| `Hosts/` | 主机卡片页（档案按需在右侧面板展开）、主机/分组/转发表单、身份、快速连接（见 `Hosts/AGENTS.md`） |
| `SFTP/` | 双面板文件浏览、传输队列、远程编辑栏（见 `SFTP/AGENTS.md`） |
| `Keys/` | 密钥库和已知主机（见 `Keys/AGENTS.md`） |
| `DevOps/` | 端口转发、代码片段、批量命令、监控、Docker、历史记录（见 `DevOps/AGENTS.md`） |
| `Security/` | 锁屏和主密码设置（见 `Security/AGENTS.md`） |
| `Settings/` | 设置窗口（⌘,）（见 `Settings/AGENTS.md`） |
| `Shared/` | 会话标签栏、命令面板、快捷键、认证弹窗等（见 `Shared/AGENTS.md`） |

## For AI Agents

### Working In This Directory
- **三条硬规则**（全文见 `Theme/AGENTS.md`）：
  1. 玻璃只在控件与导航层（侧边栏、工具栏项、按钮、浮动条、弹窗）；内容层（卡片、行、图表）不用玻璃；不叠玻璃；只有唯一的主操作上色；圆角同心 26 → 18 → 10。
  2. 颜色克制：中性表面 + 一个强调色（主操作、选中、数据）；绿 / 橙 / 红只表示状态并总带词或字形；页面和类别不按颜色区分；唯一自由的颜色是主机方块（发行版的颜色）。
  3. 数据进固定列：数字右对齐、等宽数字，单位和标签位置固定，并排的值之间有细分隔线，什么都不换行。
- **同一信息只出现一处**（加模块前先问：这条信息屏幕上已经有了吗）：会话只在工具栏标签里，侧边栏只列页面；主机名在行里和记录里各一次，不在标题栏、状态条、检查器里再写；一个区域里的计数只写一次；侧边栏徽标只表示「正在发生」，不重复列表总数；同一条曲线只画一次；路线图只在有跳板机时画（`DSRouteDiagram.addsSomething(hopCount:)`）；没有的东西不画占位（不写一排「—」）；说明文字放在动作发生的那一刻，不常驻页面。
- **玻璃包装规则**：页面**不直接写任何玻璃 API**（`glassEffect`、`GlassEffectContainer`、`.buttonStyle(.glass / .glassProminent)`、`backgroundExtensionEffect`、`scrollEdgeEffectStyle`、`ToolbarSpacer`…），只用 `Theme/Glass.swift` 的包装：`.dsButtonStyle(.prominent / .glass)`、`DSGlassIconButton`、`.dsFloatingBar()`、`.dsFloatingPanel()`、`DSFilterChip`、`.dsGlass()`、`DSGlassContainer`。系统组件（侧边栏、`.toolbar`、`.sheet`）的玻璃由系统给。
- **工具链规则**：同一份源码要在 Xcode 27（本机）、Xcode 26（CI，发布）、Xcode 16.2（CI，Swift 6.0 / macOS 15 SDK）上都能编译通过；部署目标 macOS 15。macOS 26 SDK 才有的 API 只能出现在 `Theme/Glass.swift` 的 `#if compiler(>=6.2)` + `if #available(macOS 26.0, *)` 里。Swift 6.0 的坑见 `Theme/AGENTS.md`。
- **页面不自己画标题栏**：窗口标题由 `MainWindowView` 设（页面不要调 `.navigationTitle`）；页面用 `.navigationSubtitle` 放上下文，用 `.toolbar` 放操作，用 `.searchable` 放搜索。
- **页面有三种骨架**：骨架 A 主从（`DSMasterDetail`：主栏 `DSMasterList` + `.dsListRow(isSelected:)`，进入页面自动选中一项，详情顶部是 `DSDetailHeader`）、骨架 B 居中栏（`.dsCenteredColumn()`，最宽 760），以及**只给主机页用的骨架 C：整页卡片 + 按需展开的档案**（卡片铺满页面宽度，进入页面不选中任何卡片；档案只在点卡片上的按钮 / ⌘I / 右键「显示详情」时才在页内右侧 380 的面板里展开，可关闭，卡片随之重排）。为什么有 C：机主用过之后的要求（2026-10-07，参照 Termius）——主机页要先看到全部主机，详情要自己点了才出来。别的页面不要照搬 C，也不要把主机页改回 A。详情栏 / 面板背后是 `.dsStageBackground()`。
- 页内不得再挂 `.inspector`（窗口唯一的检查器属于终端）；不用 `HSplitView`（macOS 26 上按理想宽度撑开）。
- **每屏只有一个 `.dsButtonStyle(.prominent)`**，在详情头右侧或编辑器右下；其余是 `.glass`。一屏最多一张 `hero` 卡。
- 主机一律 `DSHostAvatar` / `DSHostRow`，不手拼方块；数字用 `DSStatCard`，水位用 `DSGaugeCard`，并排的值用 `DSDividedRow` + `DSValueCell`，成组的行用 `DSSectionHeader` + `DSGroup` + `DSRow` / `DSKeyValueRow` / `DSLinkRow`，状态用 `DSStatusPill`，标签用 `DSChip`（组件表见 `Theme/AGENTS.md`）。
- `Table` 只用于历史与 Docker 容器；空状态用 `DSEmptyState`（给下一步；需要选主机的页面再给 `DSHostPickerGrid`），弹窗用 `Form(.grouped)` + `.toolbar` 的 `.cancellationAction` / `.confirmationAction`。
- 持续动画（`repeatForever`）用 `.animation(_:value:)` 限定在那个视图上，不用 `withAnimation` 包——否则同屏的玻璃按钮会一直糊着。
- 破坏性操作用 `.confirmationDialog` / `.alert` 确认，按钮带 `role: .destructive`。
- 所有可见文字走字符串目录（`Localizable.xcstrings`，en + zh-Hans）：字面量直接写进 `Text` / `Label` / `Button`；来自数据的文字用 `Text(verbatim:)`。加了新字面量要补 zh-Hans。
- 只有图标的按钮必须有 `.help(...)`（也作为无障碍标签）。
- 视图通过 `@Environment` 拿 `AppViewModel`（每窗口一个），页面自己的 ViewModel 用 `@State`；**不要**在视图里直接用 Repository / Service。

### Testing Requirements
- 没有自动化 UI 测试；改布局后在 900×600、默认尺寸、全屏，以及浅色/深色下各看一遍。
- DEBUG 构建支持启动参数直接进入某个页面或弹窗（`WindowRootView.applyDebugLaunchArguments`），便于截图检查；`-debugSheet gallery -debugGalleryPage 1…5` 是共享组件的样张（`Theme/DesignGallery.swift`），按定稿样张的版式摆，改页面时并排对比。
- 业务逻辑在 ViewModel / Service 层有单元测试。

## Dependencies

### Internal
- `ViewModels/` — 所有 ViewModel
- `Theme/` — 设计常量、玻璃包装与共享组件

<!-- MANUAL: -->
