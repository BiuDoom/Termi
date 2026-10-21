<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-05 -->

# Theme

## Purpose
界面的共享层：设计常量、Liquid Glass 包装、内容层组件。页面只用这里的东西拼，不自己发明颜色、圆角、玻璃。方向已定稿（高保真样张 + 用户批注），下面三条是**硬规则**。

## 三条硬规则

1. **玻璃只在控件与导航层**（Apple Liquid Glass, macOS 26）：侧边栏、工具栏项、按钮、浮动条、弹窗、浮层。**内容层不用玻璃**（卡片、行、图表是中性面）。少用；**不叠玻璃**（玻璃面板里面的东西都是内容）；**只有唯一的主操作上色**（`.prominent`）；圆角同心：窗口 26 → 面板 18 → 行 10。
2. **颜色克制**（用户原话：「不要太多颜色，不然看着很杂乱」）：中性表面；**一个强调色**（系统强调色 `DS.Palette.accent`，永远不写死蓝色）用于主操作、选中、数据（图表、进度条、仪表、趋势线）；**绿 / 橙 / 红只表示状态，并且总带一个词或字形**；页面和类别**不按颜色区分**（侧边栏字形、类别方块都是强调色）；唯一自由的颜色是**主机方块**——它带发行版自己的颜色（用户给主机选了颜色时以所选为准）。
3. **数据进固定列**：数字右对齐或共基线、等宽数字（tabular）；单位和标签在固定位置；同一张卡里并排的值之间有一条细分隔线（`DSDividedRow`）；**什么都不换行**。

## 玻璃包装规则（唯一出现玻璃 API 的地方是 `Glass.swift`）

- 页面**永远不直接写** `glassEffect` / `GlassEffectContainer` / `Glass` / `.buttonStyle(.glass / .glassProminent)` / `backgroundExtensionEffect` / `scrollEdgeEffectStyle` / `ToolbarSpacer` / `ConcentricRectangle`。要用就用 `Glass.swift` 里的包装；缺一个就在 `Glass.swift` 里加一个。
- 每个包装都是两层保护：`#if compiler(>=6.2)`（Xcode 16.2 不认识这些符号）**并且** `if #available(macOS 26.0, *)`（部署目标仍是 macOS 15），`#else` 和 `else` 里都有回退（`.regularMaterial` / `.bordered` / `.borderedProminent`）。
- 标准组件（`NavigationSplitView` 侧边栏、`.toolbar`、`.sheet`、系统按钮）用 macOS 26 SDK 构建时由系统给玻璃，不要自己再包一层。

## 工具链规则（同一份源码要过三处）

| 在哪 | 工具链 | 说明 |
|------|--------|------|
| 本机 | Xcode 27 / Swift 6.4 / macOS 27 SDK | 开发、截图 |
| CI「Xcode 26」 | Swift 6.2 / macOS 26 SDK | **发布用** |
| CI「Xcode 16.2」 | Swift 6.0 / macOS 15 SDK，测试跑在 macOS 15 | 兼容性；这里没有玻璃，走回退 |

Swift 6.0 的坑：参数 / 实参列表**不写尾逗号**；`#expect` / `#require` 的闭包里不做枚举模式匹配（放到文件级函数）；不把视图 / ViewModel 的实例方法当函数值传给非 SwiftUI 的 API；`@MainActor` 类型里交给系统框架的闭包标 `@Sendable`；`@Observable` 单例标 `@MainActor`；View 上给测试用的纯函数标 `nonisolated static`；`#if compiler` 之外不用 6.0 之后的语法。macOS 15 之后才有的 API 一律进 `Glass.swift` 的保护块。

## Key Files

| File | Description |
|------|-------------|
| `DesignSystem.swift` | `enum DS`：`Space`（卡片间 10、分区间 16、详情左右 26）、`Radius`（`sidebarRow` 10 · `row` 12 · `card` 16 · `panel` 18 · `sheet` 22）、`Height`（`listRow` 46 · `formRow` 40 · `compactRow` 32 · `control` 32 · `smallControl` 26 · `chip` 22 · `hop` 34）、`Font`（13 正文 · 11–12 说明 · 18 页面标题 · 26 详情标题与数字，数字等宽）、`Motion`、`Tone`（数据和状态能用的五种颜色角色：`accent` / `success` / `warning` / `danger` / `inactive`；`Tone.level(percent:)` 水位 → 强调色 / ≥60 橙 / ≥85 红）、`Palette`（`accent`、状态色、`card` / `cardRaised` / `hairline` / `separator` / `chip` / `terminal`；`category(_:)` 一律返回强调色）、`Layout`、`Tile`（16 · 20 · 30 · 38 · 48 · 64） |
| `Glass.swift` | 玻璃包装：`dsGlass`、`DSGlassContainer`、`dsButtonStyle`、`DSGlassIconButton`、`DSGlassIconMenu`、`dsFloatingBar`、`dsFloatingPanel`、`DSFilterChip` |
| `Tiles.swift` | `DSIconTile`、`DSCategoryTile`、`DSOperatingSystem`（发行版 → 名称 / 方块颜色 / 标记的**唯一**查表）、`DSHostAvatar`、`DSHostStack`、`DSSidebarLabel`、`Host.displayName / operatingSystem / tint / tileContent`、`SidebarItem.glyph / tileSymbol` |
| `DataCards.swift` | `DSStatCard`、`DSCardLabel`、`DSStatGrid`、`DSGaugeCard`、`DSDividedRow`、`DSValueCell`、`DSSectionHeader`、`DSGroup`、`DSRow`、`DSKeyValueRow`、`DSKeyLabel` / `.dsKeyColumn(fitting:)`、`DSLinkRow`、`DSStatLead`；环境值 `\.dsTint`、`\.dsFillsRowHeight` |
| `Charts.swift` | `DSMeter`、`DSDayStrip`、`DSSparkline`、`DSArcGauge`、`DSSegmentBar`、`DSLogStats`、`DSActivityChart`、`DSActivityLegend` |
| `Components.swift` | `DSStatusDot`、`DSChip`、`DSStatusPill`、`.dsCard()`、`.dsHoverTracking()`、`DSRowButton`、`DSCopyButton`、`DSMessage`、`DSShortcut`、`DSSheetTitle`、`DSDelayed`、`DSRelativeTime`、`DSHostRow`、`DSHostPickerGrid`、骨架（`DSMasterDetail`、`DSMasterList`、`DSListSectionHeader`、`.dsListRow()`、`.dsCenteredColumn()`、`.dsStageBackground()`、`DSDetailHeader`、`DSFlow`、`DSEmptyState`）、`DSRouteDiagram`、`Randomart` / `DSRandomart`、`DSCodeBlock`、`DSThemeSwatches`、`DSReveal` |
| `DesignGallery.swift` | 仅 DEBUG：`DSGalleryView`，全部组件配示例数据，按样张的版式摆。`-debugSheet gallery -debugGalleryPage 1…5 [-debugGalleryScroll <pt>]`（1 方块与玻璃 · 2 主机详情 · 3 仪表与并排数值 · 4 主列表 / 指纹 / 行 · 5 骨架与其它）。改组件后在深色 / 浅色 / 900×600 下各截一遍，和样张并排看 |

外观（浅色 / 深色 / 跟随系统）不在这里：`WindowRootView` 和 `SettingsView` 按设置项用 `.preferredColorScheme` 应用。终端配色是 `Models/TerminalTheme.swift`。

## 组件表

### 玻璃（控件层）

| 组件 | 用途 |
|------|------|
| `.dsGlass(_:tint:isInteractive:)` | 自定义玻璃面（胶囊 / 圆 / 圆角矩形）；`tint` 只给主操作 |
| `DSGlassContainer` | 把挨在一起的玻璃形状编成一组（否则各画各的） |
| `.dsButtonStyle(.prominent / .glass, size:)` | 按钮：一屏只有一个 `.prominent`；`size: .small` 用在卡片和条里 |
| `DSGlassIconButton` | 只有图标的圆形玻璃按钮（更多、刷新），自带 help 和无障碍标签 |
| `DSGlassIconMenu` | 同样的圆形玻璃按钮，点开是菜单（`⋯`）；页面不要再自己拼 `Menu + .buttonStyle(.plain) + dsGlass` |
| `.dsFloatingBar(_:)` | 浮动条：会话标签栏、终端状态条、SFTP 传输条、选中操作条 |
| `.dsFloatingPanel(cornerRadius:)` | 浮动面板：命令面板、终端上的状态卡片 |

坑：`dsGlass(tint:)` 套在另一块玻璃里面时 tint 画不出来（灰的）——本来也不该叠玻璃；需要强调色的小圆钮在玻璃里用实色。
| `DSFilterChip` | 工具栏下的筛选：玻璃胶囊，选中的那个反色 |

### 方块

| 组件 | 用途 |
|------|------|
| `DSIconTile` | 圆角方块：左上受光的渐变 + 细高光，36pt 起带自身颜色的柔光；白色标记（符号 / 资源图 / 首字母）。`monogram(for:letters:)`：默认两个字母，身份方块用 `letters: 1` |
| `DSCategoryTile` | 记录头部和空状态的方块：强调色 + 白字形 |
| `DSOperatingSystem` | 发行版查表：`HostSystem.ids` 里每个 id 一项（名称、方块颜色、`Assets.xcassets/OS/` 里的标记，Simple Icons CC0）；没有自己标记的发行版（麒麟 / openEuler / UOS / Synology / 其它 Linux）用 Linux 标记 + 石板灰；`Host.osId` 为空（还没连过）解析成默认（`server.rack`）；`local` 是 `laptopcomputer`。加发行版：`HostSystem.ids`（+ 别名）、这张表、imageset 三处一起改 |
| `DSHostAvatar` | 主机在哪都长这样：方块 + 右下角状态点（点周围的环是从方块上挖出来的，放在任何底上都成立）；`Status`：none / live / busy / failed / ended。多个会话合成一个状态：`Status(states:)` 活着的优先（主机列表：这台还连得上吗）；`Status(states:ranking: .worstFirst)` 最坏的优先（标签页方块：这里有没有要看的） |
| `DSHostStack` | 叠放的主机方块：「这些主机在用」 |
| `DSSidebarLabel` | 侧边栏行：强调色**细线**字形（`.light`），**没有方块** |

### 卡片与数字

| 组件 | 用途 |
|------|------|
| `.dsCard(isSelected:isInteractive:hero:cornerRadius:)` | 内容层卡片：中性底、细边、浅色下有柔影；`hero` 是一层色调，画在底色和内容**之间**（不会盖住主机方块），**一屏最多一张** |
| `DSStatCard` | 数字卡：带小字形的标签、26pt 粗体数字 + 单位、一行脚注、底部可放 `DSMeter` / `DSSparkline` / `DSDayStrip`；`tone` 只在数字本身是状态时给；`lead:`（`.host` / `.system` / `.tile`）让数值是一个名字，前面带方块（「最常连接」）；`isFlat: true`：整排卡片都不带附属图时数字降一档（22pt）、卡片更矮。**同一条序列只画一次**：下面已有大图时卡片里不再放迷你曲线 / 点阵 / 满格条；脚注只在它不等于卡片数字时给；数值不存在的卡片不放 |
| `DSCardLabel` | 卡片的标签行（自己拼卡片时用） |
| `DSStatGrid` | 等宽等高、窄了换行的卡片排；一两张卡默认最宽 320，`widestOfFew: nil` 让它们铺满（设置页的两张卡）。自己拼的卡读 `\.dsFillsRowHeight` 跟着等高 |
| `DSGaugeCard` | 仪表卡：270° 弧 + 中间的数字 + 一行明细 + 底部元素；≥60% 自动带「偏高」、≥85% 带「告急」；`diameter:`（默认 128，窄页给 84，卡片随之收紧）；明细放得进弧的开口就在开口里，放不进就在弧下面，**不会压到弧端** |
| `DSDividedRow` | 并排的值：等宽列，中间细分隔线 |
| `DSValueCell` | 一个值：字形 \| 数字 \| 单位 \| 尾部（趋势线），说明在上或在下；要对齐就给 `valueWidth` / `unitWidth` |
| `DSSectionHeader` | 分组卡上方的标题 + 右侧补充 |
| `DSGroup` / `DSRow` | 分组卡（圆角 16，行间细线）/ 40pt 的行（`isCompact` 32pt） |
| `DSKeyValueRow` / `DSKeyLabel` | 键在固定列的行。给分组加 `.dsKeyColumn(fitting: [键…])`，键列就按当前语言里最长的键定宽（不给是 76pt，装不下英文的 Authentication）；自己排的行用 `DSKeyLabel` 进同一列 |
| `DSLinkRow` | 通向另一条记录的行：图标、标题 / 副标题、尾部、chevron |
| `DSChip` | 中性胶囊标签；`symbol` + `tint` 只用来表示状态（强 / 弱） |
| `DSStatusPill` | 状态：发光圆点 + 文字；`showsBackground: false` 是行内的裸形式；`isHollow: true` 是空心环——「关着」（已停止），区别于「结束了」 |

### 图表

| 组件 | 用途 |
|------|------|
| `DSMeter` | 细进度条（带柔光） |
| `DSDayStrip` | 一排日子，有事的亮；`days(from:)` 从活动数据得出 |
| `DSSparkline` | 无坐标轴趋势线（Swift Charts 线 + 面，带柔光）；`domain(for:range:minimumSpan:)` 给出刻度；`minimumSpan` 让两三个几乎相等的采样画成平线而不是满高的斜坡 |
| `DSArcGauge` | 270° 弧形仪表，颜色随水位；`detailFitsOpening` 决定明细在开口里还是弧下面 |
| `DSActivityChart` | 每日连接数：强调色渐变柱，今天更亮，空天是一条线；`days(from:count:now:calendar:)` 补齐空天；`marksFailures: true` 把失败的份额画成柱顶的红段（状态色，配 `DSActivityLegend` 的「成功 / 失败」） |
| `DSSegmentBar` | 占比条；`gap:` 让每段是自己的胶囊 |
| `DSLogStats` | 一组连接记录的合计（无数据为「—」，不是 0）；`durationText(ms:)` 写成「4 分 12 秒」（数字和单位之间有空格，全应用一种写法） |

### 关系、指纹、代码

| 组件 | 用途 |
|------|------|
| `DSRouteDiagram` | 路线图：带方块的胶囊节点 + 点状连线；`flowing` 绿色带柔光，`failed` 红色。首跳靠左、末跳靠右、中间的等分居中——同一张卡里叠着的几条路线列对齐；放不下时竖排（点状竖线，行尾是地址）。`style: .compact` 是方块在上、名字在下（检查器这类窄面板，不竖排）；`reachedHops:` 让还没到的那几段保持灰色（连接中）。`Host.routeHops(hosts:groups:)` 给出跳板链。**直连不画路线**：先问 `DSRouteDiagram.addsSomething(hopCount:)`（多于两跳才画），各处同一规则 |
| `DSRelativeTime` | 「5 分钟前」：全应用统一的措辞与取整（`DSRelativeTime.text(for:now:)`）；所有实例按整分钟一起刷新（`DSRelativeTime.schedule`）。卡片要把数字放大时用 `parts(for:now:)` 拆成数值 + 单位，放在 `TimelineView(DSRelativeTime.schedule)` 里——同一时刻在相邻两处不会差一 |
| `Randomart` / `DSRandomart` | `ssh-keygen -lv` 的指纹图（有单测对照），强调色，放在选中行（强调色胶囊）里自动变白；只有格子，起点不画环；解不出就显示「?」，不编图 |
| `DSCodeBlock` | 终端色的代码块（深浅外观下都是深色），可选中、带拷贝；`template:` 高亮 `{{变量}}`，`template:values:` 把已填的值代进去并高亮（没填的保持 `{{名字}}`）。只用于命令和输出；公钥、指纹这类「只是等宽」的内容放卡片（`DSGroup` + `DS.Font.mono` + `DSCopyButton`），不用它 |
| `DSThemeSwatches` | 终端主题色卡 |

### 骨架

| 组件 | 用途 |
|------|------|
| `DSMasterDetail` | 骨架 A：主栏 320 / 260 + 详情 |
| `DSMasterList` + `.dsListRow(isSelected:)` + `DSListSectionHeader`（`trailing:` 行尾可放控件） | 主栏：选中行是强调色胶囊（白字、柔光）；↑ / ↓ 换行 |
| `DSHostRow` | 标准两行主机行（放进 `.dsListRow`） |
| `.dsCenteredColumn()` | 骨架 B：最宽 760，居中 |
| `DSDetailHeader` | 详情头：64 方块、26 标题、副标题（地址等宽；一句话用 `isSubtitleMonospaced: false`）、右侧操作（一个 `.prominent` + 若干 `.glass`）与标题同一行，chip 在两者下面一行并会换行（`DSFlow`）。变窄时标题先让位（截到 180pt），所以单独一个 `⋯` 不会掉到下一行；再放不下操作才整行移到 chip 下面 |
| `DSEmptyState` | 空状态：页面方块 + 一句话 + 下一步；`detail:` 是一句话和按钮之间的位置（示意路线图） |
| `.dsStageBackground()` | 页面背后的强调色淡晕（两团径向渐变），每个页面一样。主从页面加在**整个** `DSMasterDetail` 上（主栏和详情同一块底，交界处没有接缝） |
| `DSHostPickerGrid` | 需要先选主机的页面的挑选网格 |
| `DSReveal` / `AppViewModel.reveal(_:id:)` / `takeReveal(for:)` | 从一个页面跳到另一个页面的某条记录 |

## For AI Agents

### Working In This Directory
- 颜色只用语义色和 `DS.Palette` / `DS.Tone`；**不写十六进制色值**。例外只有两处：终端主题、`DSOperatingSystem` 里发行版自己的颜色。
- 字体用 `DS.Font`；地址、指纹、命令用等宽；列里的数字用 `.monospacedDigit()`。
- 文字层级：真实数据最浅用 `.secondary`；`.tertiary` 只给占位内容（「—」、chevron）。
- 数据的颜色从卡片继承（`\.dsTint`），不要给 `DSMeter` / `DSSparkline` 单独传颜色，除非它不在卡片里。
- 给持续动画用 `.animation(_:value:)` 限定在那一个视图上，**不要用 `withAnimation { }` 包 `repeatForever`**：同一次更新里出现的玻璃按钮会跟着无限「显影」，看起来一直是糊的（`DSRouteDiagram` 踩过）。
- 没有数据显示「—」，不显示 0。
- 改完跑 `xcodegen`（新增文件时）、构建、单测，再截样张对比。

### Common Patterns
```swift
// 详情：头部 + 数字卡 + 分组卡
DSDetailHeader(title: host.displayName, subtitle: host.addressDescription) {
    DSHostAvatar(host, size: DS.Tile.header, status: status)
} accessory: {
    DSStatusPill("Connected")
    DSChip(verbatim: "#prod")
} actions: {
    Button("Connect", systemImage: "bolt.fill") { connect() }.dsButtonStyle(.prominent)
    Button("SFTP", systemImage: "folder") { openSFTP() }.dsButtonStyle(.glass)
    DSGlassIconMenu { Button("Duplicate") { duplicate() } }
}
DSStatGrid {
    DSStatCard("Success", value: "98", unit: "%", symbol: "checkmark.circle", footnote: failedText) {
        DSMeter(percent: 98)
    }
}
VStack(alignment: .leading, spacing: 0) {
    DSSectionHeader("Configuration")
    DSGroup {
        DSKeyValueRow("System", value: systemText)
        DSLinkRow(host: jump) { appViewModel.reveal(host: jump) }
    }
}

// 主栏
DSMasterList(selection: $selectedId, order: hosts.map(\.connectionKey)) {
    DSListSectionHeader(verbatim: group.name, count: hosts.count)
    ForEach(hosts, id: \.connectionKey) { host in
        DSHostRow(host, status: appViewModel.avatarStatus(forHostId: host.id)) {
            DSRelativeTime(host.lastConnectedDate)
        }
        .dsListRow(isSelected: selectedId == host.connectionKey)
        .id(host.connectionKey)
        .onTapGesture { selectedId = host.connectionKey }
    }
}
```

## Dependencies

### Internal
- 被 `Views/` 下所有视图依赖

<!-- MANUAL: -->
