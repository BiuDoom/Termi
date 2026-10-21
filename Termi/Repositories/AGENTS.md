<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Repositories

## Purpose
数据访问层（Repository Pattern），为每个 Model 提供类型安全的 CRUD 接口。将 ViewModels 与 GRDB 查询语法解耦，方便单元测试和未来数据源切换。

## Key Files

| File | Description |
|------|-------------|
| `HostRepository.swift` | Host CRUD + 按分组/标签查询 |
| `GroupRepository.swift` | Group CRUD |
| `SSHKeyRepository.swift` | SSHKey CRUD（不含私钥内容） |
| `IdentityRepository.swift` | Identity CRUD + 关联密钥查询 |
| `KnownHostRepository.swift` | KnownHost 查询/添加/删除 |
| `SnippetRepository.swift` | Snippet CRUD + 搜索 |
| `ConnectionLogRepository.swift` | ConnectionLog 写入 + 分页查询 |
| `PortForwardRepository.swift` | PortForward CRUD |

## For AI Agents

### Working In This Directory
- 所有 Repository 方法均为 `async throws`，内部通过 `DatabaseManager.shared` 访问数据库
- Repository 只处理数据持久化，**不包含业务逻辑**（业务逻辑在 Services 层）
- SSH 密钥私钥内容通过 `SecureStoreService` 存储，Repository 只存元数据

### Common Patterns
```swift
struct HostRepository {
    func fetchAll() async throws -> [Host] {
        try await DatabaseManager.shared.read { db in
            try Host.order(Column("name").asc).fetchAll(db)
        }
    }

    func save(_ host: inout Host) async throws {
        try await DatabaseManager.shared.write { db in
            try host.save(db)
        }
    }
}
```

## Dependencies

### Internal
- `Database/DatabaseManager.swift` — 数据库访问
- `Models/` — 对应的 Record 类型

<!-- MANUAL: -->
