<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-03-02 -->

# App

## Purpose
应用程序入口点和生命周期管理。包含 SwiftUI App 结构体和 AppDelegate，负责初始化全局 ViewModel、配置窗口样式、处理应用级事件。

## Key Files

| File | Description |
|------|-------------|
| `TermiApp.swift` | `@main` App 结构体，配置 WindowGroup、注入根级 ViewModel |
| `AppDelegate.swift` | NSApplicationDelegate，处理菜单栏事件和应用生命周期回调 |

## For AI Agents

### Working In This Directory
- `TermiApp.swift` 是 ViewModel 注入的起点，所有根级 ViewModel 在此创建并通过 `.environment()` 传递
- 窗口样式配置（`.hiddenTitleBar`、`NavigationSplitView` 尺寸）在此设置
- 修改此处会影响整个应用的启动流程

### Common Patterns
```swift
@main
struct TermiApp: App {
    @State private var appVM = AppViewModel()
    var body: some Scene {
        WindowGroup {
            MainWindowView()
                .environment(appVM)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
```

## Dependencies

### Internal
- `ViewModels/AppViewModel.swift` — 全局应用状态
- `Views/MainWindow/MainWindowView.swift` — 根视图

<!-- MANUAL: -->
