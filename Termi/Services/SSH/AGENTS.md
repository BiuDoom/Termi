<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-04 -->

# Services/SSH

## Purpose
SSH 引擎：基于系统 OpenSSH（`/usr/bin/ssh`），用 **ControlMaster 连接复用** 实现 Termius 式"每台主机一条连接"——终端标签/分屏、SFTP、端口转发、远程命令都复用同一条主连接，认证只需一次。认证交互（密码、私钥口令、键盘交互/2FA、主机指纹确认）通过 **askpass 桥** 回到 App 弹窗。不使用第三方 SSH 库。

## Key Files

| File | Description |
|------|-------------|
| `SSHConnectionSpec.swift` | 连接描述：`SSHConnectionSpec`（跳板链 `hops`、超时、keepalive、可选用户 ssh_config）、`SSHHop`、`SSHCredentials`、`SSHForward`、`SSHPrompt`/`SSHPromptResponse`、`SSHError`；`validate()` 防止注入 |
| `SSHConfigRenderer.swift` | 为每条连接生成私有 ssh_config（`-F`）：每个 hop 一个 `Host termi-hN` 块（HostKeyAlias、ProxyJump 链、IdentityFile），目标 hop 带 ControlPath；专用 known_hosts；可选末尾 `Include ~/.ssh/config` |
| `SSHAskpass.swift` | Askpass 桥：App 可执行文件在 `TERMI_ASKPASS=1` 时作为 `SSH_ASKPASS` 运行（`AskpassClient`，见 `App/main.swift`），经 0600 Unix socket 把提示发给 App 内的 `AskpassServer`；`SSHPromptParser` 识别 OpenSSH 的各类提示 |
| `SSHRuntime.swift` | 运行时目录 `<tmp>/bmt-<pid>`（0700）、askpass socket、App 私有 ssh-agent（用于代理转发）、进程终止（SIGTERM→SIGKILL）、启动时清理上次残留 |
| `SSHMasterConnection.swift` | 一条主连接：`ssh -M -N` 启动并等待 control socket 出现、回答提示、保存用户选择保存的密码/口令/主机密钥、`-O exit/forward/cancel`；生成交互终端 / exec / sftp 子进程命令（`Command`） |
| `SSHConnectionManager.swift` | actor：按"主机 key + spec 指纹"单飞（single-flight）复用主连接；`Lease` 引用计数（按主连接代次计数：旧主连接的租约释放不会影响重连后的新主连接），最后一个租约释放后空闲 20 秒关闭 |
| `SSHService.swift` | 对外门面（actor，`SSHService.shared`）：从数据库组装 spec（主机 → 身份 → 分组默认值、跳板链、密钥、已存密码、已知主机）；`connect(to:password:) -> Lease`、`run(_:on:)`、`disconnect`、`shutdown` |

## For AI Agents

### Working In This Directory
- 所有 SSH 功能先通过 `SSHService.shared.connect(to:)` 取得 `Lease`，再用 `lease.master.interactiveCommand(...)` / `execCommand(_:)` / `sftpCommand()` / `addForward(_:)`；**不要**自己拼 `ssh user@host`
- 持有 `Lease` 期间主连接保持；`release()`（或租约析构）后空闲超时关闭
- 用户可控的值（主机名、用户名）必须经过 `SSHConnectionSpec.validate()`；写入 ssh_config 的新字段用 `SSHConfigRenderer.quote` / `escapeTokens`
- 密码/口令只通过 askpass socket 按需回答，绝不出现在命令行或环境变量里；私钥以 0600 临时文件交给 ssh，连接建立后立即删除
- 主机指纹：首次连接弹窗确认（TOFU），信任后写入 `KnownHostRepository`——即使随后认证失败或被取消也保留（进程退出前对私有 known_hosts 做快照）；指纹变更直接拒绝（`SSHError.hostKeyChanged`）
- `SSHMasterConnection.close()` 对已连接的主连接立即回调 `onClose` 且 `isAlive` 立即为 false，不等 ssh 进程退出
- 经 ProxyJump 的 hop 的 `ConnectTimeout` 至少 120 秒（要留出跳板机人工认证的时间）；Apple 平台上每个 Host 块写 `UseKeychain no`
- 「保存到保险库」以最后一次回答为准（先输错并勾选、再输对不勾选 → 不保存）
- 本目录只依赖 Foundation（`#if canImport(Darwin)` / `Glibc`），可以在 Linux 上编译并对真实 sshd 做集成测试
- **禁止** App Sandbox；**禁止** macOS Keychain（不得 `import Security`）

### Common Patterns
```swift
// 取得（或复用）主机的主连接
let lease = try await SSHService.shared.connect(to: host)
defer { lease.release() }

// 交互式终端：把命令交给 SwiftTerm 的 LocalProcess 启动
let command = lease.master.interactiveCommand(forwardX11: host.x11Forwarding)

// 在主机上执行一条命令（内部复用同一条主连接）
let result = try await SSHService.shared.run("uptime", on: host)
```

### Testing Requirements
- `TermiTests/SSHEngineTests.swift`：提示解析（含 OpenSSH 10 的指纹格式）、ssh_config 渲染、known_hosts、注入校验、失败分类、转发参数，以及用脚本冒充 `ssh` 的主连接/租约行为（失败后保留已信任指纹、关闭回调、代次计数）
- 与真实 OpenSSH sshd 的集成测试（密码/密钥/口令、跳板链、主机密钥信任/拒绝/变更、端口转发、代理转发、SFTP）在 Linux 上用独立测试包运行

## Dependencies

### Internal
- `Services/ProcessRunner.swift` — 执行 `ssh -O`、远程命令
- `Services/SecureStoreService.swift` — 读取/保存密码、口令、私钥
- `Repositories/KnownHostRepository.swift`、`HostRepository`、`GroupRepository`、`IdentityRepository`、`SSHKeyRepository`
- `Views/Shared/AuthPromptPresenter.swift` — 认证提示弹窗

<!-- MANUAL: -->
