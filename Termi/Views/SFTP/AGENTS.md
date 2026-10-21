<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/SFTP

## Purpose
SFTP 页面。未连接时是主机挑选页（可搜索）：已有会话的主机在最前（复用现有连接，领头的那张带唯一的主操作），其余按分组排成卡片网格；连接中 / 连接失败是和终端同款的玻璃状态卡片。连接后是两张卡片：左本地、右远程，下面依次是远程编辑栏、浮动的玻璃传输条、提示条。状态在每窗口的 `AppViewModel.sftp`（`SFTPViewModel`）里，切页面不会断开。

## Key Files

| File | Description |
|------|-------------|
| `SFTPView.swift` | 页面容器：工具栏（显示隐藏文件——两侧面板唯一的开关、打开终端、断开；切换主机是远程面板头部名称上的菜单）、`SFTPHostPicker`（挑选页：没有标题带，分组标题只在有「已连接」、≥2 组或正在搜索时出现，计数只在搜索时出现）、连接状态卡片、`FilePanelSplit`（两张卡片等分，中间的空隙可拖动；不用 `HSplitView`）、`TransferQueueView`（浮动传输条：每项的进度 / 速度 / 剩余时间 / 取消；总进度块只在进行中 ≥2 个或行数超过两行时出现，否则条高随行；窗口矮时默认收成一行）、`EditItemsBar`（正在编辑的远程文件）、`NoticeBar` |
| `LocalFilePanelView.swift` | 本地面板：头（这台 Mac + 等宽的「用户@本机名」+ 上传 +「在访达中显示」图标按钮）、路径（⌂ 按钮只在路径不在家目录下时出现）、文件列表、底栏 |
| `RemoteFilePanelView.swift` | 远程面板：头（主机方块 + 名称——点开是切换主机的菜单，传输中只有一行「等待传输完成」 + 地址 + 下载，**全页唯一的 `.prominent`**）、列目录、重命名、权限、新建文件夹、删除、编辑、上传/下载；两个面板共用的部件也在这里：`FilePanelHeader`（`FilePanelTitleMenu`：名称上的菜单）、`FilePathBar`（面包屑；点空白处或 ⌘L 变成可输入的路径框，回车打开、Esc 放弃）、`FileListHeader`、`FileRowView`、`FilePanelFooter`（N 项 · 大小 · 已选）、`FileDropHighlight`、`FileColumnVisibility`（窄了先丢权限列，再把日期缩短，再丢日期） |

## For AI Agents

### Working In This Directory
- 视图只调 `SFTPViewModel` 的方法；它经 `SFTPService` 在该主机的共享 SSH 主连接上跑自研 SFTP v3 客户端，不要在视图里碰 `SFTPClient`。
- 远程面板的命令一律走 `SFTPViewModel` 的入口（`openRemote`、`beginNewFolder` / `beginRename` / `beginPermissions` / `beginDelete`、`downloadToLocalFolder`、`uploadToRemoteFolder`、`downloadDragged`），不要在视图里直接设弹窗状态或调 `upload(_:into:)` / `download(_:into:)`：入口会在「显示的行不是路径栏那个目录的内容」（正在加载另一个目录、或显示着错误）时拒绝，并只对当前可见的行生效。按钮用 `remoteListingIsCurrent` / `remotePanelShows(_:)` 置灰。切目录时不清空旧行（不闪空状态）。
- 选中项只含可见行：用 `selectedRemote` / `selectedLocal`，不要自己按 id 去过滤全量列表。
- 两个面板互为拖放目标（本地→远程 = 上传，远程→本地 = 下载），也接受从 Finder 拖入。从远程面板拖出的是 `remoteDragPayload(for:)` 给的随机标记，不是路径：只有同一个窗口的本地面板认得它。
- 删除、覆盖等破坏性操作必须先确认；下载先写 `.part` 再改名，不要改成直接覆盖。
- 文件名、路径、错误信息来自数据，用 `Text(verbatim:)`。
- 文件字形是一套中性的 SF Symbols（`SFTPItem.rowSymbol`），只有文件夹带强调色——文件列表不按类型上色。
- 路径拆成面包屑按**字节**拆（`SFTPBreadcrumbs`）：按字符拆的话，“/” 后面跟组合字符会把那个 “/” 吞掉。
- 纯逻辑放在 `SFTPViewModel.swift` 里并有单测：`TransferSummary`、`SFTPBreadcrumbs`、`SFTPListingSummary`、`SFTPItem.modifiedText`。
- 列表选中态是系统 `List(selection:)` 的：列表有键盘焦点时是强调色，没有时是灰色。
- DEBUG 启动参数（截图用）：`-debugSFTPHost <label>`（连接已保存的主机）`-debugSFTPPath <远程目录>` `-debugSFTPLocalPath <本地目录>` `-debugSFTPSelect <文件名>` `-debugSFTPTransfers YES`（示例传输，不真传）`-debugSFTPState connecting|failed`（状态卡片）。

## Dependencies

### Internal
- `ViewModels/SFTPViewModel.swift`
- `Services/SFTPService.swift`、`Services/SFTPClient.swift`
- `Theme/` — `DSHostAvatar`、`DSRowButton`、`DSMeter`、`DSRouteDiagram`、`.dsCard()`、`.dsFloatingBar()`、`.dsButtonStyle()`
- `Views/Terminal/TerminalTabView.swift` — `SessionStateCard`

<!-- MANUAL: -->
