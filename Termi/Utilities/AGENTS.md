<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# Utilities

## Purpose
通用工具扩展和辅助函数，被多个层次复用。保持轻量，不引入业务逻辑依赖。

## Key Files

| File | Description |
|------|-------------|
| `Array+Safe.swift` | `Array` 安全下标扩展（`array[safe: index]`，越界返回 nil） |
| `DateFormatting.swift` | 日期格式化工具（相对时间、ISO 8601、显示格式） |

## For AI Agents

### Working In This Directory
- 新增工具时保持纯函数风格，无副作用
- 扩展命名遵循 Swift 规范：`TypeName+FeatureName.swift`
- 避免引入 Services 或 ViewModels 的依赖（保持最低依赖）

### Testing Requirements
- `TermiTests/UtilityTests.swift` 覆盖工具函数测试

<!-- MANUAL: -->
