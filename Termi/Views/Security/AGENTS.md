<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Views/Security

## Purpose
锁屏和主密码设置。锁屏在应用锁定时盖住整个窗口（不透明），输入主密码后解除。

## Key Files

| File | Description |
|------|-------------|
| `LockScreenView.swift` | `LockScreenView`（锁屏）、`MasterPasswordSetupView`（设置主密码的弹窗，逻辑不在本次重做范围内） |

## 锁屏的构成

- 背景：`.dsStageBackground()` 叠在不透明的 `windowBackgroundColor` 上。**不透桌面**（不用 behind-window 材质 / 非不透明窗口）。
- App 图标 120pt + 强调色柔光；右下角 38pt 圆形玻璃徽标（`.dsGlass(.circle)`）里是 `lock.fill`，解锁成功瞬间换成 `lock.open.fill`，密码错误时弹一下。
- 名称 30pt 粗体；下面一行：这个窗口有已连接的 SSH 会话时是「绿点 + N 个会话仍在后台保持连接」（只有数量，不显示主机名），否则是「输入主密码解锁」。数量来自 `@Environment(AppViewModel.self)` 的**可选**形式（`liveSSHSessionCount`）：`WindowRootView` 没把 `AppViewModel` 注入给锁屏时为 0。
- 密码框：一个 300×46 的玻璃胶囊（`.dsGlass(.capsule)` + 强调色环），里面是钥匙字形、`ASCIISecureField(isBezeled: false)`、圆形提交按钮。提交按钮是**强调色实心圆**而不是带 tint 的玻璃：玻璃叠玻璃会丢掉 tint。空或验证中禁用；验证中换成 `ProgressView`。Return 提交。
- 大写锁定：`CapsLockWatcher`（`NSEvent.addLocalMonitorForEvents(.flagsChanged)`，`onAppear` 装、`onDisappear` 卸）→ 橙色「大写锁定已打开」。提示行和错误行始终占位，出现 / 消失时表单不跳。
- `LeadingSecureFieldAlignment`：`ASCIISecureField` 无边框时文字右对齐（为表单行做的），这里要从左起，所以进窗口后找到所在的 `NSSecureTextField` 把对齐改掉。`ASCIISecureField` 以后有了对齐参数就删掉它。

## For AI Agents

### Working In This Directory
- 锁屏由 `SecurityViewModel.isLocked` 控制，在 `WindowRootView` 里叠在主窗口内容上面；锁定期间页面不构建。
- 不要动：最小尺寸（420×420）、不透明背景、`.toolbar(.hidden, for: .windowToolbar)`、`WindowArrival`（进窗口后才要键盘）、错误抖动（`phaseAnimator`）、无障碍的 modal 标记。
- 没有 Touch ID（不 `import LocalAuthentication`）。
- 仅 DEBUG 的启动参数（截图用）：`-debugLockSessions 3`（会话数那一行）、`-debugLockCaps YES`（大写锁定提示）、`-debugLockTyped YES`（输入框里有内容、提交按钮可用）。

## Dependencies

### Internal
- `ViewModels/SecurityViewModel.swift`、`ViewModels/AppViewModel.swift`（只读 `liveSSHSessionCount`）
- `Views/Shared/ASCIISecureField.swift`
- `Theme/`（`dsGlass`、`dsStageBackground`、`DSStatusDot`）

<!-- MANUAL: -->
