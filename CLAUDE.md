# Termi — macOS SSH Client

> 项目知识库，为 Claude Code 和其他 AI Agent 提供上下文。同步至 Obsidian vault。
> **最后更新**: 2026-10-19

---

## 项目概览

**Termi** 是一款原生 macOS SSH 客户端，使用 **SwiftUI + Swift 6** 构建，面向开发者和运维人员。目标是成为可上架 App Store 的商业产品。

| 属性        | 值                               |
| --------- | ------------------------------- |
| 平台        | macOS (latest)                  |
| 语言        | Swift 6                         |
| UI 框架     | SwiftUI                         |
| 数据库       | GRDB (SQLite, WAL 模式)           |
| SSH       | 系统 OpenSSH：每主机一条 ControlMaster 主连接 + askpass 桥；自研 SFTP v3 客户端 |
| 终端        | SwiftTerm（固定 1.18.x）          |
| 最低系统      | macOS 15+                       |
| Bundle ID | `dev.termi.Termi`              |

---

## 构建与运行(声明完成前必须真跑)

> 工程用 **XcodeGen** 管理:`project.yml` 是源头,`project.pbxproj` 由它生成(已提交)。

```bash
make build          # = check-xcode + xcodebuild(Scheme: Termi)
make dmg            # 发布 DMG
make clean
xcodebuild test -project Termi.xcodeproj -scheme Termi   # 测试
```

- **新增/移动 .swift 文件**:改完跑 `xcodegen` 重新生成工程,**不要手改 `project.pbxproj`**。
- **测试是隔离的**:`xcodebuild test` 不会打开真实配置(见「关键设计模式 · 配置目录只有一个来源」)。手动验收用隔离配置目录:`open -n --env TERMI_PROFILE_DIR=<绝对路径> <Termi.app>`,界面语言用 `--args -AppleLanguages '(zh-Hans)'` 指定。
- 别只 `swift build`;`xcodebuild`(或 `make build`)过 + App 能启动才算完成。

---

## 技术架构

```
Termi/
├── App/                    # 应用入口
│   ├── main.swift          # 入口：askpass 客户端 → 配置目录检查（拒绝则退出码 78）→ 测试宿主（裸 NSApplication）或启动 App
│   ├── AppProfile.swift    # 这次运行把数据和偏好放在哪：standard / isolated（TERMI_PROFILE_DIR）/ tests；所有路径与偏好的唯一来源
│   ├── DebugSeed.swift     # DEBUG：`-debugSeedHosts <json>` 把测试主机灌进隔离配置目录（标准配置下拒绝）
│   ├── TermiApp.swift     # SwiftUI App + 菜单命令 (标签/分屏/广播/查找/片段/SFTP/字体)
│   ├── AppDelegate.swift   # 网络监控、退出时关闭 SSH 主连接、窗口关闭确认
│   ├── DebugActiveAppearance.swift # DEBUG：`-debugActive YES` 让窗口按活动状态绘制（锁屏下截图用）
│   └── FocusedAppViewModel.swift
├── Models/                 # 数据模型 (GRDB Record)
│   ├── Host.swift          # SSH 主机 (跳板机、代理转发、启动片段、主机主题、最近连接、识别到的系统 os_*)
│   ├── HostSystem.swift    # 发行版 id 归一化、/etc/os-release 与 uname / ver 的解析
│   ├── Group.swift         # 主机分组 (默认用户名/身份/跳板机)
│   ├── SSHKey.swift / Identity.swift / Snippet.swift / Tag.swift / KnownHost.swift
│   ├── ConnectionLog.swift / PortForward.swift / AppSettings.swift
│   ├── SFTPItem.swift      # SFTP 文件项 (本地/远程)
│   ├── SnippetTemplate.swift     # 片段 {{变量}} 解析与渲染
│   ├── TerminalPreferences.swift # 终端偏好 (字体/光标/响铃/回滚/Option-Meta/自动重连…)
│   └── TerminalTheme.swift # 终端配色主题 (12 内置主题)
├── Database/
│   ├── DatabaseManager.swift  # Actor-based DB 管理 (单例)
│   └── Migrations.swift       # 数据库迁移 (最新 v8_host_system)
├── Repositories/           # 数据访问层 (Host/Group/SSHKey/KnownHost/Snippet/ConnectionLog/PortForward/Identity/Tag)
├── Services/               # 业务逻辑层
│   ├── SSH/                      # SSH 引擎 (见 Services/SSH/AGENTS.md)
│   │   ├── SSHService.swift            # 门面：从数据库组装连接、connect → Lease、run(_:on:)
│   │   ├── SSHConnectionManager.swift  # 主连接复用 (single-flight + 租约 + 空闲关闭)
│   │   ├── SSHMasterConnection.swift   # ssh -M 主连接、提示应答、-O forward/cancel/exit
│   │   ├── SSHConnectionSpec.swift     # 连接描述/跳板链/凭据/转发/提示/错误
│   │   ├── SSHConfigRenderer.swift     # 每连接私有 ssh_config + known_hosts
│   │   ├── SSHAskpass.swift            # askpass 客户端/服务端 (Unix socket)
│   │   └── SSHRuntime.swift            # 运行时目录、私有 ssh-agent、进程终止、残留清理
│   ├── SFTPClient.swift          # SFTP v3 协议客户端
│   ├── SFTPService.swift         # SFTPSession (共享主连接上的文件操作/传输)
│   ├── SSHConfigParser.swift     # ~/.ssh/config 解析 (导入)
│   ├── HostSystemProbe.swift     # 连接后读一次发行版（一条只读命令，每主机每次运行至多一次）
│   ├── SessionTranscripts.swift  # 会话转录文件（SessionLogs/<历史 id>.log）：只删交给它的 id，不做清扫
│   ├── PortForwardManager.swift  # 端口转发启动/停止/状态
│   ├── NetworkMonitor.swift      # 网络恢复/唤醒 → 自动重连
│   ├── ProcessRunner.swift       # 通用异步进程执行器
│   ├── CryptoService.swift       # AES-256-GCM 加密 + HKDF 密钥派生
│   ├── SecureStoreService.swift  # 独立加密保险库，不依赖 macOS Keychain
│   ├── SSHKeyGenerator.swift     # SSH 密钥生成/导入
│   ├── BatchCommandService.swift / MonitorService.swift / DockerService.swift
│   ├── NotificationService.swift # 系统通知
│   ├── SyncService.swift         # 本地加密同步（无 iCloud）
│   └── ImportExportService.swift # CSV / ~/.ssh/config 导入导出
├── ViewModels/             # MVVM ViewModel (@Observable)
│   ├── AppViewModel.swift         # 每窗口状态：导航、标签、窗格布局树、会话表、广播；持有 sftp / batchCommand / monitor / docker 的 ViewModel（切页面不丢状态）
│   ├── TerminalSession.swift      # 单个窗格的会话：SwiftTerm 视图、SSH 租约、状态机、自动重连
│   ├── HostsViewModel.swift       # 主机/分组/标记/排序/HostDraft 保存/QuickConnectParser
│   ├── SFTPViewModel.swift        # 双面板、传输队列、远程编辑
│   ├── SettingsViewModel.swift / SecurityViewModel.swift / KeysViewModel.swift
│   └── Batch/Monitor/Docker/Snippets/PortForward/ConnectionLogs/Identities/KnownHosts ViewModels
├── Views/
│   ├── MainWindow/               # MainWindowView (NavigationSplitView 外壳、统一工具栏、片段检查器) + WindowRootView (锁屏、sheet、DEBUG 启动参数)
│   ├── Sidebar/SidebarView.swift # 系统侧边栏：只列页面（连接 / 保险库 / 工具 三组 + 底部设置、锁定）；会话不在这里，只在工具栏标签里
│   ├── Terminal/                 # TerminalTabView (等分可拖动分屏、状态卡片) / BiuTerminalView (SwiftTerm 子类) / SnippetPanelView (检查器)
│   ├── Hosts/                    # 主机卡片网格（默认）/ 列表，详情 (HostDetailView) 按需在右侧面板展开；搜索即连接、标记、排序 / 主机表单 / 分组表单 / 身份 / 快速连接
│   ├── SFTP/                     # 双面板 + 拖放 + 传输队列 + 远程编辑栏
│   ├── Keys/                     # 密钥库 (安装公钥到主机) / 已知主机
│   ├── DevOps/                   # 批量命令/监控/Docker/端口转发/片段/历史
│   ├── Security/LockScreenView.swift
│   ├── Settings/SettingsView.swift
│   └── Shared/                   # TabBarView (工具栏里的会话标签；不在终端页时收成只有图标块的 tilesOnly) / AuthPromptPresenter / CommandPalette / 快捷键 / ASCIISecureField / DevOpsHostRowView
└── Theme/                        # 共享设计层 (见 Theme/AGENTS.md；签名以代码为准)
    ├── DesignSystem.swift        # enum DS：间距 / 圆角 / 行高 / 字号 / 状态色 / 强调色
    ├── Glass.swift               # 唯一出现 Liquid Glass API 的文件（双重判断 + 材质回退）：dsGlass / dsButtonStyle / DSGlassIconButton / DSGlassIconMenu / dsFloatingBar / dsFloatingPanel / DSFilterChip
    ├── Tiles.swift               # DSIconTile / DSCategoryTile / DSHostAvatar（发行版图标块）/ DSOperatingSystem / DSSidebarLabel
    ├── DataCards.swift           # DSStatCard / DSStatGrid / DSGaugeCard / DSDividedRow / DSValueCell / DSKeyValueRow
    ├── Charts.swift              # DSMeter / DSDayStrip / DSSparkline / DSArcGauge / DSActivityChart / DSSegmentBar / DSLogStats
    ├── Components.swift          # 卡片与分组、DSDetailHeader、DSMasterDetail、DSRouteDiagram、DSRandomart、DSCodeBlock、DSEmptyState、DSStatusPill、DSChip …
    └── DesignGallery.swift       # DEBUG：`-debugSheet gallery -debugGalleryPage 1…5` 展示全部组件
```

### 关键设计模式

- **MVVM**: `@Observable` ViewModel + SwiftUI Views
- **Actor 隔离**: `DatabaseManager` 使用 `actor` 保证线程安全
- **Repository Pattern**: 数据访问通过 Repository 层隔离
- **环境注入**: 通过 `.environment()` 传递 ViewModel
- **界面 = Apple Liquid Glass + 克制的颜色**（用户 2026-10-05 定稿，设计稿在 Claude Design 画布）：玻璃只属于控件与导航层（侧边栏、工具栏项、按钮、浮动栏、sheet / popover），内容层不用玻璃、不叠玻璃；页面不直接调用玻璃 API，只用 `Theme/Glass.swift` 的封装。颜色角色：中性色承载界面；一个强调色（`Color.accentColor`）给主操作、选中和数据；绿 / 橙 / 红只表示状态并配文字；页面与分类不做颜色编码；唯一的自由色是主机图标块上的发行版色。并排的数据放固定列（数字右对齐、等宽数字）、之间加分隔线、不换行。规则见 `Views/AGENTS.md`、`Theme/AGENTS.md`
- **主机图标 = 发行版**: 已保存主机连接成功后，`HostSystemProbe` 经已建立的主连接读一次 `/etc/os-release` + `uname -sm`（Windows 回退 `ver`），把系统 id / 名称 / 架构存到 `hosts.os_*`（只更新这几列，且主机地址没变才写），`DSHostAvatar` 显示该发行版的图形与颜色（Simple Icons，CC0，见 `docs/THIRD_PARTY_NOTICES.md`）；没有自家图形的发行版（麒麟、openEuler 等）用 Linux 图标；可用 `detectHostSystem` 关闭
- **同一信息只出现一处**（用户 2026-10-05 要求，裁决清单约 60 条）：会话只在工具栏标签里（侧边栏不再列会话）；主机名只在行里和记录里各出现一次，不在标题栏、状态栏、检查器里再写；一个区域里的计数只写一次；侧边栏徽标只表示「正在发生」（运行中的转发、进行中的传输），不重复列表总数；同一条曲线只画一次；路线图只在有跳板机时画（`DSRouteDiagram.addsSomething(hopCount:)`）；说明文字放到动作发生的那一刻（按钮旁、确认框里），不常驻页面。加新模块前先问：这条信息屏幕上已经有了吗
- **交互形态以 Termius 为基准**（用户 2026-10-07 在 Xcode 里真用之后的要求：「参考一下 termius……不要闭门造车」）：做页面的信息架构和交互之前先看 Termius 同一页怎么做；视觉皮肤仍是 Liquid Glass。**主机页 = 卡片网格 + 按需详情**：默认整页是主机卡片（1200 宽三列），没有常驻的详情，也没有卡片自动处于选中；卡片悬停或选中时右侧出现一个按钮（ⓘ），点它、右键「显示详情」或「显示」菜单的 ⌘I 才在右侧 380pt 面板里展开该主机的记录，面板跟随选中项、可关闭、不跨启动保存；单击选中，双击 / 回车连接；列表是工具栏里的另一种排布，同样按需展开。别的页面的「在主机中显示」走 `HostsViewModel.showRecord(of:)`（选中 + 打开面板 + 滚到可见）。没有的东西不画占位：从未连接过的主机，卡片上不写「从未」，记录里不画一排「—」和空图表
- **配置目录只有一个来源**（`App/AppProfile.swift`）：数据库、保险库密钥、会话转录、同步目录、建议的备份目录和持久偏好都从 `AppProfile.current` / `AppProfile.defaults` 取，别处不得再拼 `Application Support/Termi` 或直接用 `UserDefaults.standard`（`@AppStorage` 一律带 `store: AppProfile.defaults`）。三种运行：**standard**（正常使用，位置与以前逐字节相同）；**isolated**（设了 `TERMI_PROFILE_DIR=<绝对路径>`，全部数据和 `Preferences.plist` 都在该目录内；路径无效、或按文件身份解析后就是真实目录 / 其子目录时拒绝启动，绝不回落到真实配置）；**tests**（托管单测：`$TMPDIR/Termi-Tests/<pid>`，宿主只是一个裸 NSApplication，不建窗口、不开库、不跑任何启动任务）。`-debug…` 启动参数从 `AppProfile.arguments`（参数域快照）读。DEBUG 下 `Termi -debugPrintProfile YES` 打印本次运行会用哪套位置后退出，不碰任何文件
- **窗口**: `NavigationSplitView` 双栏；终端视图常驻（opacity 隐藏，会话不断），页面只在显示时构建；窗口最小 900×600 且不小于当前页面所需（根视图用 ZStack 垫一个最小尺寸，不能直接 `.frame(minWidth:)`，否则宽页面会被居中裁切）
- **锁定**: 锁定期间页面不构建（它的 sheet / alert 随之收起），终端保持挂载但隐藏并移出按键循环，窗口级 sheet 标志清空，SSH 认证提示收起且不再弹出，菜单命令不路由到任何窗口；启动时在锁定状态确定前窗口被遮盖并禁用（`SecurityViewModel.hidesContent`）
- **数据安全约定**: 远程编辑的本地副本按实例放在 `$TMPDIR/Termi-Edit/<pid>`，未上传的修改只进废纸篓不删除；下载先写 `.part`、旧文件进废纸篓再替换；备份是完整单文件副本（WAL 内容在内），恢复 / 加密导入先校验、再替换，并把原库保留为同目录的 `termi.before-*.db`；口令经 askpass 传给 `ssh-keygen`，不进 argv
- **SFTP 名字与路径**: 名字和路径一律按 UTF-8 字节判断与比较（`SFTPClient.isValidEntryName` / `join` / `parent`，`SFTPPathKey` 作为条目身份）——`String` 按字素簇和规范等价比较，`"../" + 组合字符` 能骗过字符级检查，NFC / NFD 同形名会被当成同一项；不是合法 UTF-8 的名字只显示、不可操作；远程编辑保存到开始编辑时记下的精确路径，不从本地文件名反推；重命名先 LSTAT，不静默覆盖；目录遍历有条目数与深度上限；FIFO / 设备不下载；本机折叠成同名的条目由文件系统（inode）裁定。操作被拒绝或失败用提示框（`remoteActionError`），`remoteError` 只表示当前目录列不出来
- **退出与关闭确认**: 关窗格 / 标签 / 窗口 / 退出应用问的是同一个问题、受同一个设置控制（`suppressSSHCloseConfirmation`）；SFTP 会丢东西时总是问
- **多窗口**: 每个窗口通过 `WindowRootView` 创建独立 `AppViewModel`，菜单命令通过 `@FocusedValue` 路由到当前激活窗口
- **每主机一条 SSH 连接**: `SSHService` → `SSHConnectionManager` 复用 OpenSSH ControlMaster 主连接；终端/分屏/SFTP/端口转发/远程命令都是它的 mux 客户端，持有 `Lease` 期间保持连接
- **askpass 桥**: App 可执行文件兼作 `SSH_ASKPASS`，密码/口令/2FA/主机指纹提示经 Unix socket 回到 `AuthPromptPresenter` 弹窗；秘密不进命令行和环境变量
- **会话归模型**: `TerminalSession` 由 `AppViewModel.sessions` 持有（不属于视图），视图只挂载其 NSView；标签内窗格用 `PaneLayout` 树描述

---

## 开发阶段 & 路线图

### 已完成阶段 (v1)

| Phase | 内容 | 状态 |
|-------|------|------|
| Phase 1 | 项目骨架 + 本地终端 | ✅ 完成 |
| Phase 2 | SSH 连接 + 主机管理 | ✅ 完成 |
| Phase 3 | 安全层 + SSH 密钥管理 | ✅ 完成 |
| Phase 4 | SFTP 双面板文件传输 | ✅ 完成 |
| Phase 5 | DevOps 工具 (批量命令/监控/Docker/片段/日志) | ✅ 完成 |
| Phase 6 | 同步/导入导出/备份恢复/设置 | ✅ 完成 |
| Phase 7 | 打磨 (身份管理/命令面板/快捷键) | ✅ 完成 |
| UI 优化 | App Store 风格侧边栏 + 主机卡片网格 | ✅ 完成 |

### 当前工作 (进行中)

- [x] 商用质量优化 — autopilot 全流程完成 (2026-03-02)
- [x] KeychainService → SecureStoreService 重构（独立加密，不依赖 macOS Keychain）
- [x] 去除 iCloud 同步（自分发，不上 App Store）
- [x] Duplicate Tab：右键 Tab 复制独立 SSH Session (2026-03-03)
- [x] Session Log Viewer：Connection Logs 查看终端输出 transcript (2026-03-03)
- [x] 单窗口 restore、⌘W/⌘1-9/⌘[⌘] 快捷键、HostListView 双 bar 合并 (2026-03-03)
- [x] V2 Phase 1: SSH 加固 — PTY 密码注入、ServerAlive、输入验证、⌘W 确认、host key 检测 (2026-03-03)
- [x] V2 Phase 2: 端口转发 UI + X11 转发 — HostForm Advanced section, 全局 Port Forwards 页面, SSH 参数注入 (2026-03-03)
- [x] V2 Phase 3: 终端主题系统 — 12 内置主题 (Dracula/Nord/Monokai/Solarized/Tokyo Night 等), ANSI 16 色调色板, 实时切换 (2026-03-03)
- [x] V2 Phase 4: 多窗口支持 — Per-window AppViewModel, FocusedValue 菜单路由, ⌘N 新窗口, WindowRegistrar (2026-03-03)

### 未来计划 (v2)

- [x] V2 Phase 5: 自分发打包 — Makefile + build-release.sh + create-dmg.sh + Sparkle keys + Homebrew Cask (2026-03-04)
- [x] V2 Phase 6: 通知中心 — NotificationService + SSH/SFTP/Batch 通知 + Settings Notifications tab (2026-03-04)
- [x] GitHub Actions CI/CD — CI (build+test on push/PR) + Release (DMG + GitHub Releases on tag) (2026-03-05)

### V3: Termius 对齐（SSH 为主）(2026-09-26)

- [x] SSH 引擎重写：ControlMaster 主连接复用、askpass 桥（密码/口令/2FA/主机指纹）、保存到保险库、跳板机链 (ProxyJump, 每跳独立凭据)、代理转发（App 私有 agent）、~/.ssh/config Include 开关
- [x] SFTP v3 协议客户端：共享主连接、拖放、传输队列（进度/速度/取消）、递归上传下载删除、chmod/重命名、远程编辑自动上传
- [x] 终端：分屏窗格 (⌘D/⇧⌘D)、广播输入 (⇧⌘B)、查找 (⌘F)、片段面板 ({{变量}})、启动片段、自动重连 (退避 + 网络恢复/唤醒)、字体/光标/响铃/回滚/Option-Meta/选中即拷贝
- [x] 主机：分组默认值（用户名/身份/跳板机）、标记过滤、按最近使用排序、搜索即连接 (user@host)、导入 ~/.ssh/config、主机级主题
- [x] 端口转发独立启停 + 状态；密钥库安装公钥到主机 (authorized_keys)；身份支持密码与系统 SSH agent
- [x] SwiftTerm 固定 1.18.x、移除未使用的 swift-nio-ssh、CI 覆盖 `claude/**` 分支并以 Release 配置构建

---

## Commit 历史

| Hash | 信息 | 日期 |
|------|------|------|
| `3f44d1f` | fix: the twelve findings of the 2026-10-11 review — atomic SFTP replacement, generation-guarded vault writes, and saved passwords bound to the login they were typed for | 2026-10-19 |
| `02c05b0` | wip: Codex fixes for F1–F12 exactly as left on 2026-10-11 (snapshot, not verified) | 2026-10-18 |
| `cfce625` | fix: after restoring an older backup a new history record could take the number of another session's transcript | 2026-10-10 |
| `1b57b21` | chore: the string helper lives in the repository (scripts/add-strings.py) | 2026-10-10 |
| `ebbf789` | ui: the Hosts page is a grid of cards; a host's record opens in a side panel only when asked for | 2026-10-07 |
| `2e299d6` | chore: the string catalog in the order and with the states Xcode writes | 2026-10-07 |
| `a93715a` | chore: the string catalog matches the code — 265 unused entries removed, 5 missing translations added, checked in CI | 2026-10-05 |
| `b01687a` | docs: README, user guide and changelog describe the app as it is | 2026-10-05 |
| `f69b055` | feat: the acceptance environment lives in the repository; test hosts are seeded into an isolated profile | 2026-10-05 |
| `778cd26` | fix: Settings said a backup existed after its file was deleted; fixed path texts did not match where files are | 2026-10-05 |
| `025977a` | fix: clearing history left the recorded session output on disk; a history search looked at 200 records only; imported history showed another session's output | 2026-10-05 |
| `597a32e` | fix: running the tests launched the real app on the owner's real data; an isolated run shared the real preferences | 2026-10-05 |
| `823fb8e` | chore: remove three files nothing referenced (ThemeManager, LiquidButtonStyles, PageHeaderView); ignore .omc/ | 2026-10-05 |
| `5259966` | fix: history counted only the 200 listed records; a vault entry that cannot be decrypted read as a raw CryptoKit error; cancelling a password prompt ended in a red failure card | 2026-10-05 |
| `e9f0cee` | docs: CLAUDE.md and Views/AGENTS.md — one place for each fact, the sidebar without sessions, click acceptance status | 2026-10-05 |
| `d353b64` | ui: one place for each fact — the sidebar's session list and the repeated modules are gone | 2026-10-05 |
| `4425f36` | fix: "Run in terminal" on a snippet with variables opened the inspector on its Info tab; a snippet row could not be chosen through accessibility | 2026-10-05 |
| `49ee001` | fix: any text was imported as an SSH key; ↑↓ did nothing in the Docker table; a cancelled password prompt came back every 5 seconds; a known host's port read "2,223" | 2026-10-05 |
| `ab8bd09` | fix: find in a narrow pane pushed the terminal under its neighbour; a path typed after ⌘L went to the file list; a mistyped SFTP path replaced the listing; an unreadable saved password blocked the host | 2026-10-05 |
| `e5ad82a` | fix: right-click on a session tab opened the toolbar's "Icon and Text" menu; a filter left a hidden host selected | 2026-10-05 |
| `c753d39` | docs: CLAUDE.md — Liquid Glass design rules, shared layer, distribution icons, toolchains | 2026-10-05 |
| `64289e3` | ui: every screen checked against its mockup once more | 2026-10-05 |
| `b63ec40` | fix: ⌫ no longer asks to delete a host nobody chose; one Return opens one session; batch does not run snippet templates | 2026-10-05 |
| `3e136db` | ui: headers keep title and actions on one line, routes line up, failed days show in history, a snippet never runs with an empty variable | 2026-10-05 |
| `8134f04` | fix: Swift 6.0 could not type-check arithmetic inside #expect comparisons | 2026-10-05 |
| `e0486c4` | ui: every page rebuilt on the Liquid Glass design | 2026-10-05 |
| `2ea2ce8` | chore: debug launch argument that draws the window as active for screenshots | 2026-10-05 |
| `694cf1d` | ui: shared layer for the Liquid Glass redesign; a host's tile shows its distribution | 2026-10-05 |
| `e384054` | ci: build and release with Xcode 26; keep an Xcode 16.2 compatibility job | 2026-10-05 |
| `448fcf2` | ui: seventh design review pass — a password silently dropped, and 13 smaller states | 2026-10-04 |
| `2901545` | ui: sixth design review pass — error states that said "empty", and round five's siblings | 2026-10-04 |
| `1b09dfc` | ui: fifth design review pass — 13 state and interaction fixes | 2026-10-04 |
| `511d861` | ui: a refused SFTP action is said in an alert, the file list stays | 2026-10-04 |
| `0053230` | fix: SFTP twins, case-only renames and links are judged by the file system, not by guesses | 2026-10-04 |
| `14532db` | fix: the SFTP panels never act on something the user does not see | 2026-10-04 |
| `b467e89` | fix: SFTP transfers survive hostile or odd servers and never replace silently | 2026-10-04 |
| `00f34c5` | fix: SFTP names, identity and edit paths are handled by their exact bytes | 2026-10-04 |
| `d6afe1b` | ui: prompts, find bar and menus say one thing, in the app's language | 2026-10-04 |
| `705c0e1` | fix: locking the app with a focused terminal hung it | 2026-10-04 |
| `af69070` | fix: ⌘Q disconnected every SSH session without asking | 2026-10-04 |
| `f196d94` | fix: after a font change the last terminal columns sat under the scroller | 2026-10-04 |
| `5345021` | fix: closing a pane of a nested split blanked its sibling and moved the keyboard away | 2026-10-04 |
| `2f5e252` | fix: Swift 6.0.3 crashed compiling the tests — enum patterns inside #expect closures | 2026-10-04 |
| `ba158e0` | fix: reject SFTP entry names that are not file names | 2026-10-04 |
| `e521119` | ui: fourth design review pass — truthful history, consistent close confirmation | 2026-10-04 |
| `d0acdf6` | ui: third design review pass — one regression and four state fixes | 2026-10-04 |
| `8f1797a` | ui: second design review pass — 10 refinements | 2026-10-04 |
| `e60ca55` | fix: Swift 6.0 rejects a MainActor method reference passed to allSatisfy | 2026-10-04 |
| `753059e` | docs: CLAUDE.md — lock and data-safety conventions, review and design pass status | 2026-10-04 |
| `85e95fa` | ui: design review pass — 22 refinements across pages, sheets and states | 2026-10-04 |
| `6f6bacd` | fix: nothing of a locked window stays visible or reachable | 2026-10-04 |
| `e71a6d2` | fix: page state that lives with the window stays consistent | 2026-10-04 |
| `7da664b` | fix: remote edits and transfers are never dropped silently | 2026-10-04 |
| `3a36b55` | fix: backup, restore, encrypted import and master password could lose or expose data | 2026-10-04 |
| `a6e010a` | fix: a remote shell exiting with 255 is not a lost connection; back-off really backs off | 2026-10-04 |
| `3aaddd2` | docs: CLAUDE.md — HIG design system, window shell rules, V3 acceptance status | 2026-10-04 |
| `7339f3f` | ui: rebuild the interface on standard macOS (HIG) components | 2026-10-04 |
| `8cf3b7e` | fix: untranslated error messages, stale tool results, smart quotes in commands | 2026-10-04 |
| `c676fc2` | fix: master password re-encrypts keys and identities; vault while locked | 2026-10-04 |
| `bdbbcc0` | fix: port forwards, search-to-connect and key import | 2026-10-04 |
| `7f1d8db` | fix: SFTP data-safety and transfer defects | 2026-10-04 |
| `602bc24` | fix: terminal session lifecycle — reconnect, exit codes, leftover processes | 2026-10-04 |
| `b735b18` | fix: SSH engine defects found by the V3 audit on macOS / OpenSSH 10 | 2026-10-04 |
| `b8846ec` | fix: opening SFTP froze the app behind a Downloads-folder permission prompt | 2026-10-03 |
| `c1615c8` | fix: ⌘W closed the whole window and leaked its SSH sessions | 2026-10-03 |
| `fc4365a` | fix: repair key types stored as "unknown" (migration v7_key_types) | 2026-10-03 |
| `0ebfdaa` | chore: drop unnecessary awaits in CryptoServiceTests | 2026-10-03 |
| `71c0a57` | fix: import key sheet clipped the file row and showed English segment labels | 2026-10-03 |
| `3cc0795` | fix: imported SSH keys were all labelled "unknown" | 2026-10-03 |
| `3977686` | fix: split panes, pane focus ring and broadcast badge never re-rendered | 2026-10-03 |
| `f96723b` | docs: add 2f88cba to the CLAUDE.md commit history | 2026-10-03 |
| `f0fbb0a` | docs: CLAUDE.md — CI result, Swift 6 callback isolation rule, commit history | 2026-09-26 |
| `98020e8` | fix: UserNotifications completion handlers must not inherit MainActor isolation | 2026-09-26 |
| `cd27fe2` | fix: NWPathMonitor handler must not inherit MainActor isolation | 2026-09-26 |
| `9b0464d` | feat: localized notifications and CI log artifacts | 2026-09-26 |
| `c604cc0` | fix: call MainActor color converter from a closure instead of a method reference [skip ci] | 2026-09-26 |
| `cbd1c40` | chore: CI for claude/** with Release build, zh-Hans strings, docs, test scheme [skip ci] | 2026-09-26 |
| `9ac2c87` | chore: regenerate Xcode project — SwiftTerm 1.18.x, drop swift-nio-ssh, 2.1.0 | 2026-09-26 |
| `b36c625` | feat: SFTP, port forwarding, keychain, identities and settings UI on the new engine | 2026-09-26 |
| `c8da0f0` | feat: Termius-style terminal, hosts and data model on the shared SSH engine | 2026-09-26 |
| `70551ac` | feat: SFTP v3 protocol client over the shared SSH master | 2026-09-26 |
| `899d073` | feat: ControlMaster-based SSH engine with askpass bridge | 2026-09-26 |
| `2f88cba` | chore: bump CLAUDE.md commit counter | 2026-06-22 |
| `ad6d170` | chore: update localizations and CLAUDE.md before machine reinstall | 2026-06-22 |
| `8cd2054` | fix: change CryptoService from actor to Sendable class | 2026-03-07 |
| `a6eaffb` | fix: use sending return type for deriveKey to fix actor isolation | 2026-03-07 |
| `88caf8a` | fix: add @preconcurrency import CryptoKit for Release archive | 2026-03-07 |
| `04edf1c` | chore: bump MARKETING_VERSION to 2.0.0 | 2026-03-07 |
| `df79f3d` | feat: manual SSH key import + Chinese/English localization | 2026-03-07 |
| `c7be828` | ci: add workflow_dispatch trigger to release workflow | 2026-03-06 |
| `3c03d95` | docs: add README and user guide | 2026-03-06 |
| `f9d27f3` | ci: add GitHub Actions CI + Release workflows | 2026-03-05 |
| `2d311db` | feat: V2 Phase 5+6 — DMG distribution + notification center | 2026-03-05 |
| `0401e7b` | feat: V2 Phase 4 — Multi-window support with per-window state isolation | 2026-03-03 |
| `beee5ec` | feat: V2 Phase 3 — Terminal Theme System with 12 built-in color schemes | 2026-03-03 |
| `fead455` | feat: V2 Phase 2 — Port Forwarding UI + X11 Forwarding | 2026-03-03 |
| `04ae8dc` | feat: V2 Phase 1 — SSH hardening + input validation + ⌘W confirmation | 2026-03-03 |
| `3728f21` | refactor: remove dead SidebarItem.hosts + sync docs | 2026-03-03 |
| `03763bf` | fix: single window restore + keyboard shortcuts + UI header unification | 2026-03-03 |
| `71db2b0` | feat: duplicate tab + session log viewer | 2026-03-03 |
| `cd1a356` | docs: update CLAUDE.md — sync commit history after global review fix | 2026-03-03 |
| `5567153` | fix: global code review — 129 issues resolved across 39 files | 2026-03-03 |
| `0e888e9` | ui: Termius-style layout — full-width host grid + top session tab bar | 2026-03-03 |
| `45055dd` | feat: unified Connections view — Termius-style host panel + terminal in one page | 2026-03-03 |
| `71882ff` | fix: preserve SSH sessions across sidebar navigation + faster connected state | 2026-03-02 |
| `b1012f3` | fix: UI polish — remove duplicate section header, deprecated APIs, animation | 2026-03-02 |
| `b563509` | fix: code-reviewer LOW — foregroundStyle + docker ps flag cleanup | 2026-03-02 |
| `122c0b2` | feat: commercial-quality autopilot — perf, security, Liquid Glass, AGENTS.md | 2026-03-02 |
| `3e16855` | UI: Unify toolbar layout in HostListView to match SSH Keys view style | 2026-03-01 |
| `9e3d162` | UI: Add comprehensive Liquid Glass effects and global Dark/Light theme switching | 2026-03-01 |
| `0e84e4b` | chore: remove redundant 1024px icon + sync CLAUDE.md commit history | 2026-03-01 |
| `b860c37` | chore: update .gitignore — exclude firebase logs and .claude/ | 2026-03-01 |
| `f02c34d` | fix: QA round 2 — crash safety, pipe deadlock, 73 unit tests | 2026-03-01 |
| `bc5b143` | fix: GRDB insert id backfill + SSH connection state machine | 2026-03-01 |
| `2c22a3b` | Inspect project and optimize crypto | 2026-02-28 |
| `5a61ca7` | ui: comprehensive HIG audit — macOS 26 Liquid Glass, system APIs, ThemeColors | 2026-02-28 |
| `9d31d44` | Audit project security and build | 2026-02-27 |
| `2430853` | ui: App Store sidebar + host card grid layout | 2026-02-27 |
| `bc42062` | fix: SSH terminal input, expanded sidebar, host card styling | 2026-02-27 |
| `35c783d` | feat: Phase 7 — polish (identities, command palette, keyboard shortcuts) | 2026-02-27 |
| `65bd1d8` | feat: Phase 6 — sync, import/export, backup/restore, settings | 2026-02-27 |
| `3866b97` | feat: Phase 5 — DevOps tools (batch command, monitoring, Docker, snippets, logs) | 2026-02-27 |
| `115f3bb` | feat: Phase 4 — SFTP file transfer with dual-pane browser | 2026-02-27 |
| `d126408` | feat: Phase 3 — security layer + SSH key management | 2026-02-27 |
| `76d890e` | feat: Phase 2 — SSH connection + host management | 2026-02-27 |
| `ff87ad6` | feat: Phase 1 — project skeleton with local terminal | 2026-02-27 |
### V3 真机验收与界面重做 (2026-10-03 ~ 10-04)

- [x] 在本机（Xcode 27.0 / macOS 27 / OpenSSH 10.3）对 Docker 里的 sshd 逐项验收 A–G，修复发现的缺陷（⌘W 关整个窗口、分屏不刷新、导入密钥类型 unknown、SFTP 冻结等）
- [x] 审查 workflow 找出的 SSH 引擎 / 终端会话 / SFTP 数据安全 / 转发 / 主密码缺陷已修复并补单测（133 个）
- [x] 界面整体按 Apple HIG 重做（设计系统 + 全部页面与弹窗），zh-Hans 词条补全（按编译器导出的 .stringsdata 核对）
- [x] 推送前审查（5 个维度 + 反向核实）确认的 21 条缺陷已修复：锁屏时页面弹窗仍可见、远程编辑未上传的修改被删、备份不含 WAL、恢复先删库、加密导入必然失败、主密码 hash/salt 不在同一事务、口令进 `ssh-keygen` 的 argv、退出码 255 误判为断线等（单测 174 个）
- [x] 设计评审一轮（四个视角 + 裁决，39 条提案采纳 22 条）已应用：弹窗标题层级、卡片底色、广播描边、空状态不闪现、复制反馈等
- [x] 需要点击的验收项（A–G）与 21 条修复的真机逐条复验：用辅助功能在本机点了一遍，锁屏 / 备份 / 恢复 / 加密导入这类会动数据的在隔离配置目录里做（`open -n --env CFFIXED_USER_HOME=<目录> Termi.app`）。过程中新修：嵌套分屏关窗格后兄弟窗格变黑且焦点跑偏、改字号后末两列压在滚动条下、⌘Q 不询问就断开全部会话、**终端有焦点时锁定会卡死**、认证弹窗 / 查找栏 / 菜单文案、SFTP 操作失败顶掉文件列表
- [x] Xcode 16.2 / Swift 6.0（CI）：构建 + 223 个测试全绿。之前红是 Swift 6.0.3 编译器在测试里崩溃，见「Swift 规范」
- [x] SFTP 名字 / 路径的独立反向审查（5 个视角 + 3 个核实者 + 查漏）与修复：名字按字节判断、身份按字节比较、远程编辑保存到记录的精确路径、非 UTF-8 名字只显示不操作、重命名不覆盖、目录遍历有上限、特殊文件不下载、同名折叠不互相顶替等，41 个新测试
- [ ] 仍需手动确认：面板之间 / 从 Finder 拖放、拖动标签排序、关 Wi-Fi 与合盖唤醒后的自动重连、Esc 关查找栏和弹窗（自动化不能合成 Esc）、悬停观感、慢链路上的长传输（速度 / 剩余时间 / 取消）、VoiceOver 实听

### 未提交变更

无。

---

## 编码规范

### Swift 规范
- 使用 **Swift 6** 语法，启用 strict concurrency
- 优先使用 `async/await` 和 `actor`
- ViewModel 使用 `@Observable` (非 ObservableObject)
- 环境值通过 `@Environment` 注入
- 错误处理使用 typed throws 或 `Result`
- **`#expect` / `#require` 的闭包里不做枚举模式匹配**（`if case` / `guard case` / `switch` / `catch X.y`）：Swift 6.0.3 的类型检查器在宏展开里遇到对 `any Error` 的枚举模式会直接崩溃，CI 上只看到「SwiftCompile failed with a nonzero exit code」而没有 `error:` 行。把匹配放进文件级函数，宏闭包只调用它（见 `SecureStoreTests.swift` 开头）
- **交给系统框架的回调闭包必须标 `@Sendable`**（在 `@MainActor` 类型里创建时尤其如此）：如 `NWPathMonitor.pathUpdateHandler`、`UNUserNotificationCenter` 的 completion handler。否则闭包继承 MainActor 隔离，框架在后台队列回调时 Swift 6 运行时隔离检查会直接崩溃（`dispatch_assert_queue_fail`）；闭包内需要主线程时用 `Task { @MainActor in … }`

### SwiftUI 规范
- 遵循 Apple Human Interface Guidelines (macOS)
- 使用 **SF Symbols** 图标
- 部署目标 macOS 15。发布包和 CI 主任务用 **Xcode 26**（macOS 26 SDK）构建——只有这样应用才有 Liquid Glass；CI 另有一个 Xcode 16.2 / Swift 6.0（macOS 15 SDK）的兼容任务，同一份代码必须在两边都能编译、测试通过。因此：macOS 26 才有的 API（`glassEffect` / `GlassEffectContainer` / `.buttonStyle(.glass)` 等）一律包在 `#if compiler(>=6.2)` 加 `if #available(macOS 26, *)` 里，旧环境走 `.regularMaterial` 之类的回退（只是没有玻璃效果）；不用参数列表尾逗号等 6.0 之后的语法
- 颜色使用系统语义色 (`Color(nsColor: .textBackgroundColor)`)
- 优先 SwiftUI，仅在必要时使用 AppKit
- **`updateNSView` 里不同步隐藏第一响应者、不同步改第一响应者**：AppKit 会去找下一个可聚焦视图并询问 hosting view 的焦点系统，在视图图更新途中重入，锁屏出现时成环卡死（100% CPU）。只记下目标状态，推迟到本次更新之后再应用（`TerminalContainerNSView.setTerminal(hidden:wantsFocus:)`）
- 会话的终端视图只归最新的包装视图（`TerminalSession.viewHost`）：分屏布局变形时 SwiftUI 先建新包装、再最后更新一次旧包装，旧的不得把视图抢回去

### 安全红线 (MUST NOT)
- **禁止使用 macOS Keychain** — 不得 `import Security`，不得调用 `SecItemAdd/SecItemCopyMatching/SecItemUpdate/SecItemDelete` 等 Keychain API。密钥存储必须使用 `SecureStoreService`（本地文件 + AES-256-GCM），完全独立于系统 Keychain。
- **禁止使用 iCloud** — 不得调用 CloudKit / NSUbiquitousKeyValueStore / iCloud Drive API。同步通过本地加密导入/导出实现。
- **禁止 App Sandbox** — `ENABLE_APP_SANDBOX` 必须为 `NO`（SwiftTerm PTY 需要 `tcsetpgrp()`）。使用 Hardened Runtime 替代。

### Git 规范
- Commit message 格式: `<type>: <description>`
- Type: `feat`, `fix`, `ui`, `refactor`, `docs`, `chore`
- 中英文均可，保持简洁

---

## 关键依赖

| 依赖   | 用途             | 引入方式 |
| ---- | -------------- | ---- |
| GRDB | SQLite 数据库 ORM | SPM  |
| SwiftTerm | 终端仿真与渲染（固定 1.18.x：1.19+ 给库目标加了构建插件，xcodebuild 需额外信任） | SPM |
| Sparkle | 自动更新 | SPM |

> 注意: SSH 功能通过系统 OpenSSH（`/usr/bin/ssh`，ControlMaster 复用）实现，SFTP 为自研 v3 协议客户端，未使用第三方 SSH 库。

---

## Agent 协作指南

### 对 Claude Code 的指令
1. **读取此文件** 获取项目全貌，避免重复探索
2. **每次 commit 后更新** 本文件的 "Commit 历史" 和 "当前工作" 部分
3. **架构变更时更新** "技术架构" 部分
4. **新增功能后更新** "路线图" 状态

### 对其他 Agent 的指引
- 本项目是 **macOS 原生应用**，不是 Web 或跨平台
- 所有 UI 代码在 `Views/` 目录，业务逻辑在 `Services/`
- 数据库操作必须通过 `DatabaseManager.shared`（actor 隔离）
- SSH 连接通过 `SSHService.shared.connect(to:)` 取得 `Lease`（复用主机的 ControlMaster 主连接），不要自行拼 `ssh` 命令
- 安全敏感数据通过 `SecureStoreService` 存储在本地加密 vault（AES-256-GCM），不使用 macOS Keychain
- 分发方式: 自分发（DMG），不上 App Store，不使用 iCloud

### 上下文快速入口
- 应用入口: `App/TermiApp.swift`
- 主界面: `Views/MainWindow/MainWindowView.swift`
- 路由/导航: `ViewModels/AppViewModel.swift` → `SidebarView.swift`
- 数据库: `Database/DatabaseManager.swift` + `Database/Migrations.swift`
- SSH 核心: `Services/SSH/SSHService.swift` + `SSHConnectionManager.swift` + `SSHMasterConnection.swift`
- 终端会话: `ViewModels/TerminalSession.swift` + `Views/Terminal/TerminalTabView.swift`

---

## 更新日志

### 2026-10-10
- **外部模型审查（Codex CLI，gpt-6-astra / ultra，只读）`823fb8e..HEAD`**：5 条发现全部属实并已修——① 历史记录的 id 不得复用磁盘上已有转录的编号：恢复旧备份后数据库的自增计数会落在留作回滚的转录后面，新记录（新会话或导入）会拿到别的会话的转录编号，显示错输出、删除时还会把它删掉；现在新建记录和导入前都把计数抬到磁盘上最大转录编号之上（`SessionTranscripts.highestId` + `ConnectionLogRepository.reserveIds`），会话开始录制时遇到已存在的文件也不覆盖；② 一个单测在固定路径 `/opt/termi-qa/SessionLogs` 上做删除，改为只在自己的临时目录里；③ `test-env.sh up` 两个同时跑时，输的一方回滚会按名字删掉赢的一方的容器，改为 `docker create` 拿到 id 后只回收自己建的；④ `-debugSeedHosts` 重灌时不清 `identityId`；⑤ 主机详情面板打开时延迟 350ms 的滚动没有核对是否还是同一台主机。单测 538 → 541

### 2026-10-07
- **主机页改成卡片网格、详情按需展开**（用户在 Xcode 里试用后的第 1 条意见，附 Termius 截图）：见「关键设计模式 · 交互形态以 Termius 为基准」。流程：worktree 里实现 → 两位只读评审（交互回归 / 对照参考图）→ 修复 → 合并。⌘I 是「显示」菜单里的正式命令（不是页面里看不见的按钮）；偏好键从 `hostsViewMode` 换成 `hostsLayout`（旧键的 list 含义变了，所有人回到卡片）；页面不再自动选中一台主机。单测 521 → 538
- **字符串目录交给 Xcode 同步**（`2e299d6`）：开了 `SWIFT_EMIT_LOC_STRINGS` 后，在 Xcode 里构建会自动重排目录、清掉无引用的空条目；已按 Xcode 的格式提交，通过变量取到的 15 个键标为 `manual`。之后在 IDE 里构建不应再弄脏工作区；命令行用 `scripts/add-strings.py`（按文本插入词条，不重排目录）加词条后顺序可能和 Xcode 的略有出入，下次 IDE 构建会归位

### 2026-10-05
- **去重**（`d353b64`）：用户指出侧边栏「会话」与顶部标签重叠、各页有重复模块。只读评审 + 裁决出约 60 条 → 改设计稿（画布 23 张）→ 四路实现 → 合并 → 点击验收（44 可用、3 当场修好）。规则见「关键设计模式 · 同一信息只出现一处」。侧边栏选中行保持安静的胶囊（`SidebarSelectionQuieter` 把列表的 `selectionHighlightStyle` 设为 `.none`，否则键盘焦点在列表上时会变成整条强调色）。单测 400 → 434
- **验收遗留缺陷收尾**：两轮点击验收列给机主的具体问题逐条修掉并点过——历史记录的统计卡改为按全部记录在库里聚合（原来只算列表加载的 200 条）；保险库里的私钥 / 身份密码解不开时给出可照做的句子（`SSHServiceError.privateKeyUnreadable` / `.identityPasswordUnreadable`，按错误类型映射）而不是 CryptoKit 原始报错；自己取消密码提示落到安静的「连接已取消」而不是红色失败卡；隐藏标签页的窗格头不再留在辅助功能树里（只给显示中的标签建窗格头和状态卡，终端视图照常挂载）；新建 / 复制主机、新建片段后选中并滚到新项；拷贝（Copy）与复制（Duplicate）用词统一；确认框标题与打开它的菜单同词；同步导入的确认写明替换什么、原库保留在哪；Docker 日志失败带原因。单测 434 → 452
- **测试与验收不再碰真实配置**：原来托管单测会把真实 App 在真实数据上启动一遍（开库、清扫、请求通知权限），隔离验收又与正式版共用偏好域。现在由 `AppProfile` 统一决定位置：单测进临时目录且宿主不做任何事，`TERMI_PROFILE_DIR` 给出完全独立的配置目录（含偏好）。验证方式：跑完整套单测前后，真实目录各文件的大小 / 修改时间和偏好域导出的哈希逐项相同。单测 452 → 469
- **删历史就是删掉它记下的东西**（`025977a`）：会话输出存成 `SessionLogs/<历史记录 id>.log`，原来删历史只删数据库行，输出留在磁盘上最多 90 天。现在每条删除历史行的路径（单条、清除历史记录、启动时清 90 天前的、删除主机时级联）都连带删除对应转录：同一事务里先取 id，先数据库后文件，数据库失败则什么都不删（`Services/SessionTranscripts.swift`，入口都在 `ConnectionLogRepository`；删主机走 `deleteHostWithHistory`）。**故意不做「无记录的转录一律清掉」的清扫**：恢复 / 加密导入后被替换的数据库留着用于回滚，它的记录仍指向这些文件。历史搜索改为在数据库里搜全部记录（`instr`，不用 LIKE，无通配符可转义）。加密导入的历史行不再沿用导出机的 id（否则会显示本机另一个会话的输出）
- **备份记录按文件校验**（`778cd26`）：设置 › 备份只承认文件还在的备份；外接盘未连接 / 目录不可读的记录保留并标注，不当成已删除；页面显示的路径取自 `AppProfile`，不写死
- **验收环境进仓库**（`f69b055`）：`TestEnvironment/`（镜像源 + `test-env.sh up|down|status`，密码 / 密钥 / 主机密钥生成到被忽略的 `.test-env/`，只绑 127.0.0.1，要么全起要么不起）；DEBUG 启动参数 `-debugSeedHosts <json>`（`App/DebugSeed.swift`，标准配置下拒绝）把测试主机灌进隔离配置目录；`make test-env-up / run-isolated / test-env-down`；说明见 `docs/TESTING.md`。坑：屏幕锁着时新配置目录建不出 `.vault-key`（`completeFileProtection`），先放一个 32 字节的随机文件
- **文档对齐产品**：README、`docs/USER_GUIDE.md` 按当前界面逐条对代码重写并配图（`docs/images/`），新增 `CHANGELOG.md`（Keep a Changelog；2.1.0 尚未发布，记在 Unreleased）。单测 469 → 521
- **字符串目录与代码对齐**：`scripts/check-strings.py`（`make check-strings`，CI 每次都跑）拿编译器导出的 `.stringsdata`（`project.yml` 里开了 `SWIFT_EMIT_LOC_STRINGS`）和 `Localizable.xcstrings` 对账：代码用到却没有 zh-Hans 的键 = 错误；目录里没有任何源码引用的条目 = 警告，可用 `--prune` 按文本删除（不重排目录）。通过变量取到的键（枚举原始值、模型里的名字）只要在源码里以字面量出现就算在用。这次清掉 265 条旧条目（清理前后 61 个页面 / 弹窗的截图逐像素对比无文字变化），补了 5 条缺的；图表的读屏标签从占位字母 t / v / low 改成 Time / Value / Baseline
- **清理**：三个早已无引用的旧文件（`Theme/ThemeManager.swift`、`Theme/LiquidButtonStyles.swift`、`Views/Shared/PageHeaderView.swift`）移出仓库；`.omc/` 进 `.gitignore`
- **点击验收**（`e5ad82a` … `4425f36`）：解锁后用辅助功能把重做后的界面点了一遍，149 可用、20 当场修好；未测的（悬停观感、拖放、Esc、长传输、合盖唤醒）仍需手动确认
- **界面整体重做**（`694cf1d` … `64289e3`）：先在 Claude Design 画布出 23 张设计稿并经用户确认方向（Liquid Glass + 克制配色 + 发行版图标），再实现：共享设计层（`Theme/` 拆成 Glass / Tiles / DataCards / Charts / Components）→ 七个页面包并行实现（各自「实现 → 回归审计 → 对照设计稿评审」）→ 合并 → 再打磨一轮。单测 224 → 398
- **发行版图标**：连接后自动识别系统并更新主机图标（迁移 `v8_host_system`、`HostSystemProbe`、`Assets.xcassets/OS`）
- **工具链**：发布与 CI 主任务改用 Xcode 26（macOS 26 SDK 才有 Liquid Glass），CI 另留 Xcode 16.2 兼容任务；Swift 6.0 的坑新增一条——`#expect` 里不要写算术或长链，类型检查会超时，先算进带类型的 `let`
- **DEBUG 截图手段**：`-debugActive YES` 让窗口在锁屏下也按活动状态绘制；各页新增直达状态的启动参数（`-debugHostSelect` `-debugMonitorHost` `-debugSFTPHost` `-debugVaultSelect` `-debugSessionState` `-debugBatchSample` `-debugLockSessions` …，见各页面文件里的 `#if DEBUG`）

### 2026-10-04（晚）
- CI 修绿：测试目标在 Swift 6.0.3 上编译器崩溃（`#expect … throws: { if case … }`），改为文件级函数匹配
- SFTP 名字 / 路径反向审查与修复合并（见「关键设计模式 · SFTP 名字与路径」），单测 182 → 223
- 阶段 3 验收 A–G 与 21 条修复逐条复验；新修分屏黑屏、字号列数、⌘Q 确认、锁定卡死、文案与提示方式
- DEBUG 验证手段：`CFFIXED_USER_HOME` 隔离配置目录（独立的数据库、保险库、主密码），不碰真实数据
- 设计评审第 5 轮（四个视角 + 裁决，21 条提案采纳 13 条）已应用：广播时启动片段只进自己的窗格、「不再询问」只随确认生效、历史记录时长列不截断、传输完成行不再一列绿字、编辑上传失败换图标、已知主机删除失败不盖住列表、锁定时菜单项置灰、关闭单个会话的文案、连接失败原因本地化、「无主机」空状态带入口等
- 设计评审第 6 轮（17 条提案采纳 12 条）已应用：主机页 / 密钥库 / 工具页读库失败显示「错误 + 重试」而不是「无主机」，保存 / 删除失败有错误条；删除分组的确认框标题；SFTP 本地路径框输错后复位；编辑上传失败的文字与悬停；失败红字统一混色；主密码提示只给图标上色；设置里的「关闭前确认」开关跟随「不再询问」；SFTP 底栏文字按钮用链接样式
- 设计评审第 7 轮（15 条提案全部成立，合并为 14 项）已应用：身份表单在密码加密或保存失败时不再悄悄关闭、SFTP 页读主机失败显示错误、监控页自动刷新时错误不再与「正在加载」来回切换、历史记录可按界面上的状态词和错误文字搜索并支持 ⌘R、三个页面的错误条可关闭、锁屏错误字混色、错误浮层停留 8 秒、弹窗里的「无主机」带入口、几处文案
- macOS 26+ 的坑（已测量，未改）：窗口宽度小于 900 + 检查器宽度（1180）时打开片段检查器，系统会把窗口加宽 480pt（检查器 280 + 被算两次的侧边栏 200）；给内容区声明更小的最小宽度（`.frame(minWidth:)` / `navigationSplitViewColumnWidth`）都不改变这个判定

### 2026-10-04
- V3 真机验收：密码 / 密钥 / agent / 跳板 / keyboard-interactive 认证、连接复用、分屏广播、SFTP 传输、端口转发、退出清理均在本机实测；修复 12 类缺陷（见 Commit 历史 `3977686`…`8cf3b7e`）
- 界面按 Apple HIG 重做（`7339f3f`）：系统侧边栏 + 统一工具栏 + 系统列表/表单/表格，`Theme/DesignSystem.swift` + `Theme/Components.swift`；旧的 `ThemeManager.swift` / `LiquidButtonStyles.swift` / `Shared/PageHeaderView.swift` 已无引用
- 本地化：ViewModel / Service 里写死的英文提示全部走字符串目录；计数类词条补英文单复数
- DEBUG 构建支持启动参数直达页面/弹窗/会话（`-debugPage` `-debugSheet` `-debugConnect` `-debugSplit` `-debugSFTP` `-debugAppearance` `-debugWindowSize`），用于截图自检
- macOS 26+ 的坑：浮动侧边栏的宽度会在 NavigationSplitView 的最小宽度里被算两次；`HSplitView` 的窗格按理想宽度撑开。SFTP 双面板因此改为自己的等分可拖动分栏；分组 `List` 在已有列表上无动画插入行时行高停在默认值（端口转发页用 `.id(已加载)` 在数据到位后重建列表）
- 推送前审查 + 修复：见「当前工作」；`SyncService` 导出格式升到 3（秘密只由导出密码保护）
- 设计评审与优化：`Theme/Components.swift` 新增 `DSSheetTitle` / `DSDelayed` / `DSCopyButton`，规则补进 `Theme/AGENTS.md`

### 2026-09-26
- V3 Termius 对齐（SSH 为主）：SSH 引擎重写（ControlMaster 主连接复用 + askpass 桥）、SFTP v3 客户端、分屏/广播/查找/片段面板/自动重连、主机分组默认值/标记/搜索即连接/导入 ~/.ssh/config
- 构建：SwiftTerm 固定 1.18.x、移除 swift-nio-ssh、AGENTS.md 不再打包进资源；CI 覆盖 `claude/**` 分支并以 Release 配置构建
- 非 UI 层（模型/仓储/服务/SSH 引擎）可在 Linux 上用 Swift 6.0.3 + GRDB 编译，SSH 引擎与 SFTP 已对真实 OpenSSH sshd 做集成测试
- macOS CI（Xcode 16.2）：Release 构建通过、101 个测试全部通过；修复两处启动即崩溃的 Swift 6 运行时隔离问题（NWPathMonitor 回调、通知权限回调——后者为既有问题，旧 CI 的 `| tail` 掩盖了失败）

### 2026-02-27
- 创建项目 CLAUDE.md + Obsidian 同步
- 项目从 Phase 1 到 Phase 7 全部完成
- UI 优化为 App Store 风格
- KeychainService → SecureStoreService（独立 AES-256-GCM 加密，脱离 macOS Keychain）
- 去除 iCloud 同步，改为本地加密导入/导出
- 分发策略: 自分发（DMG），不上 App Store
