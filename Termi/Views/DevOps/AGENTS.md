<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/DevOps

## Purpose
DevOps 工具集视图，包含批量命令执行、服务器资源监控、Docker 容器管理、命令片段库和连接历史日志。

## Key Files

| File | Description |
|------|-------------|
| `PortForwardsView.swift` | 端口转发（骨架 B）：顶部三张数字卡（规则 / 运行中 / 自动启动），每台主机一张分组卡，每条规则 = 路线图（监听处 ┄ 主机 ┄ 目标）+ 类型 + **运行开关** + `⋯` 菜单（自动启动、拷贝地址、拷贝为 ssh 命令、在浏览器中打开、编辑、删除）+ 一行状态。`OpsErrorBanner` 也在这个文件里，被别的页面引用，不得改名 / 改初始化器 |
| `BatchCommandView.swift` | 批量命令（骨架 A，主栏 260）：左侧按分组勾选主机，右上命令编辑器（历史 / 片段菜单、⌘↩ 运行），下面是本次运行的数字、「按主机 / 按输出分组」两种结果 |
| `MonitoringView.swift` | 服务器监控：CPU/内存/磁盘实时图表，轮询刷新 |
| `DockerView.swift` | Docker：容器/镜像列表、启动/停止/删除操作 |
| `SnippetsView.swift` | 代码片段（骨架 A）：分类筛选 + 按分类分节的主栏；详情 = 命令（高亮 `{{变量}}`）、变量输入、预览、「运行到」打开的会话、把它用作启动片段的主机。表单 `SnippetFormSheet` |
| `ConnectionLogsView.swift` | 连接历史日志：分页显示，按主机/时间过滤 |

## For AI Agents

### Working In This Directory
- `MonitoringView` 使用定时器轮询，注意视图消失时取消轮询（`onDisappear`）
- `BatchCommandView` 并发执行多主机命令，结果需线程安全地追加到 `@Observable` 数组
- 端口转发：**开关 = 运行状态**（`PortForwardManager`），「随终端会话自动启动」在菜单里并写在状态行；连接中开关禁用，「停止隧道」仍在菜单。「在浏览器中打开」只在菜单里（不是每个转发都是 HTTP）；「拷贝为 ssh 命令」只拷贝、不执行
- 三个页面的数字、分节、分组都是 ViewModel 上的 `nonisolated static` 纯函数（`PortForwardViewModel.Summary` / `sshCommand`、`SnippetsViewModel.sections`、`BatchCommandViewModel.hostSections` / `outputGroups` / `Summary`），单测在 `TermiTests/RedesignWP5Tests.swift`
- 监控与 Docker 共用主栏 `ToolsHostMaster`（在 `MonitoringView.swift`），尾部内容由页面给；两页的 VM 自带 hosts，收到 `.dsDataChanged` 要重读，判断「还是不是同一台」用 `Host.isSameTarget`（忽略 `os_*`）而不是 `isSameSave`。Docker 的宽 / 窄是两张各自固定列的 `Table`。数字格式在 `MonitorFormat` / `HistoryFormat`，合计在 `DockerSummary` / `HistorySummary`，都有单测。DEBUG 参数：`-debugMonitorHost`、`-debugMonitorHistory`、`-debugDockerSample`、`-debugDockerHost`
- 带 `{{变量}}` 的片段**不会带着空洞发出去**：片段详情的「运行」/「运行到」和终端里的变量弹窗在每个变量都有值之前禁用（`SnippetTemplate.missingValues`）；批量命令的「片段」菜单把带变量的片段列为禁用项（批量页没有填变量的地方）
- 批量命令保留 stdout、stderr 和真实退出码；已执行命令显示退出码，连接/传输失败才显示「失败」。按输出分组、单条拷贝和全部拷贝都保留两条输出流及非零退出码；结果送达后才更新完成统计。
- DEBUG 启动参数（截图用，读在各自页面的 `.task` 里）：`-debugPortForwards running|empty`（示例状态 / 空状态，不启动、不删除任何东西）；`-debugSnippet <名称>`、`-debugSnippetValues name=world`、`-debugSnippetSessions local[,<主机标签>]`；`-debugBatchSample host|output`（虚构结果，不连接）、`-debugBatchRun <命令>` + `-debugBatchHosts a,b`（默认 test-agent，真的执行）

## Dependencies

### Internal
- `ViewModels/PortForwardViewModel.swift`
- `ViewModels/BatchCommandViewModel.swift`
- `ViewModels/MonitorViewModel.swift`
- `ViewModels/DockerViewModel.swift`
- `ViewModels/SnippetsViewModel.swift`
- `ViewModels/ConnectionLogsViewModel.swift`

<!-- MANUAL: -->
