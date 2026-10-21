<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Termi

## Purpose
原生 macOS SSH 客户端，使用 SwiftUI + Swift 6 构建，面向开发者和运维人员。采用 MVVM 架构，actor 隔离数据库，pty-based SSH 连接，本地 AES-256-GCM 加密存储，自分发（DMG），不依赖 App Store 或 iCloud。

## Key Files

| File | Description |
|------|-------------|
| `CLAUDE.md` | 项目知识库，AI Agent 主要上下文文档 |
| `project.yml` | XcodeGen 项目配置文件 |
| `firebase-debug.log` | Firebase 调试日志（可忽略） |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `Termi/` | 主应用源代码（Swift 6 + SwiftUI）（见 `Termi/AGENTS.md`） |
| `Termi.xcodeproj/` | Xcode 项目文件（自动生成，勿手动编辑） |
| `TermiTests/` | 单元测试套件（见 `TermiTests/AGENTS.md`） |
| `scripts/` | 构建/辅助脚本 |

## For AI Agents

### Working In This Directory
- **读取 `CLAUDE.md`** 获取完整项目架构、编码规范和安全红线
- 源代码修改请在 `Termi/` 目录中进行
- `Termi.xcodeproj/` 通过 XcodeGen（`project.yml`）自动生成，修改配置应编辑 `project.yml`
- 禁止使用 macOS Keychain API（`SecItemAdd` 等），所有敏感存储通过 `SecureStoreService`
- 禁止 iCloud / CloudKit API
- App Sandbox 必须为 `NO`（pty 需要 `tcsetpgrp()`）

### Testing Requirements
- 在 Xcode 中运行 `TermiTests` target，或使用 `xcodebuild test`
- 测试文件位于 `TermiTests/`

### Common Patterns
- Swift 6 strict concurrency，所有跨 actor 调用用 `await`
- `@Observable` ViewModel（非 `ObservableObject`）
- GRDB actor-based 数据库访问（`DatabaseManager.shared`）
- SF Symbols 图标，系统语义色

## Dependencies

### External
- **GRDB** (SPM) — SQLite ORM，WAL 模式

<!-- MANUAL: -->
