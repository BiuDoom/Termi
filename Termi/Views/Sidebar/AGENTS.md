<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/Sidebar

## Purpose
系统侧边栏（`List` + `.listStyle(.sidebar)`）。只有页面，没有「会话」分区（会话只有一份清单：工具栏里的标签组，见 `Views/MainWindow/AGENTS.md`）。三组：连接（主机、SFTP、端口转发、代码片段）、保险库（密钥库、身份、已知主机）、工具（批量命令、监控、Docker、历史记录）；列表下面是设置（`SettingsLink`）和锁定按钮。

## Key Files

| File | Description |
|------|-------------|
| `SidebarView.swift` | 侧边栏；`AppViewModel.sidebarSelection`（`SidebarItem?`）/ `select(_:)` / `badge(for:)`。看终端时**不选中任何行**（这样点「主机」是一次选中变化，才会真的切回主机页），看页面时是页面那一行 |

## For AI Agents

### Working In This Directory
- 导航项是 `SidebarItem`（定义在 `ViewModels/AppViewModel.swift`），标题和图标来自它的 `label` / `icon`；标题要在字符串目录里有 zh-Hans。
- 新增页面：给 `SidebarItem` 加 case → 在这里放进某一组 → 在 `MainWindowView.contentView` 加分支 → 命令面板的「前往」会自动带上。
- 页面行是 `DSSidebarLabel`（强调色字形，没有方块）+ `.badge(数字)`；数字来自 `AppViewModel.badge(for:)`，只表示「正在发生」：SFTP 是进行中的传输数，端口转发是运行中的隧道数；0 不显示。**不要给页面加库存数徽标**（有多少主机 / 密钥 / 片段写在页面自己的分区头或筛选药丸里）。
- 不要把会话放回侧边栏：开关会话会让其余行上下跳，而且与工具栏标签重复。
- 选中高亮是系统的；`selectionTint` 只在它上面叠一层强调色（和活动标签同一种胶囊）。不要再加悬停效果。
- 底栏放在 `List` 下面（`VStack`），不是 `safeAreaInset`：窗口矮时行会从透明的底栏后面透出来。

## Dependencies

### Internal
- `ViewModels/AppViewModel.swift` — `selectedSidebar`、`isViewingTerminal`、`sftp`
- `ViewModels/SecurityViewModel.swift` — 锁定按钮

<!-- MANUAL: -->
