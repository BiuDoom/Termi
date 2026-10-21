<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Resources

## Purpose
应用资源文件，包含图标资产、权限配置和应用元数据。

## Key Files

| File | Description |
|------|-------------|
| `Assets.xcassets` | 应用图标（AppIcon）和颜色资产 |
| `Termi.entitlements` | Hardened Runtime 权限配置（无 App Sandbox） |
| `Info.plist` | 应用元数据（Bundle ID、版本号、权限描述） |

## For AI Agents

### Working In This Directory
- `Termi.entitlements` 中 `ENABLE_APP_SANDBOX` 必须为 `NO`（pty 需要 `tcsetpgrp()`）
- 修改权限时注意 Hardened Runtime 约束
- 图标资产通过 Xcode Asset Catalog 管理，不直接编辑 `.xcassets` 目录内部文件

### Common Patterns
- Hardened Runtime 已启用：`com.apple.security.cs.allow-unsigned-executable-memory` 用于 SSH pty
- 网络访问权限已配置（SSH 连接需要）

<!-- MANUAL: -->
