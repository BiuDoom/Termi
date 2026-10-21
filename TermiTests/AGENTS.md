<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# TermiTests

## Purpose
单元测试套件，覆盖核心业务逻辑层（ViewModel、Database、Models、Services、Utilities）。不包含 UI 测试（UI 通过手动测试验证）。

## Key Files

| File | Description |
|------|-------------|
| `AppViewModelTests.swift` | AppViewModel 状态管理测试 |
| `CryptoServiceTests.swift` | AES-256-GCM 加密/解密正确性测试 |
| `DatabaseTests.swift` | GRDB 数据库 CRUD 和迁移测试 |
| `ModelTests.swift` | 数据模型序列化/反序列化测试 |
| `MonitorParsingTests.swift` | MonitorService 输出解析测试 |
| `ProcessRunnerTests.swift` | ProcessRunner 进程执行和输出捕获测试 |
| `UtilityTests.swift` | Array+Safe、DateFormatting 等工具函数测试 |

## For AI Agents

### Working In This Directory
- 测试使用 Swift Testing 框架（`@Test`、`#expect`）或 XCTest
- 每个测试文件对应 `Termi/` 中同名的生产代码
- 新增 Service 或 Utility 时，应在此目录添加对应测试文件
- 数据库测试使用内存数据库（`:memory:`）避免持久化副作用
- **测试是隔离的，必须保持隔离**：测试托管在 App 里，但宿主在测试运行时只是一个裸 NSApplication（`App/main.swift`），数据和偏好落在 `$TMPDIR/Termi-Tests/<pid>`（`App/AppProfile.swift` 的 tests 配置），不会打开真实的 `~/Library/Application Support/Termi`，也不写真实偏好域。测试里不要绕过 `AppProfile`（不要自己拼 Application Support 路径，不要用别的 `UserDefaults` 域）。用到 `DatabaseManager.shared` / `*Repository.shared` 的测试共享整个测试进程的一个库，Swift Testing 并行执行：各用各的行，不要断言整张表
- Swift 6.0（CI 的 Xcode 16.2）的坑：`#expect` / `#require` 里不做枚举模式匹配、不写算术和长链（先算进带类型的 `let`）；文件级 `@Test` 函数名在所有测试文件里唯一

### Testing Requirements
```bash
# Xcode 中运行
xcodebuild test -scheme Termi -destination 'platform=macOS'
```

### Common Patterns
- 安全相关测试（CryptoService）验证加密/解密往返正确性
- DB 测试验证迁移版本和 CRUD 操作
- 解析测试（MonitorParsing）使用固定输入字符串验证解析结果

## Dependencies

### Internal
- 测试目标依赖 `Termi` 主 target 的所有源文件

<!-- MANUAL: -->
