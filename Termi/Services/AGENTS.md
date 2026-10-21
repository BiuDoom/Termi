<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-09-26 -->

# Services

## Purpose
业务逻辑层，封装所有与外部系统交互或复杂计算的服务。包含 SSH 连接、文件传输、加密存储、进程执行、服务器监控、Docker 管理等核心功能。

## Key Files

| File | Description |
|------|-------------|
| `ProcessRunner.swift` | 通用异步进程执行器（`Process` + pipe），是 SSH/SFTP 的基础 |
| `CryptoService.swift` | AES-256-GCM 加密/解密 + HKDF 密钥派生，纯本地，无外部依赖 |
| `SecureStoreService.swift` | 独立加密保险库（本地文件 + CryptoService），替代 macOS Keychain |
| `SSHKeyGenerator.swift` | SSH 密钥对生成（调用系统 `ssh-keygen`） |
| `SFTPClient.swift` | SFTP v3 协议客户端（`ssh -s sftp` 子系统上的二进制协议，READ/WRITE 流水线） |
| `SFTPService.swift` | `SFTPSession`：在主机的共享主连接上打开 SFTP，列目录、递归上传/下载/删除、重命名、chmod |
| `SSHConfigParser.swift` | 解析 `~/.ssh/config`（Host 模式、Include、ProxyJump、IdentityFile、转发）供导入使用 |
| `PortForwardManager.swift` | 在共享主连接上启动/停止端口转发规则（`ssh -O forward/cancel`），维护运行状态 |
| `HostSystemProbe.swift` | 已保存的主机连上后读一次它的系统：**只发一条只读命令**（`sh -c 'cat /etc/os-release; echo ---; uname -sm' || cmd /c "chcp 65001 >nul & ver"`，没有 `sh` 的 Windows 由同一行的后半句回答），走已有主连接、不认证不弹窗；每主机每次运行至多一次，库里的结果不满 7 天不读；由 `SSHService.connect` 触发，结果经 `HostRepository.setSystem(_:id:at:)` 只写 `os_*` 四列、且仅当主机地址仍是连接时的地址，再发 `.dsDataChanged`。日志只记主机 id，不记系统名和远端输出。设置键 `detectHostSystem`（默认开）。解析在 `Models/HostSystem.swift` |
| `NetworkMonitor.swift` | `NWPathMonitor` + 系统唤醒通知，网络恢复时触发终端自动重连 |
| `BatchCommandService.swift` | 批量在多台主机执行命令，收集输出 |
| `MonitorService.swift` | 服务器资源监控（CPU、内存、磁盘）解析 |
| `DockerService.swift` | Docker 容器/镜像管理（调用远程 docker CLI） |
| `SyncService.swift` | 本地加密导出/导入（不使用 iCloud） |
| `ImportExportService.swift` | 数据导入/导出（CSV、`~/.ssh/config` 导入） |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `SSH/` | SSH 引擎：ControlMaster 主连接复用 + askpass 桥（见 `SSH/AGENTS.md`） |

## For AI Agents

### Working In This Directory
- **安全红线**：`SecureStoreService` 是唯一合法的密钥存储方式，禁止使用 `Security` framework
- SSH/SFTP/端口转发/远程命令都通过 `SSHService.shared` 复用主机的主连接；`ProcessRunner` 用于一次性进程
- `CryptoService` 使用 Apple CryptoKit，无第三方加密库
- 所有 Service 方法应为 `async throws`

### Common Patterns
```swift
// 在主机上执行命令（复用该主机的 SSH 主连接）
let result = try await SSHService.shared.run("uptime", on: host)

// SFTP 会话
let session = try await SFTPSession.open(host: host)

// 加密存储
try SecureStoreService.shared.store(key: "privateKey_\(id)", value: privateKeyPEM)
let pem = try SecureStoreService.shared.retrieve(key: "privateKey_\(id)")
```

### Testing Requirements
- `TermiTests/CryptoServiceTests.swift` — 加密往返测试
- `TermiTests/ProcessRunnerTests.swift` — 进程执行测试
- `TermiTests/MonitorParsingTests.swift` — 监控输出解析测试

## Dependencies

### External
- Apple **CryptoKit** — AES-GCM、HKDF

<!-- MANUAL: -->
