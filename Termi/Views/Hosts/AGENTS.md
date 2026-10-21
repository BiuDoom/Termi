<!-- Parent: ../AGENTS.md -->
<!-- Generated: 2026-03-02 | Updated: 2026-10-07 -->

# Views/Hosts

## Purpose
主机功能域。主机页是骨架 C（见 `Views/AGENTS.md`）：主机卡片铺满整页（或切成整行列表），档案**不常驻**，只在用户要的时候在页内右侧面板展开——机主用过之后的要求（2026-10-07，参照 Termius）。另有主机表单、分组表单、身份管理、端口转发表单和快速连接弹窗。

## Key Files

| File | Description |
|------|-------------|
| `HostListView.swift` | 主机页：工具栏（卡片 / 列表切换 `@AppStorage("hostsLayout")`，默认卡片；排序、本地终端、添加）、筛选条（全部 / 在线 / 标记，带计数）、卡片网格（自适应列，卡片最窄 264：1200 宽的窗口三列，开着面板两列；900 宽两列 / 一列）、列表（`DSMasterList`，整行）、按需展开的档案面板（380，带分隔线，从右侧滑入，卡片重排）、⌘I、搜索即连接、空状态与读库失败、全部 sheet / alert；`AppViewModel.liveSessionCount(forHostId:)`；DEBUG 启动参数 |
| `HostDetailView.swift` | 主机档案（现在只出现在面板里，走它的窄版布局）：面板条（「主机详情」+ 关闭，不随档案滚动；传了 `onClose` 才有）、头部（方块 + 状态点、名称、地址、状态 / 系统 / 标记 chip、「连接」「SFTP」「编辑」「更多」）、四张数字卡、连接路径、端口转发（开关直接启停）、最近 14 天 + 最近 5 次会话（可看会话记录）、配置（认证 / 系统 / 分组 / 启动片段 / 主题 / 转发 / 备注，能跳到对应页面）、主机指纹；`HostDetailFormat` 是数字和时间的措辞规则（纯函数，有单测） |
| `HostRowView.swift` | `HostActions`（一台主机能做的事）、`HostMenuItems`（行 / 卡片的右键菜单和档案的「更多」菜单共用）、`HostListRow`（列表行）、`HostCardView`（网格卡片）；行和卡片在悬停或选中时只露出一个按钮（`info.circle`，打开 / 关闭档案面板），位置一直留着，文字不会被挤或被盖 |
| `HostFormView.swift` | 添加 / 编辑主机：顶部是不随表单滚动的实时预览（方块、名称、地址、连接路径，随输入变化），「系统」一节只读（系统由连接后读取，不能在表单里填） |
| `QuickConnectView.swift` | 快速连接：大号地址框、实时解析（用户 @ 主机 : 端口）、地址对上已存主机时改用该主机、最近的临时连接（点一下填入） |
| `GroupFormView.swift` | 添加 / 编辑主机分组 |
| `IdentitiesView.swift` | 身份管理（用户名 + 密钥的命名组合） |
| `PortForwardFormView.swift` | 端口转发规则表单 |

## For AI Agents

### Working In This Directory
- **三个状态别混**（都在 `HostsViewModel`，随窗口存在）：`selectedHostId`＝描边的那张卡片，方向键和 Return 作用的对象，**进入页面时为 nil**，页面不替用户选；主机被删、被搜索 / 筛选藏起来时清成 nil，不落到别的主机上（`selection(_:keptWithin:)`）。`pickedHostId`＝用户亲手点的那台，**只在它仍是选中项时有效**（选中项一变成别的主机或 nil 就清掉，免得页面之后自己选回这台时 ⌫ 把它当成用户选的）；⌫ 只问「亲手点的」或「网格 / 列表有键盘焦点时选中的」（`deleteTarget`），刚新建 / 复制出来被 `reveal` 选中并滚到的主机不算。`showsDetails`＝面板开着；`detailsHostId` 是面板显示的主机（开着时就是选中项，所以面板跟着选中项走）；选中项一变成 nil 面板就关（不是「等下一次选中」），不持久化，每次启动都是关的。
- 打开面板的三条路：卡片 / 行上的按钮（`toggleDetails(for:)`，同一台再点一次是关）、⌘I（`toggleDetails()`，没选中时什么都不做；快捷键挂在页面背景里一个看不见的按钮上）、右键菜单「显示详情」。关：面板条上的按钮、⌘I、主机没了。别的页面的「在主机中显示」走 `AppViewModel.reveal(host:)` → `showRecord(of:)`：清掉搜索 / 标记 / 在线筛选，选中、打开面板、滚到那张卡片（不切换、不算亲手点；页面挂载时对 `hostToBringIntoView` 滚一次，因为那时 `onChange` 不会触发）。
- 卡片是一个无障碍元素（`children: .ignore`）：默认动作「连接」，具名动作「编辑」「显示详情」（面板正显示这台时叫「隐藏详情」）；里面的按钮不是第二个元素。列表行同理：行尾按钮对无障碍隐藏，不并进行的标签。
- 单击选中，双击 / Return 连接（只开一个会话）；连接、SFTP、编辑在右键菜单和面板里，卡片上不再有三个悬停按钮。
- 档案自己的数据（连接记录、转发规则、保险库里有没有密码）由 `HostsViewModel.loadDetail(for:)` 读，`.task(id:)` 的键是「主机 id + `revision` + 标签数」：主机列表每读一次、每开关一个会话都会重读。引用的密钥 / 身份 / 片段 / 已知主机由 `loadReferences()` 读。
- 「连接」是本屏唯一的 `.dsButtonStyle(.prominent)`，不加默认快捷键——Return 属于搜索框（搜索即连接）和列表（Return = 连接选中的主机）。
- 状态永远带词：行尾是「N 个会话」，档案头是状态 chip；方块右下角的圆点只是补充。
- 系统（`Host.osId / osName / osArch`）只由 `HostSystemProbe` 写；表单和档案只读。
- 筛选（标记、在线）和选中项放在 `HostsViewModel`（它随窗口存在；看终端时页面会被移出窗口）。
- 保存 / 删除主机或分组成功后 `HostsViewModel` 发 `.dsDataChanged`。
- 数字卡没有数据显示「—」；`HostDetailFormat` 里改措辞要同步单测（`TermiTests/RedesignWP2Tests.swift`）。

### DEBUG 启动参数（截图用）
- `-debugHostSelect <label>`：选中某台主机（面板不开）
- `-debugHostDetails <label>`：选中并打开它的档案面板
- `-debugHostHover <label>`：把它的卡片 / 行画成悬停状态（截按钮用，不需要真的指针）
- `-debugHostEdit <label>`：打开它的编辑表单（走页面自己的 sheet）
- `-debugHostsAfterConnect YES`：与 `-debugConnect` 一起用，会话开好后回到主机页（看在线状态）；再加 `-debugHostsOnline YES` 打开「在线」筛选
- `-debugQuickConnectText user@host:port`：快速连接弹窗里预填地址
- `-hostsLayout grid|list`：卡片 / 列表（就是 `@AppStorage` 的键；旧键 `hostsViewMode` 不再读——老用户那里存的都是旧含义的 `list`）

## Dependencies

### Internal
- `ViewModels/HostsViewModel.swift`
- `ViewModels/IdentitiesViewModel.swift`
- `Theme/`（`DSMasterList`、`DSHostRow`、`DSHostAvatar`、`DSStatCard`、`DSRouteDiagram`、`DSActivityChart` …）
- `Views/DevOps/ConnectionLogsView.swift` 的 `SessionTranscriptView`、`Views/DevOps/PortForwardsView.swift` 的 `OpsErrorBanner`

<!-- MANUAL: -->
