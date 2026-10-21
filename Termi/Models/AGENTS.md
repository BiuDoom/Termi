<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Models

## Purpose
GRDB 数据模型层，定义 11 个 Record 类型，对应数据库表结构。每个 Model 遵循 `FetchableRecord`、`PersistableRecord` 协议，实现自动 SQLite 序列化/反序列化。

## Key Files

| File | Description |
|------|-------------|
| `Host.swift` | SSH 主机配置（地址、端口、用户名、认证方式、分组） |
| `SSHKey.swift` | SSH 密钥元数据（密钥类型、公钥指纹，私钥存 SecureStore） |
| `Identity.swift` | 身份管理（用户名 + 关联密钥的命名组合） |
| `Group.swift` | 主机分组（名称、颜色、排序） |
| `Tag.swift` | 标签（与主机多对多关联） |
| `KnownHost.swift` | SSH known_hosts 记录（主机指纹验证） |
| `Snippet.swift` | 命令片段（标题、内容、分组） |
| `ConnectionLog.swift` | 连接日志（时间戳、主机、结果、错误信息） |
| `PortForward.swift` | 端口转发规则（本地/远程端口、绑定地址） |
| `SFTPItem.swift` | SFTP 文件项（路径、大小、权限、修改时间） |
| `AppSettings.swift` | 应用设置（主题、安全、终端配置等键值对） |

## For AI Agents

### Working In This Directory
- 所有 Model 修改必须同步更新 `Database/Migrations.swift` 中的 schema
- 新增字段需要新 migration 版本（不得修改已有 migration）
- `SFTPItem` 是内存对象（非 GRDB Record），用于 SFTP 目录列表
- 敏感字段（私钥内容、密码）**禁止**存入 Model/数据库，改存 `SecureStoreService`

### Common Patterns
```swift
struct Host: Codable, FetchableRecord, MutablePersistableRecord {
    static let databaseTableName = "hosts"
    var id: Int64?
    var hostname: String
    // ...
    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

### Testing Requirements
- `TermiTests/ModelTests.swift` 覆盖序列化测试
- `TermiTests/DatabaseTests.swift` 覆盖 CRUD 操作

## Dependencies

### Internal
- `Database/DatabaseManager.swift` — 数据库连接
- `Database/Migrations.swift` — 表结构定义

### External
- **GRDB** — `FetchableRecord`、`PersistableRecord` 协议

<!-- MANUAL: -->
