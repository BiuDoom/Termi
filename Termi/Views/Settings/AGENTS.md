<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/Settings

## Purpose
设置窗口（⌘,）：系统的工具栏式 `TabView`，七个页签（通用 / 终端 / 导入导出 / 同步 / 备份 / 通知 / 关于）。每个页签是一列分组卡（内容层），窗口宽 760，高度跟随当前页签，超过 `SettingsLayout.maxPaneHeight` 后页内滚动。

## Key Files

| File | Description |
|------|-------------|
| `SettingsView.swift` | 窗口与七个页签；页签的骨架（`SettingsPage` / `SettingsSection` / `SettingsRow` / `SettingsToggleRow`）；`TerminalPreview`、`TerminalThemeGrid` / `TerminalThemeCard`；`BackupFileRow`；`SyncPasswordSheet` |

## 页签怎么拼

- **不用 `Form(.grouped)`**：页签 = `SettingsPage { SettingsSection("标题") { SettingsRow / SettingsToggleRow … } footer: { … } }`。`SettingsSection` 是 `DSSectionHeader` + `DSGroup`；行是 `DSRow`（名称 + 可选的一行说明在左，控件在右）。说明文字最多两行，其它不换行。
- 开关用 `SettingsToggleRow`（名称是 `Toggle` 的标签，整行是一个控件）；`Picker` 放进 `SettingsRow` 时 `.labelsHidden().fixedSize()`（标签留给无障碍）。
- 行里的按钮 `.dsButtonStyle(.glass, size: .small)`。整个设置窗口只有一个 `.prominent`：备份页的「创建备份…」。
- **终端页**：顶部 `TerminalPreview`（当前主题色 + 当前字体 / 字号 / 光标，四行放不下时只留命令和提示符两行）；主题是 `TerminalThemeGrid`（12 张主题色卡，选中的带强调色环和对勾）；下面是「文字」「行为」两组。
- **备份页**：两张数字卡（上次备份 + 最近 14 天的日条；数据库大小 + 主机 / 密钥 / 片段数）→ 备份 / 恢复两行 → 备份文件列表 → 警告与说明。数据来自 `SettingsViewModel.backupOverview`（`loadBackupOverview()`，只读）。
- **通用页**有「连接后读取主机的系统」开关：`@AppStorage(HostSystemProbe.settingKey)`，默认开。

## 备份页的数据

- 备份存到保存面板选的任何位置，没有固定的备份目录。所以 App 自己记一笔（`UserDefaults` 的 `backupRecords`：路径 + 时间，最多 30 条）：「上次备份」和日条读它；文件列表 = 记录里还存在的文件 + 数据库目录下的 `termi.before-*.db`（恢复 / 导入前留下的原数据库）。
- 列表里的「恢复…」是一次点击就能触发的：先弹确认框（破坏性按钮、Return 不触发），再走和「选取文件…」同一条恢复路径。**不要去掉这个确认。**
- 没有数据显示「—」/「从未」/「尚无备份」，不显示 0 字节。

## For AI Agents

### Working In This Directory
- 设置项经 `SettingsViewModel` 读写（`AppSetting` 表）；`suppressSSHCloseConfirmation`、`detectHostSystem`、`settingsSelectedTab` 是 `@AppStorage`。
- 外观（浅色 / 深色 / 跟随系统）用 `.preferredColorScheme` 应用在 `TabView` 上。
- 备份 / 恢复 / 加密导入的数据安全文案与流程不改（先校验再替换、原库保留为 `termi.before-*.db`、恢复后需重启）。
- 仅 DEBUG 的启动参数（截图用）：`-settingsSelectedTab terminal|backup|…`（就是那个 `@AppStorage`）、`-debugBackupSample YES`（备份页用示例数据，不写任何东西）、`-debugAppearance Light|Dark`（设置窗口也跟随，不保存）。
- 屏幕锁定时截图，设置窗口不是 key window：开关、分段控件、主按钮画成灰色，这不是缺陷。

## Dependencies

### Internal
- `ViewModels/SettingsViewModel.swift`（含 `BackupOverview` / `BackupFile` / `BackupRecord`）、`ViewModels/SecurityViewModel.swift`
- `Theme/`（`DSGroup`、`DSRow`、`DSSectionHeader`、`DSStatCard`、`DSDayStrip`、`DSMessage`、`DSChip`、`DSGlassIconButton`、`dsButtonStyle`、`dsStageBackground`）
- `Services/SyncService.swift`、`Services/ImportExportService.swift`、`Services/HostSystemProbe.swift`（只用 `settingKey`）

<!-- MANUAL: -->
