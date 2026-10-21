<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/MainWindow

## Purpose
主窗口外壳。`NavigationSplitView`：左边系统侧边栏，右边是当前页面或终端。窗口用统一工具栏（`.windowToolbarStyle(.unified)`）；看终端时工具栏里没有标题，而是会话标签组、最近主机菜单和终端工具组，浮在终端上面。

## Key Files

| File | Description |
|------|-------------|
| `WindowRootView.swift` | 每个窗口的根：创建该窗口自己的 `AppViewModel`，叠加锁屏，挂载命令面板、快捷键、快速连接三个 sheet，应用外观设置；DEBUG 下解析 `-debugPage` / `-debugSheet` / `-debugConnect` 等启动参数 |
| `MainWindowView.swift` | 外壳布局、窗口标题、页面上的会话方块组、终端工具栏（会话标签 `TabBarView`、`RecentHostsMenu`、拆分 / 广播 / 片段 / SFTP）、代码片段检查器（`.inspector`）、toast；`WindowRegistrar` 把 NSWindow 登记给 `AppDelegate`（关窗确认、结束会话） |

## For AI Agents

### Working In This Directory
- 显示什么由 `AppViewModel` 的两个状态决定：`selectedSidebar`（哪个页面）和 `isViewingTerminal`（是否在看终端）。会话只有一份清单——工具栏 `.navigation` 位的标签组：看终端时是完整标签；在页面上以「只剩方块」的形态留在原位（`TabBarView(tilesOnly: true)`：点击回到该会话、方块上的状态点、悬停提示标题 + ⌘n、右键菜单、拖动排序都在，没有「+」），宽度由 `pageTabsWidth(detailWidth:)` 给（最多 6 个方块，窄窗口更少），放不下的进「+N」菜单。侧边栏没有会话分区，⌘1…9 和「标签」菜单在任何页面都有效。
- 标签组是工具栏的一个 `.navigation` 项（玻璃由系统给，不要自己再包）。它能占多宽由 `detailWidth - toolbarReserve` 传进去，`TabBarView.sizing` 决定：自然宽度 → 等分 → 只有活动标签带标题、其余缩成方块（放不下的在「+N」菜单里；`sizing` 已为「+N」留出宽度）。**不要在工具栏项里放 `ScrollView`**（偏移会丢）。
- 看终端时：`.toolbar(removing: .title)` + 工具栏背景隐藏 + 终端主题色只向上（`.top`）铺到窗口边；两侧不能铺（会染到侧边栏和检查器）。标签文字的深浅跟终端主题走，不跟窗口外观走。没有标题时用一个 `Spacer()` 工具栏项把工具组推到右边。这套「浮在终端上」只在系统给工具栏项玻璃时启用（`MainWindowView.toolbarFloats`：macOS 26 SDK 构建且运行在 macOS 26）；否则工具栏保留自己的底、标签跟窗口外观走——没有玻璃时深色终端上的浅色外观图标会看不清。
- 锁定时工具栏里不放标签和最近主机（它们带主机名）。
- `TerminalTabView` **始终留在视图树里**（用 opacity 隐藏），这样切页面不会断开会话；页面只在显示时才构建，它的工具栏项随之出现/消失。
- 窗口标题在这里统一设置（终端 = 标签名，页面 = 侧边栏项名），页面不要再调 `.navigationTitle`。
- 「设置」不是页面：选中 `.settings` 会打开设置窗口（`openSettings()`）并把选中项还原。
- 终端相关的工具栏项（最近主机、拆分、广播、代码片段、SFTP）只在看终端时出现（标签组在页面上缩成方块）；对应的菜单命令在 `App/TermiApp.swift`。

## Dependencies

### Internal
- `Views/Sidebar/SidebarView.swift`、`Views/Shared/TabBarView.swift`、`Views/Terminal/`
- `ViewModels/AppViewModel.swift` — 导航、标签、窗格、会话
- `App/AppDelegate.swift` — 窗口登记与关闭确认

<!-- MANUAL: -->
