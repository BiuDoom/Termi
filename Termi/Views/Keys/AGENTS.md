<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/Keys

## Purpose
保险库的两页：密钥库（生成 / 导入 / 安装公钥 / 删除）和已知主机（首次连接时信任的主机密钥）。第三页「身份」在 `Views/Hosts/IdentitiesView.swift`，用的是同一套零件。三页都是骨架 A（`DSMasterDetail`），指纹图（`DSRandomart`）是主角。

## Key Files

| File | Description |
|------|-------------|
| `KeyManagementView.swift` | 密钥库：主栏按「在用 / 未使用」分区（每行是指纹图 + 名称 + 类型 + 使用它的主机）；详情 = 头部（安装到主机… 是本页唯一的主操作）+ 指纹卡 + 公钥卡 +「使用这把密钥的」。文件后半是三个弹窗（生成 / 导入 / 安装公钥）。**保险库三页共用的零件也在这里**：`VaultHeroCard`、`VaultFingerprintColumn`（指纹正文 + 行尾拷贝 + 一句说明，没有数字行）、`VaultPublicKeyCard`、`VaultHostLink`、`VaultErrorBanner`。主栏底部不放常驻脚注：「私钥只保存在本机」在生成 / 导入弹窗的 footer（`KeyVaultNote`）；窗口副标题只在搜索时写「N 条匹配」；拷贝只在卡片上，详情头的「…」只放删除 |
| `KnownHostsView.swift` | 已知主机：主栏按主机密钥分组（同一指纹 = 同一台机器），行 = 对应的已保存主机 + 地址；详情 = 指纹卡 + 同一把密钥的其它地址 + 对应的已保存主机 + 公钥。工具栏 `⋯`：移除没有对应主机的条目…（确认框逐条列出地址）、全部移除 |

## For AI Agents

### Working In This Directory
- 谁在用哪把密钥 / 哪个身份的判断在 `VaultUsage`（`ViewModels/KeysViewModel.swift`），规则与 `SSHService` 一致：主机自己的身份优先，其次分组的默认身份（主机自带密钥时不沿用）；有身份时用身份的密钥。改规则两边一起改，单测在 `RedesignWP3Tests`。
- 密钥强度（`KeyStrength`）只从类型和公钥读，读不出就不显示，不猜。
- 指纹卡（`VaultHeroCard`）是每页唯一的 `hero` 卡；它用 `ViewThatFits` 在「图在左」和「图在上」之间切换，右栏必须给 `idealWidth`，否则按指纹的单行宽度量，永远放不下。
- 指纹和公钥显示时在字符间插了零宽空格（`VaultText.breakable`）好让它们填满一行，**拷贝一律拷原文**（拷贝按钮），不要给这两处加 `textSelection`。
- 「移除没有对应主机的条目」只在已保存主机读完之后可用（否则每一条都像孤儿），并且删的就是确认框里列出的那几条（`orphansToDelete`），按 id 逐个删。
- 密钥私钥内容存储在 `SecureStoreService`，视图层只显示公钥和指纹；「有口令」只看保险库里有没有存这把密钥的口令。
- DEBUG 启动参数：`-debugVaultSelect <密钥名 | 身份名 | host:port>` 选中一条；`-debugVaultSample YES` 让身份页显示两条样例身份（不写库）；`-debugHostKeyPrompt new|changed`（在已知主机页）弹出主机指纹弹窗。

## Dependencies

### Internal
- `ViewModels/KeysViewModel.swift`（含 `VaultUsage` / `KeyStrength` / `VaultText`）
- `ViewModels/KnownHostsViewModel.swift`
- `Services/SSHKeyGenerator.swift`
- `Theme/`（`DSMasterDetail`、`DSRandomart`、`DSDetailHeader`、`DSGroup`、`DSLinkRow`…）

<!-- MANUAL: -->
