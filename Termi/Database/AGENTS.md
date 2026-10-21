<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Database

## Purpose
数据库基础设施层，提供 actor-isolated 的 SQLite 连接管理和版本化迁移系统。所有数据库操作的单一入口点，保证 Swift 6 并发安全。

## Key Files

| File | Description |
|------|-------------|
| `DatabaseManager.swift` | `actor DatabaseManager`，单例，管理 GRDB DatabaseQueue，提供 `read`/`write` 方法 |
| `Migrations.swift` | 所有数据库迁移定义，按版本号顺序注册 |

## For AI Agents

### Working In This Directory
- `DatabaseManager` 是 `actor`，所有调用必须 `await`
- **禁止**绕过 `DatabaseManager` 直接操作数据库文件
- 迁移是累加的（append-only），**禁止修改已有迁移**，只能新增迁移版本
- 数据库文件位于 `~/Library/Application Support/Termi/termi.db`（WAL 模式）

### Common Patterns
```swift
// 读取
let hosts = try await DatabaseManager.shared.read { db in
    try Host.fetchAll(db)
}

// 写入
try await DatabaseManager.shared.write { db in
    try host.insert(db)
}

// 新增迁移（在 Migrations.swift 末尾追加）
migrator.registerMigration("v2_add_host_tags") { db in
    try db.alter(table: "hosts") { t in
        t.add(column: "tags", .text)
    }
}
```

### Testing Requirements
- `TermiTests/DatabaseTests.swift` 使用 `:memory:` 数据库测试迁移和 CRUD

## Dependencies

### Internal
- `Models/` — 所有 GRDB Record 类型

### External
- **GRDB** — DatabaseQueue、DatabaseMigrator

<!-- MANUAL: -->
