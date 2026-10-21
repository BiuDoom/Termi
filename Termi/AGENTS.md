<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Termi (主应用源代码)

## Purpose
主应用所有 Swift 源代码，采用严格 MVVM 分层：App 入口 → Models → Database → Repositories → Services → ViewModels → Views。所有层之间通过协议和 `@Environment` 注入解耦。

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `App/` | 应用入口和生命周期（见 `App/AGENTS.md`） |
| `Models/` | GRDB 数据模型，11 个 Record 类型（见 `Models/AGENTS.md`） |
| `Database/` | Actor-based 数据库管理和迁移（见 `Database/AGENTS.md`） |
| `Repositories/` | 数据访问层 CRUD 操作（见 `Repositories/AGENTS.md`） |
| `Services/` | 业务逻辑：SSH、加密、SFTP、监控等（见 `Services/AGENTS.md`） |
| `ViewModels/` | @Observable ViewModel，14 个（见 `ViewModels/AGENTS.md`） |
| `Views/` | SwiftUI 视图，35 个文件（见 `Views/AGENTS.md`） |
| `Theme/` | 主题管理和 Liquid Glass 按钮样式（见 `Theme/AGENTS.md`） |
| `Utilities/` | 通用工具扩展（见 `Utilities/AGENTS.md`） |
| `Resources/` | Assets、entitlements、Info.plist（见 `Resources/AGENTS.md`） |

## For AI Agents

### Working In This Directory
- 数据流向：Views → ViewModels → Repositories/Services → DatabaseManager
- 所有 DB 操作必须通过 `DatabaseManager.shared`（actor 隔离）
- ViewModel 使用 `@Observable`，通过 `.environment()` 注入视图
- SSH 连接核心：`Services/SSH/SSHService.swift`
- 安全存储：`Services/SecureStoreService.swift`（禁止绕过使用 Keychain）

### Common Patterns
```swift
// ViewModel 注入示例
@Environment(AppViewModel.self) private var appVM

// DB 访问示例
await DatabaseManager.shared.write { db in ... }

// SSH 连接
let session = await SSHService.shared.connect(to: host)
```

### Testing Requirements
- 测试位于项目根目录 `TermiTests/`
- Services 层有单元测试覆盖（CryptoService、ProcessRunner、MonitorParsing）

## Dependencies

### External
- **GRDB** — SQLite 数据库 ORM

<!-- MANUAL: -->
