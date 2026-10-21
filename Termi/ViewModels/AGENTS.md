<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-09-26 -->

# ViewModels

## Purpose
MVVM 表现层的状态管理，`@Observable` ViewModel，每个对应一个功能域。ViewModel 持有 UI 状态、调用 Repository/Service 层，并通过 `@Environment` 注入视图。

## Key Files

| File | Description |
|------|-------------|
| `AppViewModel.swift` | 每个窗口一份：侧边栏导航、终端标签（`TerminalTab`，含窗格布局树 `PaneLayout`、广播输入）、会话表（`sessions`）、分屏/关闭/聚焦、代码片段执行、窗口内 SFTP 状态 |
| `HostsViewModel.swift` | 主机列表/搜索/标记过滤/排序、分组、`HostDraft` 保存（转发规则、标记、密码）；`QuickConnectParser` |
| `TerminalSession.swift` | 一个终端窗格的会话（本地 shell / 已保存主机 / 临时主机）：持有 SwiftTerm 视图、租用 SSH 主连接、状态机（connecting/connected/reconnecting/ended/failed）、指数退避自动重连、启动片段、会话记录（transcript） |
| `SecurityViewModel.swift` | 锁屏逻辑、PIN 验证、自动锁定计时器 |
| `KeysViewModel.swift` | SSH 密钥列表、生成、导入/删除 |
| `SFTPViewModel.swift` | 双面板文件浏览（基于 `SFTPSession`）、传输队列（进度/速度/取消）、远程文件编辑（保存自动上传） |
| `BatchCommandViewModel.swift` | 批量命令状态、目标主机选择、输出收集 |
| `MonitorViewModel.swift` | 服务器监控数据、轮询定时器、历史图表数据 |
| `DockerViewModel.swift` | Docker 容器/镜像列表、操作状态 |
| `SnippetsViewModel.swift` | 命令片段 CRUD、搜索过滤 |
| `ConnectionLogsViewModel.swift` | 连接日志分页加载、过滤 |
| `SettingsViewModel.swift` | 应用设置读写、主题切换 |
| `IdentitiesViewModel.swift` | 身份 CRUD、关联密钥选择 |
| `KnownHostsViewModel.swift` | known_hosts 列表管理 |

## For AI Agents

### Working In This Directory
- 所有 ViewModel 使用 `@Observable` 宏（Swift 5.9+），**不使用** `ObservableObject`
- ViewModel 通过 `@Environment` 传递：`@Environment(AppViewModel.self) private var appVM`
- 异步操作用 `Task { ... }` 包裹，避免在 `init` 中执行异步工作
- `AppViewModel` 是核心路由，修改导航状态必须通过它

### Common Patterns
```swift
@Observable
final class HostsViewModel {
    var hosts: [Host] = []
    var searchText = ""

    private let repo = HostRepository()

    func loadHosts() async {
        do {
            hosts = try await repo.fetchAll()
        } catch { /* handle */ }
    }
}
```

### Testing Requirements
- `TermiTests/AppViewModelTests.swift` 覆盖导航状态测试

## Dependencies

### Internal
- `Repositories/` — 数据访问
- `Services/` — 业务逻辑

<!-- MANUAL: -->
