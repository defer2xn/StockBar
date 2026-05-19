# StockBar 「今日」Tab 设计方案

> 状态：待用户 review
> 日期：2026-05-19
> 作者：协作产出（user + assistant）

## 1. 背景与目标

### 1.1 用户痛点

当前 StockBar 五个 Tab（持仓 / 自选 / 大盘 / 新闻 / 量化）数据齐全，但**信息表达不够"一眼看明白"**：
- 想知道"今天我赚还是亏"——要进持仓 Tab
- 想知道"今天能买什么"——要进量化 Tab
- 想知道"大盘和热点新闻什么情况"——要进大盘 / 新闻 Tab

每个查问都要切 Tab，且每个 Tab 内信息密度高、没有"先看一眼全貌"的入口。

### 1.2 目标

在不改动现有 5 个 Tab 内部布局的前提下，**新增一个「今日」Tab 作为启动默认页**，把三类高频信息汇集到一屏：

1. **今日盈亏**：是赚还是亏，多少
2. **量化买卖信号**：今天可以买/卖哪几只（评分高的）
3. **大盘 + 股票热点**：指数走势 + 持仓/自选相关新闻

### 1.3 非目标

- 不改 5 个原有 Tab 的内部结构（信息架构改造这一轮只做这一处）
- 不引入新的 helper API / 数据源
- 不引入 Bento Grid / WebGL / 复杂动效
- 不加配置项（默认布局即终态）

## 2. 架构

| 项 | 决定 |
|----|------|
| 新增 Tab 名 | **「今日」** |
| 侧栏 symbol | `sun.max.fill` |
| 侧栏位置 | 第一位（在「持仓」之前） |
| 默认选中 | `MainContentView` 启动时 `@State section = .today` |
| 数据来源 | 全部复用 `AppModel` 既有 `@Published` 字段，**零新 IPC** |
| 自动刷新 | 跟随现有 snapshot/quant timer，本 Tab 不另起 timer |
| 文件归属 | 新增 `Sources/StockBar/Views/TodayTab.swift`（预计 ~350 行，包含 4 个子 view） |

## 3. UI 布局

### 3.1 整体（Hero + 三栏）

```
PageHeader: 「今日」 · 19:03 · [刷新]
─────────────────────────────────────────
[ Hero 卡片：今日盈亏大数 + 持仓汇总 ]
─────────────────────────────────────────
| 量化建议  |  大盘指数   |  今日热点      |
| (≈30%)   |  (≈30%)    |  (≈40%)       |
─────────────────────────────────────────
```

布局实现：`VStack { Hero; LazyVGrid(columns: 3, minWidth: 280) }`，
列宽 `≥ 280pt`；总窗宽 < 960 时自动折回 1 列。

### 3.2 Hero 卡片 `TodayHero`

| 字段 | 来源 | 视觉 |
|------|------|------|
| **今日盈亏** | `holdings.totalPnlToday` | `hero(40)` 大字号，染色（红/绿/灰） |
| **涨跌幅** | `holdings.totalPnlTodayPct` | `ChangeChip(value)`（已有组件） |
| **总市值** | `holdings.totalMarketValue` | `subnumber` 中字号 |
| **持仓数** | `holdings.positions.count` | "持仓 N 只" |
| **现金** | `holdings.cash` | `subnumber` |
| **市场状态** | `MarketSession.isOpen` | 右上角小绿点 + "交易中" / 灰点 + "休市" |

**布局**：左侧大数（盈亏 + ChangeChip 同行），右侧三个 mini 指标（总市值 / 持仓 / 现金）水平排列。

**特殊态**：
- 持仓为空 → Hero 缩为单行 `现金 ¥X · 还没添加持仓 [加持仓]`，CTA 跳「持仓」Tab
- `holdings == nil`（首次加载）→ skeleton：三个灰条 + Shimmer

### 3.3 量化建议卡片 `OrderShortlistCard`

| 字段 | 来源 |
|------|------|
| 标题 | "量化建议" + 副标题 "X 买 Y 卖 · 评分倒排" |
| 列表 | `quantSnapshot.orders` 按 `score desc` 取前 5；**不按操作分组**，买卖按评分自然交错（评分相同时 sell 优先，因为持仓信号更紧急） |
| 行内字段 | 操作 badge（买/止盈/止损/清仓）/ 名字 / 代码 / 评分大数 / 距现价 % |

**行高**：紧凑 ~32pt。
**点击行为**：点击行 → 切到「量化」Tab 并通过 `@Published model.quantSelectedOrderId` 滚动到该笔订单 + 高亮 1s。
**底部 CTA**："查看全部 N 笔 →" 链接到量化 Tab。

**特殊态**：
- `quantSnapshot == nil && quantLoading` → ProgressView + "量化扫描中…"
- `orders.isEmpty` → 空状态："今日无符合订单"
- `quantError != nil` → 红色 banner 显示错误简述

### 3.4 大盘指数卡片 `IndicesGridCard`

| 字段 | 来源 |
|------|------|
| 标题 | "大盘" + 当前时段（休市 / 盘中） |
| 卡片 | `model.indices`（4 只：上证 / 深证 / 创业板 / 沪深 300） |
| 单卡内 | 名字（大）/ 价格（rounded mono）/ ChangeChip / **mini 分时**（60pt 高，无 axis 无 label） |

**布局**：2×2 网格。
**mini 分时**：`IntradayChartView` 加 `compact: Bool` 参数：true 时隐藏 header / X 轴 / Y 轴 / 昨收注解文字，保留昨收虚线（用于视觉锚定），只留主线 + 染色 area。
**点击行为**：点卡片 → 切到「大盘」Tab 并通过既有 `selectedCode` 机制选中该指数。

**特殊态**：
- 任一指数缺 `chartByCode[code]` → 该卡 mini 分时区域显示一条平直辅助线 + "加载中"
- `indices.isEmpty` → 整体卡片显示"指数数据未到位"

**额外**：`TodayTab.onAppear` 里若 `chartByCode` 里某 index code 没数据，循环 `model.requestChart(code:)` 拉一遍（已有 API，不增 helper 命令）。

### 3.5 今日热点卡片 `HotNewsCard`

| 字段 | 来源 |
|------|------|
| 标题 | "今日热点" + 副标题 "持仓 + 自选相关 N 条" |
| 列表 | 合并 `newsByCode` 所有 code 的新闻；按 `date desc` 去重（按 url）取前 10 |
| 行内字段 | title（最多 2 行） / 股票名 chip（颜色按涨跌） / 时间 |

**点击行为**：点击新闻 → 切到「新闻」Tab + `newsSelectedCode = code` + `newsSelectedURL = url`。
**首次进入预拉**：若 `newsByCode` 大部分为空，调用现有 `refreshAllNews()`。

**特殊态**：
- 全空 → "暂无新闻"
- 加载中（`newsByCode` 还没数据） → skeleton 3 行

## 4. 数据流变更

### 4.1 AppModel 新增字段

```swift
/// 量化订单跳转锚点：「今日」Tab 点击订单后写入，量化 Tab 监听并滚动 + 高亮
@Published var quantHighlightOrderId: String?
```

仅 1 个新字段。其它都复用既有 `@Published`。

### 4.2 SidebarSection enum 改动

```swift
enum SidebarSection: Hashable, CaseIterable {
    case today, holdings, watchlist, indices, news, quant   // today 首位
    var title: String { ... }
    var symbol: String { ... case .today: return "sun.max.fill" }
}
```

`MainContentView.detail` 添加 `case .today: TodayTab()`，默认 `@State section: SidebarSection? = .today`。

### 4.3 IntradayChartView 改动

`IntradayChartView` 增加 `compact: Bool = false` 参数；compact 模式：
- 隐藏 header（名字 / 价格 / ChangeChip）
- 隐藏 X 轴 label 和 grid
- 隐藏 Y 轴 label
- 隐藏昨收注解文字
- frame `minHeight: 60`

不影响现有调用点（默认 `compact: false`）。

## 5. 错误处理与降级

| 场景 | 行为 |
|------|------|
| helper 进程没起 | Hero / 三栏 全部 skeleton，PageHeader 标题旁红点 "helper 未就绪" |
| snapshot 拉失败 | Hero 显示 `--`，副文案 "刷新失败，按 ⌘R 重试" |
| quant 跑挂 | 左栏显示红色 banner |
| 个别 chart 拉失败 | 该 mini 分时空白，其它正常 |
| news 拉失败 | 右栏显示 "新闻获取失败" |

降级原则：**任一区块挂掉不影响其它区块**。

## 6. 实现拆解（写 plan 时进一步拆 task）

1. `SidebarSection` 加 `today` + 默认选中改 today
2. `IntradayChartView` 加 `compact` 参数
3. `AppModel` 加 `quantHighlightOrderId`
4. `TodayTab.swift` 新文件，4 个子 view
5. `MainContentView` 加 `case .today`
6. `QuantTab` 监听 `quantHighlightOrderId`，做滚动 + 高亮
7. 各种 empty / loading / error 状态
8. 视觉打磨：色彩、间距、字号

## 7. 验收清单

- [ ] App 启动默认进入「今日」Tab
- [ ] Hero 卡片正确显示今日盈亏（红涨绿跌、ChangeChip 方向正确）
- [ ] 持仓为空时 Hero 降级为"现金 + 加持仓 CTA"
- [ ] 量化卡片显示评分前 5 订单，点击跳量化 Tab 并高亮
- [ ] 大盘卡片显示 4 个指数 + mini 分时；点击跳大盘 Tab 并选中
- [ ] 热点卡片显示前 10 条新闻；点击跳新闻 Tab 并打开
- [ ] 窗口宽 < 960 时三栏折回单列
- [ ] `prefers-reduced-motion` 下不再做 shimmer 动画（用静态灰条）
- [ ] 暗色模式正常（所有色彩都走 DS 颜色变量）

## 8. 不在本期范围（未来迭代）

- 持仓 Tab 的表格密度优化（用户原题里也提了"视觉精度"，留给下一轮）
- 自选 Tab 的批量管理
- 新闻 Tab 的搜索 / 过滤
- 量化 Tab 的列宽自适应
