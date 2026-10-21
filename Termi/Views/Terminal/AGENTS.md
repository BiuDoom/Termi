<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/Terminal

## Purpose
终端视图层：标签内的分屏窗格（`PaneLayout` 树）、窗格头、底部浮动的会话状态条、连接状态卡片、检查器（片段 | 信息）。终端渲染与输入由 SwiftTerm 完成；会话生命周期由 `ViewModels/TerminalSession.swift` 管理（会话属于模型而不是视图，切换侧边栏/标签不会断开）。终端本身是内容层（按终端主题上色）；浮在它上面的状态条和状态卡片是玻璃，跟窗口外观走。

## Key Files

| File | Description |
|------|-------------|
| `TerminalTabView.swift` | 一个标签：按 `PaneLayout` 递归布局窗格（`PaneSplit`：默认等分、分隔线可拖动、有最小尺寸）；`PaneHeader`（仅分屏时：主机方块 + 名称 + 程序标题 + 关闭，焦点窗格头是强调色，广播时所有窗格头是警示色 + 广播字形——**窗格四周不再画描边**）；`SessionStatusBar`（`.safeAreaInset(.bottom)` 里的浮动玻璃胶囊：地址 / 经跳板、状态 + 已连接时长、隧道数、列×行、主题，窄了依次丢主题 → 尺寸）；`SessionOverlayView` + `SessionStateCard`（连接中 / 重连中 / 失败 / 已结束的玻璃卡片，SFTP 页也用它；窗格太小时退成只有标题和按钮的紧凑卡片）；`TerminalHostView` 把会话持有的 NSView 挂进 SwiftUI |
| `BiuTerminalView.swift` | `LocalProcessTerminalView` 子类：广播输入钩子、右键菜单、查找、选中即拷贝 |
| `SnippetPanelView.swift` | 检查器（由 `MainWindowView` 用 `.inspector` 挂在终端右侧，入口类型名不变）：顶部分段「片段 \| 信息」（`@AppStorage("terminalInspectorTab")`）。片段页：搜索、按类别分组、粘贴/运行到聚焦窗格，带变量的行有 `{} N` 标签，`{{变量}}` 填写表单。信息页（`SessionInfoView`）：主机头、路线、会话（状态 / 时长 / 尺寸 / 主题 / 认证）、该主机的端口转发开关、主机（系统 / 分组 / 启动片段）、「在监控中打开」「在主机页显示」——**只放已知信息，不在远端执行任何命令** |

## For AI Agents

### Working In This Directory
- 不要在视图里创建或结束会话：通过 `AppViewModel`（`addSSHTab`、`splitFocusedPane`、`closePane`…）和 `TerminalSession`（`startIfNeeded`、`reconnect`、`type`…）
- 终端 NSView 由 `TerminalSession.ensureTerminalView()` 持有，视图层只做挂载（re-parenting），不要在 `makeNSView` 里新建终端
- 终端区域内的内容层元素（分隔线、窗格头）按标签的终端主题明暗取 `colorScheme`；浮在上面的玻璃（状态条、状态卡片）跟窗口外观：`\.terminalWindowScheme` 带着窗口的 `colorScheme` 进终端区域，玻璃下面垫一层窗口底色（`.terminalGlassBed`）——玻璃的明暗取自它后面的内容，浅色窗口里的深色终端会把它染成看不清字的灰
- 终端区域的底色跟随终端主题（`TerminalContainerNSView` 把四周留白也涂成终端背景色），状态条所在的那一条也是；状态条在安全区里，**不盖住终端最后一行**
- 界面显示的状态一律读 `session.displayState`（DEBUG 下可被 `-debugSessionState` 覆盖），逻辑判断仍用 `state` / `isLive`
- 主机方块用 `appViewModel.currentHost(of:)`：会话保留连接时的主机记录，系统是连接之后才读到的
- 关闭窗格的 × 走 ⌘W 的同一个确认（先 `focus(paneId:)` 再 `confirmAndCloseFocusedPane()`）
- SwiftTerm 固定在 1.18.x（`project.yml`），重写的方法必须是 SwiftTerm 中的 `open` 方法
- 这个文件里 `Color` 与 `SwiftTerm.Color` 重名：类型位置写 `SwiftUI.Color`

### Testing Requirements
DEBUG 启动参数（截图用）：`-debugConnect <label>` `-debugSplit N` `-debugSnippets YES` `-debugBroadcast YES`（`WindowRootView`）；`-terminalInspectorTab snippets|info`；`-debugSessionState connecting|reconnecting|failed|ended`（只画状态卡片，不连接）；`-debugSampleForwards YES`（信息页里两条示例转发）。

## Dependencies

### Internal
- `ViewModels/AppViewModel.swift` — 标签、窗格、会话表
- `ViewModels/TerminalSession.swift` — 会话状态与 I/O
- `Services/SSH/SSHService.swift` — SSH 主连接

<!-- MANUAL: -->
