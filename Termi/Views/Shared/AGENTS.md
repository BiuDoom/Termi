<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-04 -->

# Views/Shared

## Purpose
跨功能域复用的界面部件（纯样式的小组件在 `Theme/Components.swift`）。

## Key Files

| File | Description |
|------|-------------|
| `TabBarView.swift` | 会话标签：只在终端页，作为窗口工具栏里的一项（玻璃胶囊由系统给）。每个标签是主机方块 + 状态点（最坏的状态优先）、窗格数、广播标记；当前标签的关闭按钮常显，其余悬停出现；放不下时非当前标签收成方块，再多的进「+N」菜单；右键菜单（`TabMenuItems`，与侧边栏的会话行共用）、拖动排序。页面上没有标签栏，回到会话走侧边栏的「会话」分区 |
| `CommandPaletteView.swift` | 命令面板（⌘K）：打开的会话（可切换）、操作、前往页面、主机（空查询时列最近连接的五台，带上次连接时间）、代码片段；↑ / ↓ 选择、回车执行、⌘↩ 在 SFTP 中打开所选主机；底部一行按键提示和结果数 |
| `KeyboardShortcutsView.swift` | 快捷键一览（⌘/） |
| `AuthPromptPresenter.swift` | askpass 桥的界面端：密码 / 密码短语 / 2FA / 主机指纹确认弹窗（NSAlert），可选「保存到保险库」 |
| `ASCIISecureField.swift` | 密码输入框（NSSecureTextField）：编辑时把输入法限制为英文，避免中文输入法截获按键；`isBezeled: false` 用在分组表单行里；跟随 `.controlSize` |
| `DevOpsHostRowView.swift` | 工具页共用的主机行 / 无主机空状态（批量命令在用）；`DevOpsHostList` 已无引用（监控与 Docker 改用 `MonitoringView.swift` 里的 `ToolsHostMaster`） |

## For AI Agents

### Working In This Directory
- 密码、密码短语一律用 `ASCIISecureField`，不要用 `SecureField`。
- `AuthPromptPresenter` 的弹窗里秘密只经 askpass 的 Unix socket 回到 ssh，不要把它们写进日志、命令行或环境变量。
- 命令面板、快捷键、快速连接由 `WindowRootView` 以 sheet 形式挂载，开关状态在 `AppViewModel`。

## Dependencies

### Internal
- `ViewModels/AppViewModel.swift`
- `Services/SSH/SSHAskpass.swift` — 认证提示来源

<!-- MANUAL: -->
