# Termi 功能代码审核（2026-10-11）

> 后续修复位于 `codex/fix-review-20261011`。本文件保留审核时的原始问题和证据；修复实现及最新验证结果见 [修复记录](CODE_REVIEW_FIXES_2026-10-11.md)。下面的源码行号对应审核基线。

审核基线：`main` / `cfce6253fda8d4e1c80d789da4fb69aafc8db988`。

本次检查当前实现的功能调用链，通过 Codex CLI 只读交叉复核，并使用 Xcode 构建、现有测试、隔离启动和定向复现验证。确认 12 项问题（P1 4 项、P2 8 项），没有修改业务代码。开始时工作区已有用户修改的 `CLAUDE.md`，`git pull --rebase` 因工作区未暂存变更被拒绝，因此结论针对本地基线，不代表远端最新状态。

## 问题总览

P1：建议发布前修复，可能操作错误目标或损坏数据。P2：具体功能缺陷，应安排修复。各项列明验证方式；代码链确认不等于真实服务器端到端验收。

| 编号 | 优先级 | 问题 | 验证方式 |
| --- | --- | --- | --- |
| F1 | P1 | SFTP 并发连接后，显示主机与实际会话可能不一致 | 生产连接方法 + 可控异步替身复现 |
| F2 | P1 | 同名上传直接截断远端文件，取消后原件无法恢复 | 原始 SFTPClient + 系统 sftp-server 实测 |
| F3 | P1 | 修改主机地址后，远程编辑可能回写到新服务器 | 核对编辑绑定、重连与轮询上传调用链 |
| F4 | P1 | 加密导入后旧列表不刷新，可能按旧条目删除新主机 | 核对独立窗口、替换快照与按 id 删除调用链 |
| F5 | P2 | 转发规则编辑/删除后，旧隧道继续存在 | 生产管理器 + 命令记录替身复现；核对两条保存路径 |
| F6 | P2 | 用户 ssh_config 中按真实主机匹配的选项不生效 | 原始配置渲染器 + 系统 ssh -G 实测 |
| F7 | P2 | CSV 多行备注被拆成多个记录，回导可能增加错误主机 | 抽取生产 CSV 方法复现 |
| F8 | P2 | CSV 回导忽略 group 列，分组关联丢失 | 对照导出字段、导入字段与 Host 默认值 |
| F9 | P2 | 批量命令失败时丢失 stdout，成功时不保留 stderr | 原始服务和 ProcessRunner + 本机 shell 实测 |
| F10 | P2 | 多个 SSH 等待者全部取消后，共享连接仍继续建立 | 生产管理器 + 可取消连接替身复现 |
| F11 | P2 | 显式选择系统 Agent 仍继承分组身份用户名 | 生产凭据解析方法 + 内存仓库替身复现 |
| F12 | P2 | 显式身份密码失效后，保存的新密码下次不会被使用 | 生产凭据解析方法复现 + 核对保存回调 |

## F1 — SFTP 连接缺少请求代次校验，会把操作发到界面未显示的主机

- 主要位置：[SFTPViewModel.swift:531–570](../Termi/ViewModels/SFTPViewModel.swift#L531)。
- 可达入口：[AppViewModel.swift:718–721](../Termi/ViewModels/AppViewModel.swift#L718)。

`connect(to:)` 在等待 `SFTPSession.open` 前设置 `selectedHost`，完成后直接 `adopt`，没有确认这次请求是否仍然有效。`adopt` 替换底层会话，却不更新 `selectedHost`。SFTP 页的主机选择器虽然在连接中禁用，但主机页/终端的“打开 SFTP”入口会另外创建 Task，绕过该界面限制。

**触发步骤：**先打开连接较慢的 A 的 SFTP；在它完成前，从主机页或另一个终端打开 B 的 SFTP。若 B 先完成、A 后完成，最终标题仍是 B，底层会话却变成 A。此后的上传、重命名、删除会作用于 A。旧请求失败时也会清空新请求的 `selectedHost` 并写入旧错误。

**复现结果：**原样抽取生产 `connect(to:)`，用异步替身让 A 等待 300 ms、B 等待 20 ms，在 A 开始 30 ms 后发起 B：

```text
SFTP selected host = B
SFTP actual session = A
```

这是连接状态方法的确定性复现，不冒充两台真实 SSH 主机的 UI 端到端测试。目录加载已有 `remoteLoadToken`，但该令牌不保护上面的连接完成回调。

**修复方向：**连接请求持有独立代次和可取消 Task；成功、失败、`defer` 发布状态前均校验代次。失效请求取得的会话应关闭。采纳会话时同时更新主机和目录，断开时也使未完成请求失效。

**回归验收：**覆盖 A→B 的两种完成顺序、A 晚失败、连接中关闭窗口；始终断言显示主机等于会话主机，旧请求不会重新采纳会话。

## F2 — 覆盖上传没有冲突确认或失败保护

- 写入位置：[SFTPClient.swift:828–869](../Termi/Services/SFTPClient.swift#L828)。
- 上传入口：[SFTPViewModel.swift:767–770](../Termi/ViewModels/SFTPViewModel.swift#L767)、[SFTPService.swift:319–335](../Termi/Services/SFTPService.swift#L319)。

普通上传直接走到 `openFile(..., flags: [.write, .create, .truncate])`。目标同名文件在第一批内容传完之前就被清空；入口没有同名冲突确认，异常/取消分支也只关闭句柄，没有恢复原件。远程编辑回写同样使用这个上传方法。

**触发步骤：**服务器已有重要文件，在本地选中同名的大文件并上传；开始后取消，或遇到断网/写入失败。旧远端文件已丢失，留下不完整的新文件。即使只是误拖入同名文件，也没有机会选择跳过或改名。

**真实协议复现：**直接编译当前 `SFTPClient.swift`，连接 `/usr/libexec/sftp-server`，文件均位于本次审核的临时目录。目标原本为 23 字节，源文件为 16,000,000 字节；在第一条进度回调取消任务：

```text
UPLOAD result = CancellationError()
Original bytes = 23; remote bytes after cancellation = 1048576
Original preserved = false; new upload complete = false
```

复现只为未使用的 SSH 命令构造和进程退出提供兼容替身，协议、上传实现和服务端均为真实代码。现有下载 `.part` 保护不适用于上传。远程编辑保留本地副本也不能恢复被普通上传覆盖的旧远端版本。

**修复方向：**普通上传先提供替换/跳过/改名选择；传输到远端同目录临时文件，成功关闭并验证后才替换目标。取消或失败只清理临时文件，保留原目标。远程编辑采用同样的失败保护，并明确处理符号链接及权限继承。

**回归验收：**覆盖同名文件取消、断线、磁盘写满，以及上传成功；失败时目标内容保持原样，成功时目标完整，不残留临时文件。

## F3 — 修改主机地址后，待上传的远程编辑可能写入新服务器

- 身份判断：[Host.swift:118–120](../Termi/Models/Host.swift#L118)。
- 保留编辑：[SFTPViewModel.swift:544](../Termi/ViewModels/SFTPViewModel.swift#L544)。
- 自动回写：[SFTPViewModel.swift:1238–1272](../Termi/ViewModels/SFTPViewModel.swift#L1238)。

远程编辑项只绑定 `host.connectionKey`，已保存主机的这个值是数据库 id，不包含地址、端口、用户或跳板链。重连是否保留编辑项、每秒轮询是否允许上传，都只比较这个 key。

**触发步骤：**打开 A 上的远程文件编辑；连接中断后在本地保存修改；把同一主机记录的地址改成 B，再打开 SFTP。两个连接的 key 都是 `host-<相同 id>`，所以旧编辑项被保留，随后上传到 B 的相同路径，可能覆盖 B 的文件或泄露 A 的内容。

**代码链核对：**初次下载后的 `self.session === session` 校验只防止下载期间切换会话；它不保护断线后的重连。`startWatching` 持续每秒调用 `uploadIfChanged`，后者以相同 connectionKey 放行，并直接使用当前 session 上传。这是独立于 F1 并发竞态的另一条错误目标路径。本项未做双服务器端到端复现。

**修复方向：**编辑项绑定开始编辑时实际解析出的端点、登录用户和跳板路径；目标变化后保留本地副本，停止自动回写并明确告知用户。数据库记录 id 不能独自证明远端目标未变。

**回归验收：**断线编辑后，分别修改地址、端口、用户名、分组身份及跳板机再连接；新目标不应收到旧文件。同一真实目标重连仍应续传。

## F4 — 加密导入后仍显示旧主机，删除旧条目可能删掉导入的新主机

- 导入完成：[SettingsViewModel.swift:315–321](../Termi/ViewModels/SettingsViewModel.swift#L315)。
- 替换快照：[SyncService.swift:309–317](../Termi/Services/SyncService.swift#L309)。
- 删除行为：[HostsViewModel.swift:538–545](../Termi/ViewModels/HostsViewModel.swift#L538)。

加密导入会整体替换数据库，主机沿用导入文件中的 id。导入完成只设置结果文字，没有发布 `.dsDataChanged` 或使现有窗口缓存失效。设置是独立窗口，底下仍挂载的主机页不会重新执行 `.task`，继续显示旧 `hosts` 数组。

**触发步骤：**主窗口停在主机列表，里面有 A（id=1）；打开设置并导入另一份快照，其中 B 的 id=1。导入后直接回到仍显示 A 的主窗口，在刷新前删除 A。确认框依据旧对象显示 A，但删除服务仅按 id 操作，实际删除 B 及其关联历史、转发规则和保存密码。

**代码链核对：**`TermiApp` 的 Settings scene 与主窗口分开；主列表在出现时或收到数据通知时加载；`SettingsView` 的导入结果回调仅检查主密码，不刷新主列表；删除方法没有数据代次校验。导入前虽保留数据库备份，但不能阻止随后对新数据的误操作。本项依据调用链验证，未在 UI 中执行破坏性导入。

**修复方向：**成功替换快照后统一更新数据代次，使所有窗口的缓存、选择和编辑草稿失效，再重新加载；任何持有旧对象的写操作都应拒绝或要求重新确认。同步处理仍持有旧主机配置的会话。

**回归验收：**两个窗口同时显示 A，导入含同 id 的 B；所有窗口及时显示 B，导入前打开的删除确认/编辑表单不能再对 B 提交旧操作。

## F5 — 转发规则的持久化内容和正在运行的隧道脱节

- 保存位置：[PortForwardViewModel.swift:47–53](../Termi/ViewModels/PortForwardViewModel.swift#L47)。
- 停止位置：[PortForwardManager.swift:84–96](../Termi/Services/PortForwardManager.swift#L84)。
- 主机表单保存路径：[HostsViewModel.swift:512–522](../Termi/ViewModels/HostsViewModel.swift#L512)。

编辑运行中规则只更新数据库；运行管理器按规则 id 保存状态，却没有保存启动时的 `SSHForward`。编辑后界面显示新端口“运行中”，实际仍是旧端口。随后停止时，管理器用**编辑后的参数**发 `-O cancel`，清空状态并忽略取消错误，旧规则仍在主连接里。

**触发步骤：**保持该主机的终端打开，启动本地 `18080→80` 隧道；编辑为 `18081→80` 并保存；关闭规则开关。界面显示已停止，旧的 18080 隧道仍可使用。保留终端的前提很重要：它让主连接继续存在，不会在最后一个租约释放后的空闲超时被关闭。

**替身复现结果：**编译原始 `PortForwardManager.swift` 与 `SSHConnectionSpec.swift`，替身主连接记录添加/取消参数：

```text
Edited rule shown running = true
After Stop: shown running = false
Master still has original tunnel = true
```

另一路径也有同类问题：在“编辑主机”的表单里删转发规则后保存，`HostsViewModel.store` 直接删数据库行，没有停止隧道。端口转发页自己的 Delete 路径会先 `stop`，不能据此推断主机表单也已处理。

**修复方向：**管理器保存启动时的完整规则快照；编辑/删除通过统一服务先用旧参数停止，再更新持久数据，按产品约定决定是否重启。取消失败时保留可见的失败状态和停止入口。

**回归验收：**实际监听端口和 UI 状态一起核对；覆盖修改监听端口、目标、类型，以及两处删除入口。

## F6 — “应用 ~/.ssh/config 选项”无法匹配按真实主机配置的 Host 块

- 配置位置：[SSHConfigRenderer.swift:107–111](../Termi/Services/SSH/SSHConfigRenderer.swift#L107)。
- 命令位置：[SSHMasterConnection.swift:632–654](../Termi/Services/SSH/SSHMasterConnection.swift#L632)。

应用用 `termi-h0` 等内部别名调用 ssh，只在生成配置尾部 Include 用户配置。用户的 `Host legacy.example` 因匹配对象变成内部别名而不生效；`Host *` 可生效，不能证明主机专属配置生效。给旧设备配置的算法例外因此可能失效，导致命令行能连、应用不能连。

**实测：**在临时配置中写入以下内容，以原始渲染器生成应用配置，再用 `/usr/bin/ssh -G -F ...` 比较，无网络连接、无修改用户 `~/.ssh/config`：

```sshconfig
Host legacy.example
  Ciphers aes256-ctr
```

```text
direct: ciphers aes256-ctr
Termi: ciphers chacha20-poly1305@openssh.com,aes128-gcm@openssh.com,aes256-gcm@openssh.com,aes128-ctr,aes192-ctr,aes256-ctr
```

**修复方向：**按原始主机名/导入别名求出用户配置的有效选项，再把允许继承的选项带入私有 Host 块，保持应用对认证、主机密钥和连接复用选项的控制。不要要求用户写应用内部别名来绕过问题。

**回归验收：**以 `ssh -G` 对照 Host 精确匹配、通配模式、Include 和跳板机各自的算法选项。

## F7 — 应用导出的多行 CSV 备注无法正确回导

- 主要位置：[ImportExportService.swift:51–71](../Termi/Services/ImportExportService.swift#L51)。
- 字段解析：[ImportExportService.swift:309–340](../Termi/Services/ImportExportService.swift#L309)。

导出器会给含换行的字段加引号，但导入器先 `components(separatedBy: .newlines)`，随后每行重置 CSV 引号状态。合法字段中的换行因此被当成记录边界。

**触发步骤：**建立一台备注包含多行文字的主机，导出 CSV 后回导。备注只剩第一行；若后续行有逗号，可能被误识别成另一台主机。

**复现：**原样抽取生产 `escapeCSV` / `parseCSVLine` 方法，并按生产导入的分行规则执行。一个主机的备注为 `first line\nextra,wrong.example,22,root,password,,unexpected`：

```text
CSV logical host count = 1
IMPORTED host=original.example, notes=first line
IMPORTED host=wrong.example, notes=unexpected
```

**修复方向：**按整个文件解析带引号的逻辑记录，覆盖 CRLF、换行、转义双引号；先解析和校验，再整体写入，避免部分导入被报告成完整成功。

**回归验收：**应用自身导出的单行/多行备注回导后内容完全相同，不增加主机；覆盖逗号、空行、双引号组合。

## F8 — CSV 回导完全忽略 group 列，分组与继承关系丢失

- 导出字段：[ImportExportService.swift:15–35](../Termi/Services/ImportExportService.swift#L15)。
- 导入字段：[ImportExportService.swift:59–90](../Termi/Services/ImportExportService.swift#L59)。

导出文件和用户指南都列出 `group` 列，但导入器没有读取这一列，也没有给新建 Host 赋 `groupId`。即使 CSV 只有单行普通字段，原来有分组的主机回导后仍全部落入“未分组”；依赖分组默认用户名、身份或跳板机的主机还会失去连接所需的上下文。

**触发步骤：**建立 `Production` 分组并放入一台主机，导出 CSV；回导到仍有同名分组的配置中。新导入记录的 `groupId` 仍为 nil，而不是现有分组的 id。

**代码链核对：**导出使用 `groupMap` 把 groupId 转为名称；导入的表头索引只有 label/hostname/port/username/auth/notes，随后从 `Host.defaultValue()` 构建并保存，完全未处理 group。这与 F7 的多行解析错误相互独立，未做 UI 回导实测。

**修复方向：**解析 group 列并关联已有分组；对不存在的分组定义创建或提示策略。CSV 不包含分组凭据时应说明限制，但不能静默丢弃已有分组的关联。

**回归验收：**普通分组、空分组名、带逗号/引号的分组名导出回导后关联正确；同名已有分组不重复创建。

## F9 — 批量命令的关键输出在失败时被丢弃

- 主要位置：[BatchCommandService.swift:29–45](../Termi/Services/BatchCommandService.swift#L29)、[56–64](../Termi/Services/BatchCommandService.swift#L56)。

`ProcessRunner` 已收集 stdout、stderr 和真实退出码，但批量服务在非零退出时直接抛错，只保留 stderr 或退出码文本；外层生成 `output: ""`。因此检查脚本或部署命令把诊断写到 stdout 后返回失败时，用户只看到失败码，看不到具体原因。成功分支仅返回 stdout，stderr 中的警告也不会进入结果。

**实测：**编译原始 `BatchCommandService.swift` 与 `ProcessRunner.swift`，仅把 SSH 传输替换为本机 `/bin/sh`，执行打印 `FAILED CHECK: disk pressure` 后 `exit 7` 的命令：

```text
Batch stdout = ""
Batch error = Command failed: Exit code 7; exitCode = -1
```

**修复方向：**保留进程完整结果；非零退出属于一条带失败状态的执行结果，不应在构造结果前丢弃已收集的输出。UI 同时展示诊断和失败状态。

**回归验收：**覆盖非零退出且只有 stdout、stdout/stderr 都有内容，以及零退出但 stderr 有警告三种情况。

## F10 — 多个 SSH 等待者全部取消后，共享连接仍继续建立

- 计数位置：[SSHConnectionManager.swift:90–102](../Termi/Services/SSH/SSHConnectionManager.swift#L90)。
- 取消逻辑：[SSHConnectionManager.swift:192–197](../Termi/Services/SSH/SSHConnectionManager.swift#L192)。
- UI 入口：[TerminalSession.swift:316–332](../Termi/ViewModels/TerminalSession.swift#L316)。

同一连接有两个等待者时，取消回调仍看到 `waiters == 2`，因 `waiters <= 1` 才会取消底层任务，两次回调都不执行取消。等待者数量只有等 `task.value` 返回后才递减，因此形成必须先连接结束才能解除等待的状态。

**触发步骤：**两处终端同时连接同一主机，在握手或认证完成前全部取消/关闭。界面可以已显示取消或移除窗格，底层连接仍在继续，可能继续发起认证提示；取消的调用者也不能及时返回。

**确定性复现：**编译原始 `SSHConnectionManager.swift` 与 `SSHConnectionSpec.swift`，主连接替身以可取消的异步等待模拟未完成握手；两个 acquire 都进入后一起取消：

```text
Shared connection attempts = 1
After cancelling both: underlying attempt cancelled = false
After cancelling both: waiters returned = 0
After shutdown: underlying attempt cancelled = true
```

**修复方向：**为每个等待者登记独立标识，取消时立即且仅一次减少有效等待者；最后一个等待者离开且无租约时取消共享任务。完成/异常收尾不能重复减计数。

**回归验收：**覆盖两个等待者依次取消、同时取消、一个取消而另一个成功、取消与成功竞争；无用户等待时底层任务及时结束，仍有用户时不误断连接。

## F11 — 主机显式选择系统 Agent，仍被分组身份改写登录用户名

- 表单保存：[HostFormView.swift:697–713](../Termi/Views/Hosts/HostFormView.swift#L697)。
- 身份解析：[SSHService.swift:141–163](../Termi/Services/SSH/SSHService.swift#L141)。

主机选择系统 Agent 后会保存 `authType = "agent"`、清空 privateKeyId，并保留用户填写的用户名。但解析分组身份时只检查主机私钥和已保存密码，没有把显式 Agent 视为自己的认证配置；后续身份用户名又优先于主机用户名。

**触发步骤：**分组默认身份使用 `root`；组内主机明确填写 `deploy`、选择系统 Agent，没有主机密码或私钥。实际连接尝试使用 root，而不是 deploy，可能认证失败，也可能进入非预期账号。

**定向复现：**原样抽取生产 `hop(for:...)` 方法，使用内存仓库/保险库替身和真实 `SSHConnectionSpec.swift`：

```text
Explicit agent: configured username = deploy; resolved username = root
Explicit agent: useSystemAgent = true
```

**修复方向：**把显式 Agent 视作主机自己的认证配置，避免继承分组身份；同时明确主机用户名与分组默认值的优先级。不要只修改最后的 useSystemAgent 标志。

**回归验收：**分组含密码身份/密钥身份时，显式 Agent 主机按自己的用户名连接；未配置身份的主机继续正确继承。

## F12 — 显式身份的旧密码优先级高于刚保存的新密码，重复连接仍失败

- 读取顺序：[SSHService.swift:181–196](../Termi/Services/SSH/SSHService.swift#L181)。
- 提示保存：[SSHMasterConnection.swift:468–473](../Termi/Services/SSH/SSHMasterConnection.swift#L468)。
- 保存目标：[SSHMasterConnection.swift:613–615](../Termi/Services/SSH/SSHMasterConnection.swift#L613)、[SSHService.swift:75–76](../Termi/Services/SSH/SSHService.swift#L75)。

主机显式绑定一个有密码的身份时，身份旧密码失败后仍会提供“保存到保险库”。认证成功后保存回调只更新 hostId 对应的主机密码；下一次创建主连接时，却仍先读取 `identity.passwordEncrypted`，忽略刚保存的主机密码。

**触发步骤：**服务器改了密码，主机使用的显式身份仍留着旧密码；认证提示中输入新密码并勾选保存。断开到旧 SSH 主连接已销毁后再连接，旧密码又被尝试，用户需反复输入新密码。共享连接复用时可能暂时掩盖此问题。

**定向复现：**同 F11 的生产解析方法，模拟保存回调写入新的主机密码后重新解析：

```text
Explicit identity: prompt can save host password = true
Explicit identity: next resolved password uses newly saved value = false
Explicit identity: next resolved password still uses old identity value = true
```

这里验证的是凭据选择与保存目标，不是实际 SSH 服务端认证；“分组继承身份不允许保存”的现有保护不覆盖显式身份。

**修复方向：**保存时记录凭据实际所有者，更新对应身份，或提供清晰且优先级正确的主机覆盖凭据。界面的保存承诺要与下次解析行为一致。

**回归验收：**显式身份旧密码失败→新密码保存→销毁主连接→重新连接，全程只在第一次要求新密码；同时验证共享身份影响范围与无密码身份的主机保存回退。

## 验证记录与边界

- 本机工具链：Xcode 27.0（27A266a），macOS 27.0.1，Apple Silicon。
- `xcodebuild test`：541 项测试通过，0 失败、0 跳过；参数化测试展开后的执行次数为 554。
- `xcodebuild build -configuration Release`：构建成功（arm64 / x86_64）。
- 中文词条检查：956 个词条，缺失 zh-Hans 0，过期 0。
- Debug App 隔离启动：本地 zsh 正常运行；新建左右分屏成功；切到主机页再回到终端，两个窗格仍在；已退出审核实例。
- 测试和运行数据放在临时目录；未使用真实主机、真实凭据或用户正式数据库。
- 定向复现中，F2/F6 使用真实系统协议程序；F1/F5/F10 使用确定性的异步/连接替身；F7 抽取生产 CSV 方法；F9 使用本机 shell 替代网络传输；F11/F12 使用生产解析方法和内存仓库。F3/F4/F8 经代码链核对，未做对应的真实服务器或 UI 端到端复现。不能把这些结果当作所有 SSH 服务端的兼容性验收。
- 未进行跨主机真实 SSH 密码/密钥/2FA 全矩阵、拖放、长时间弱网、休眠唤醒、VoiceOver 和 macOS 15/Xcode 16.2 的本次验收。

本次主要命令：

```sh
xcodebuild test -project Termi.xcodeproj -scheme Termi \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Debug \
  -resultBundlePath /tmp/termi-audit-20261011/baseline.xcresult

xcodebuild build -project Termi.xcodeproj -scheme Termi \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData-Debug -disableAutomaticPackageResolution

python3 scripts/check-strings.py \
  Termi/Localizable.xcstrings build/DerivedData-Debug Termi

open -n --env TERMI_PROFILE_DIR=/tmp/termi-audit-20261011/app-profile \
  build/DerivedData-Debug/Build/Products/Debug/Termi.app \
  --args -debugConnect local -debugWindowSize 1200x800
```

原始构建/测试日志、复现驱动和结果位于本机 `/tmp/termi-audit-20261011/`；临时目录可能被系统清理，关键结果已摘录在本报告中。修复上述问题后，应增加针对性回归测试并重新做真实构建与隔离验收；现有测试通过不能证明上述场景已被覆盖。
