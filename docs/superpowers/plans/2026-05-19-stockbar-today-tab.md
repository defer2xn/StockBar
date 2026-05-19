# StockBar 「今日」Tab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新增一个「今日」Tab 作为 StockBar 启动默认页，把今日盈亏、量化买卖信号、大盘 + 热点新闻三类高频信息聚合到一屏。

**Architecture:** Hero（盈亏大数 + 持仓汇总）+ 三栏（量化建议 / 大盘指数 mini 分时 / 热点新闻），全部读 `AppModel` 既有 `@Published` 数据，零新 helper API。新建 1 个 `TodayTab.swift`（含 4 个子 view），同时改造 `IntradayChartView` 加 compact 模式，`AppModel` 加 1 个跳转锚点 `@Published`，`SidebarSection` 加 today 项。

**Tech Stack:** Swift 5.9 / SwiftUI / macOS 14 / Swift Charts。无 Unit Test 框架，验证靠 `bash scripts/build.sh` + 运行 App 视觉确认。

**Spec：** `docs/superpowers/specs/2026-05-19-stockbar-today-tab-design.md`

---

## 文件结构

| 操作 | 文件 | 职责 |
|------|------|------|
| Create | `Sources/StockBar/Views/TodayTab.swift` | 「今日」Tab 根视图 + 4 个子 view（TodayHero / OrderShortlistCard / IndicesGridCard / HotNewsCard）|
| Modify | `Sources/StockBar/Views/MainContentView.swift` | `SidebarSection` enum 加 `.today` + 默认选中改为 `.today` |
| Modify | `Sources/StockBar/AppModel.swift` | 加 `@Published var quantHighlightOrderId: String?`（订单跳转锚点）|
| Modify | `Sources/StockBar/Views/IntradayChartView.swift` | 加 `compact: Bool = false` 参数，true 时简化渲染 |
| Modify | `Sources/StockBar/Views/QuantTab.swift` | 监听 `model.quantHighlightOrderId`，滚动到该订单并高亮 1s |

每个 task 完成一个独立的可构建单元。Task 1-3 是地基（其它 task 依赖），4-8 自下而上组装 UI，9 完成跨 tab 联动，10-12 是状态完整性 + 打磨。

---

## Task 1: 加 SidebarSection.today 与默认选中

**Files:**
- Modify: `Sources/StockBar/Views/MainContentView.swift:8` (default selection)
- Modify: `Sources/StockBar/Views/MainContentView.swift:22-31` (detail switch)
- Modify: `Sources/StockBar/Views/MainContentView.swift:34-56` (enum + title + symbol)

- [ ] **Step 1: 在 SidebarSection enum 第一位加 .today**

```swift
enum SidebarSection: Hashable, CaseIterable {
    case today, holdings, watchlist, indices, news, quant

    var title: String {
        switch self {
        case .today:     return "今日"
        case .holdings:  return "持仓"
        case .watchlist: return "自选"
        case .indices:   return "大盘"
        case .news:      return "新闻"
        case .quant:     return "量化"
        }
    }

    var symbol: String {
        switch self {
        case .today:     return "sun.max.fill"
        case .holdings:  return "briefcase.fill"
        case .watchlist: return "star.fill"
        case .indices:   return "chart.bar.fill"
        case .news:      return "newspaper.fill"
        case .quant:     return "function"
        }
    }
}
```

- [ ] **Step 2: 默认 section 改 .today，detail switch 加 case**

```swift
struct MainContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: SidebarSection? = .today      // ← 改这里
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // ...

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .today:     TodayTab()                           // ← 加这行
        case .holdings:  HoldingsTab()
        case .watchlist: WatchlistTab()
        case .indices:   IndicesTab()
        case .news:      NewsTab()
        case .quant:     QuantTab()
        case .none:      TodayTab()                           // ← 改这里
        }
    }
}
```

注：Step 2 引用了 `TodayTab()`，此时还未定义，**Task 1 不会单独编译通过**。把 TodayTab 创建放到 Task 4，所以 Task 1 与 Task 4 视为联合提交（也可暂时用占位 `Text("Today")` 让 Task 1 单独可编译，但徒增 churn，直接接 Task 4 即可）。

**结论：Task 1 完成后不构建，直接进 Task 2 / 3 / 4，到 Task 4 一并构建。**

---

## Task 2: AppModel 加 quantHighlightOrderId

**Files:**
- Modify: `Sources/StockBar/AppModel.swift:14`（紧挨 `lastUpdated` 后加新字段）

- [ ] **Step 1: 添加 @Published 字段**

```swift
@Published private(set) var lastError: String?
@Published private(set) var lastUpdated: String?
/// snapshot 刷新是否正在进行，用于按钮转圈反馈
@Published private(set) var isRefreshing: Bool = false
/// 「今日」Tab 点击某订单后写入该订单 id；量化 Tab 监听并滚动 + 高亮。消费后清空。
@Published var quantHighlightOrderId: String?
```

注意是 `var` 不是 `private(set)`，因为外部要写。

- [ ] **Step 2: 构建验证**

```bash
bash scripts/build.sh
```

Expected: `Build complete!` 无新增 error/warning。

---

## Task 3: IntradayChartView 加 compact 参数

**Files:**
- Modify: `Sources/StockBar/Views/IntradayChartView.swift:6-15` (struct 定义 + body)
- Modify: `Sources/StockBar/Views/IntradayChartView.swift:17-42` (header conditional)
- Modify: `Sources/StockBar/Views/IntradayChartView.swift:44-110` (chart axes conditional)

- [ ] **Step 1: 加 compact 参数到 struct**

```swift
struct IntradayChartView: View {
    let data: ChartData
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            if !compact {
                header
            }
            chart
                .frame(minHeight: compact ? 60 : 220)
        }
    }
    // ... 其余不变
```

- [ ] **Step 2: 在 chart computed property 里按 compact 切换 axes 与 annotation**

把现有的：

```swift
if let prev = data.prevClose {
    RuleMark(y: .value("prev_close", prev))
        .foregroundStyle(.secondary.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .annotation(position: .top, alignment: .trailing) {
            Text("昨收 \(String(format: "%.3f", prev))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
                .background(.regularMaterial, in: Capsule())
        }
}
```

改成：

```swift
if let prev = data.prevClose {
    RuleMark(y: .value("prev_close", prev))
        .foregroundStyle(.secondary.opacity(0.5))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
        .annotation(position: .top, alignment: .trailing) {
            if !compact {
                Text("昨收 \(String(format: "%.3f", prev))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .background(.regularMaterial, in: Capsule())
            }
        }
}
```

把 `.chartXAxis { ... }` 和 `.chartYAxis { ... }` 包成条件：

```swift
.chartXAxis {
    if compact {
        // 完全隐藏 X 轴
    } else {
        AxisMarks(values: tickIndicesForLabels()) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                .foregroundStyle(.secondary.opacity(0.3))
            AxisValueLabel {
                if let idx = value.as(Int.self), idx < data.ticks.count {
                    Text(formatHHMM(data.ticks[idx].time))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
.chartYAxis {
    if compact {
        // 完全隐藏 Y 轴
    } else {
        AxisMarks(position: .trailing) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                .foregroundStyle(.secondary.opacity(0.3))
            AxisValueLabel()
                .font(.caption2)
        }
    }
}
```

- [ ] **Step 3: 构建验证**

```bash
bash scripts/build.sh
```

Expected: `Build complete!`。所有现有调用点（IndicesTab/HoldingsTab/WatchlistTab）因为没传 compact，默认 false，行为不变。

---

## Task 4: 创建 TodayTab.swift 框架（壳子 + PageHeader）

**Files:**
- Create: `Sources/StockBar/Views/TodayTab.swift`

- [ ] **Step 1: 写最小可编译的 TodayTab**

```swift
import SwiftUI

/// 「今日」Tab：启动默认页，三个高优先信息一屏聚合。
struct TodayTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var portfolio: PortfolioStore

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "今日",
                subtitle: subtitle,
                onRefresh: {
                    model.requestRefresh()
                    model.requestQuant()
                    prefetchIndexCharts()
                },
                timestamp: shortTime(model.lastUpdated)
            )

            ScrollView {
                VStack(spacing: DS.spaceL) {
                    // 后续 task 会塞入 Hero / 三栏
                    Text("今日 Tab 占位")
                        .foregroundStyle(.secondary)
                        .padding(DS.space2XL)
                }
                .padding(.horizontal, DS.spaceXL)
                .padding(.bottom, DS.spaceXL)
            }
        }
        .onAppear {
            prefetchIndexCharts()
            if model.newsByCode.isEmpty {
                model.refreshAllNews()
            }
        }
    }

    private var subtitle: String {
        let session = MarketSession.isOpen ? "交易中" : "盘后"
        return "\(session)  ·  一眼看盘"
    }

    private func prefetchIndexCharts() {
        for q in model.indices {
            if let code = q.code, model.chartByCode[code] == nil {
                model.requestChart(code: code)
            }
        }
    }

    private func shortTime(_ ts: String?) -> String? {
        guard let ts else { return nil }
        return ts.split(separator: " ").last.map(String.init)
    }
}
```

- [ ] **Step 2: 构建验证（连同 Task 1 / 2 / 3 的改动）**

```bash
bash scripts/build.sh
```

Expected: `Build complete!`。
启动 App 验证：
- 启动默认进入「今日」Tab（侧栏选中第一项 sun.max.fill icon）
- 顶部 PageHeader 显示「今日」标题、刷新按钮可点
- 内容区显示"今日 Tab 占位"灰字

---

## Task 5: TodayHero 子视图（盈亏大数 + 持仓汇总）

**Files:**
- Modify: `Sources/StockBar/Views/TodayTab.swift`（在底部 `// MARK: - 子视图` 区追加 `TodayHero`，同时把占位 `Text` 替换为 `TodayHero()`）

- [ ] **Step 1: 替换占位**

把 TodayTab.body 里的：

```swift
Text("今日 Tab 占位")
    .foregroundStyle(.secondary)
    .padding(DS.space2XL)
```

替换为：

```swift
TodayHero()
```

- [ ] **Step 2: 在 TodayTab.swift 文件底部加 TodayHero**

```swift
// MARK: - Hero 卡片

private struct TodayHero: View {
    @EnvironmentObject private var model: AppModel

    private var holdings: Holdings? { model.holdings }

    var body: some View {
        if let h = holdings, !h.positions.isEmpty {
            populatedHero(h)
        } else {
            emptyHero
        }
    }

    private func populatedHero(_ h: Holdings) -> some View {
        HStack(alignment: .top, spacing: DS.spaceXL) {
            // 左：今日盈亏大数 + ChangeChip
            VStack(alignment: .leading, spacing: DS.spaceS) {
                Text("今日盈亏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: DS.spaceM) {
                    Text(Optional(h.totalPnlToday).signedMoneyString())
                        .font(DS.hero(40))
                        .foregroundColor(DS.tint(for: h.totalPnlToday))
                    ChangeChip(value: h.totalPnlTodayPct)
                }
            }
            Spacer(minLength: DS.spaceXL)
            // 右：mini 指标 3 列
            HStack(spacing: DS.spaceXL) {
                miniStat(title: "总市值", value: formatMoney(h.totalMarketValue))
                miniStat(title: "持仓", value: "\(h.positions.count) 只")
                miniStat(title: "现金", value: formatMoney(h.cash ?? 0))
            }
            // 市场状态指示
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(MarketSession.isOpen ? DS.up : DS.flat)
                        .frame(width: 7, height: 7)
                    Text(MarketSession.isOpen ? "交易中" : "休市")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DS.spaceXL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusL, style: .continuous)
                .fill(DS.tintBg(for: holdings?.totalPnlToday))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusL, style: .continuous)
                .strokeBorder(DS.border.opacity(0.6), lineWidth: 0.5)
        )
    }

    private var emptyHero: some View {
        HStack(spacing: DS.spaceL) {
            Image(systemName: "tray")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 4) {
                Text("还没添加持仓")
                    .font(.system(size: 16, weight: .semibold))
                Text("加仓后开始追踪今日盈亏")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let cash = model.holdings?.cash {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("现金")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(formatMoney(cash))
                        .font(DS.subnumber(18))
                }
            }
        }
        .padding(DS.spaceXL)
        .cardStyle()
    }

    private func miniStat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(DS.subnumber(18))
        }
    }
}
```

- [ ] **Step 3: 构建 + 视觉验证**

```bash
bash scripts/build.sh
```

启动 App 看「今日」Tab：
- 持仓非空：上方一条粗胶囊状卡片，左大字今日盈亏 + ChangeChip，中三个 mini 指标，右上"交易中/休市"
- 临时把 portfolio.json 的 positions 清空看 emptyHero（验证后改回）

---

## Task 6: OrderShortlistCard 子视图（量化建议前 5）

**Files:**
- Modify: `Sources/StockBar/Views/TodayTab.swift`（在 TodayHero 后追加 OrderShortlistCard；在 TodayTab.body 的 VStack 加 LazyVGrid 三栏，先插 OrderShortlistCard）

- [ ] **Step 1: 在 TodayTab.body 里建三栏 grid 框架**

把：

```swift
VStack(spacing: DS.spaceL) {
    TodayHero()
}
```

改为：

```swift
VStack(spacing: DS.spaceL) {
    TodayHero()
    threeColumnGrid
}
```

并在 struct TodayTab 里加 computed property：

```swift
private var threeColumnGrid: some View {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280, maximum: .infinity), spacing: DS.spaceL)],
        spacing: DS.spaceL
    ) {
        OrderShortlistCard()
        // 后续 task 加 IndicesGridCard / HotNewsCard
    }
}
```

注：`GridItem(.adaptive(...))` 在窗宽 < 960 时自动折回 1 列（满足 spec 响应式要求）。

- [ ] **Step 2: 加 OrderShortlistCard 实现**

```swift
// MARK: - 量化建议卡片

private struct OrderShortlistCard: View {
    @EnvironmentObject private var model: AppModel

    private var allOrders: [QuantOrder] {
        guard let snap = model.quantSnapshot else { return [] }
        return snap.orders
    }

    /// 取 score 倒排前 5；score 相同 sell 优先
    private var topOrders: [QuantOrder] {
        allOrders.sorted { a, b in
            let sa = a.score ?? 0
            let sb = b.score ?? 0
            if sa != sb { return sa > sb }
            return a.isSell && !b.isSell
        }
        .prefix(5).map { $0 }
    }

    private var buyCount: Int { allOrders.filter { !$0.isSell }.count }
    private var sellCount: Int { allOrders.filter { $0.isSell }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            header
            if model.quantLoading && model.quantSnapshot == nil {
                ProgressView("量化扫描中…")
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else if let err = model.quantError {
                errorBanner(err)
            } else if topOrders.isEmpty {
                emptyState
            } else {
                ForEach(topOrders) { order in
                    orderRow(order)
                }
                viewAllLink
            }
        }
        .padding(DS.spaceL)
        .cardStyle(padding: 0)
    }

    private var header: some View {
        HStack {
            Text("量化建议")
                .font(DS.sectionTitle)
            Spacer()
            Text("\(buyCount) 买 · \(sellCount) 卖")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func orderRow(_ o: QuantOrder) -> some View {
        Button {
            model.quantHighlightOrderId = o.id
            // section 切到量化 —— 通过 NotificationCenter 或共享 binding；
            // 当前实现：复用 AppModel 的另一个 published；最简方案是在 model 里加
            // newsSelectedCode 同款机制。这里走 NotificationCenter 解耦：
            NotificationCenter.default.post(
                name: .switchToQuantTab, object: nil
            )
        } label: {
            HStack(spacing: DS.spaceS) {
                actionBadge(o)
                    .frame(width: 50, alignment: .leading)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(o.code)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if let score = o.score {
                    Text("\(score)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor(score))
                        .frame(width: 32, alignment: .trailing)
                }
                Text(distanceLabel(o))
                    .font(.system(size: 10, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 50, alignment: .trailing)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func actionBadge(_ o: QuantOrder) -> some View {
        let isBuy = !o.isSell
        let bg = isBuy ? DS.up.opacity(0.12) : DS.down.opacity(0.12)
        let fg = isBuy ? DS.up : DS.down
        return Text(o.action)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }

    private func scoreColor(_ s: Int) -> Color {
        if s >= 85 { return DS.up }
        if s >= 70 { return .primary }
        return .secondary
    }

    private func distanceLabel(_ o: QuantOrder) -> String {
        if o.isSell, let p = o.sellPct {
            return String(format: "%+.1f%%", p)
        }
        if !o.isSell, let p = o.buyPct {
            return String(format: "%+.1f%%", p)
        }
        return "—"
    }

    private var viewAllLink: some View {
        Button {
            NotificationCenter.default.post(name: .switchToQuantTab, object: nil)
        } label: {
            HStack {
                Spacer()
                Text("查看全部 \(allOrders.count) 笔")
                    .font(.caption)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: DS.spaceS) {
            Image(systemName: "tray")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("今日无符合条件订单")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func errorBanner(_ err: String) -> some View {
        Text(err)
            .font(.caption)
            .foregroundColor(DS.down)
            .padding(DS.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.down.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }
}
```

- [ ] **Step 3: 在 TodayTab.swift 顶部加 Notification.Name 扩展**

```swift
extension Notification.Name {
    static let switchToQuantTab = Notification.Name("StockBar.switchToQuantTab")
    static let switchToIndicesTab = Notification.Name("StockBar.switchToIndicesTab")
    static let switchToNewsTab = Notification.Name("StockBar.switchToNewsTab")
}
```

- [ ] **Step 4: MainContentView 监听上面三个通知，切换 section**

修改 `MainContentView.body`：

```swift
var body: some View {
    NavigationSplitView(columnVisibility: $columnVisibility) {
        Sidebar(selection: $section)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
    } detail: {
        detail
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 980, minHeight: 600)
    .onReceive(NotificationCenter.default.publisher(for: .switchToQuantTab)) { _ in
        section = .quant
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchToIndicesTab)) { _ in
        section = .indices
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchToNewsTab)) { _ in
        section = .news
    }
}
```

- [ ] **Step 5: 构建 + 视觉验证**

```bash
bash scripts/build.sh
```

启动 App：
- 「今日」Tab 三栏 grid 出现第一列 "量化建议"
- 显示评分前 5 订单，每行：买/卖 badge / 名字 / 代码 / 评分 / 距现价
- 点订单 → 切到「量化」Tab（Task 9 再加滚动 + 高亮）
- 点底部 "查看全部 N 笔" → 切到量化 Tab

---

## Task 7: IndicesGridCard 子视图（4 指数 + mini 分时）

**Files:**
- Modify: `Sources/StockBar/Views/TodayTab.swift`（在 threeColumnGrid 里加 IndicesGridCard，在 OrderShortlistCard 后追加 struct）

- [ ] **Step 1: 在 threeColumnGrid 里加**

```swift
private var threeColumnGrid: some View {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280, maximum: .infinity), spacing: DS.spaceL)],
        spacing: DS.spaceL
    ) {
        OrderShortlistCard()
        IndicesGridCard()
    }
}
```

- [ ] **Step 2: 加 IndicesGridCard 实现**

```swift
// MARK: - 大盘指数卡片

private struct IndicesGridCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            HStack {
                Text("大盘")
                    .font(DS.sectionTitle)
                Spacer()
                Text(MarketSession.isOpen ? "盘中" : "盘后")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if model.indices.isEmpty {
                placeholderRow("指数数据未到位")
            } else {
                LazyVGrid(
                    columns: [GridItem(.flexible()), GridItem(.flexible())],
                    spacing: DS.spaceS
                ) {
                    ForEach(model.indices) { q in
                        indexCard(q)
                    }
                }
            }
        }
        .padding(DS.spaceL)
        .cardStyle(padding: 0)
    }

    private func indexCard(_ q: Quote) -> some View {
        Button {
            if let code = q.code {
                NotificationCenter.default.post(
                    name: .switchToIndicesTab, object: code
                )
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(q.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                    ChangeChip(value: q.changePct, compact: true)
                }
                Text(q.price.priceString(decimals: 2))
                    .font(DS.subnumber(16))
                    .foregroundColor(DS.tint(for: q.changePct))
                miniChart(for: q)
                    .frame(height: 50)
            }
            .padding(DS.spaceS)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                    .fill(DS.tintBg(for: q.changePct))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                    .strokeBorder(DS.border.opacity(0.4), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func miniChart(for q: Quote) -> some View {
        if let code = q.code, let chart = model.chartByCode[code] {
            IntradayChartView(data: chart, compact: true)
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.06))
                .overlay(
                    Text("分时加载中")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                )
        }
    }

    private func placeholderRow(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 80)
    }
}
```

- [ ] **Step 3: IndicesTab 监听 NotificationCenter 切换并选中**

Modify `Sources/StockBar/Views/IndicesTab.swift`：

把现有的：

```swift
struct IndicesTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedCode: String?
```

下面 `body` 里增加 onReceive：

```swift
var body: some View {
    VStack(spacing: 0) {
        // ... 原有 PageHeader 等
    }
    .onReceive(NotificationCenter.default.publisher(for: .switchToIndicesTab)) { note in
        if let code = note.object as? String {
            selectedCode = code
            model.requestChart(code: code)
        }
    }
}
```

- [ ] **Step 4: 构建 + 视觉验证**

```bash
bash scripts/build.sh
```

启动 App：
- 「今日」Tab 第二列是 "大盘"，里面 2×2 网格：上证 / 深证 / 创业板 / 沪深300
- 每张小卡：名字 + ChangeChip + 大字价格 + 50pt 高 mini 分时（无 axis 无 label）
- 点小卡 → 切到「大盘」Tab 并选中该指数

---

## Task 8: HotNewsCard 子视图（热点新闻前 10）

**Files:**
- Modify: `Sources/StockBar/Views/TodayTab.swift`（在 threeColumnGrid 里加 HotNewsCard，文件底部追加 struct）

- [ ] **Step 1: 在 threeColumnGrid 里加**

```swift
private var threeColumnGrid: some View {
    LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 280, maximum: .infinity), spacing: DS.spaceL)],
        spacing: DS.spaceL
    ) {
        OrderShortlistCard()
        IndicesGridCard()
        HotNewsCard()
    }
}
```

- [ ] **Step 2: 加 HotNewsCard 实现**

```swift
// MARK: - 今日热点新闻卡片

private struct HotNewsCard: View {
    @EnvironmentObject private var model: AppModel

    /// 合并所有 newsByCode 的条目，按 date desc 去重（url）取前 10
    private var topNews: [(code: String, item: NewsItem)] {
        var pairs: [(code: String, item: NewsItem)] = []
        for (code, items) in model.newsByCode {
            for item in items {
                pairs.append((code: code, item: item))
            }
        }
        // 按 date desc；date 是字符串 "YYYY-MM-DD HH:MM" 风格，字典序排序即可
        pairs.sort { $0.item.date > $1.item.date }
        // 去重 url
        var seen = Set<String>()
        var out: [(code: String, item: NewsItem)] = []
        for p in pairs {
            if !seen.contains(p.item.url) {
                seen.insert(p.item.url)
                out.append(p)
                if out.count >= 10 { break }
            }
        }
        return out
    }

    /// 显示用：code → name 映射；从 holdings + watchlist + indices 合并
    private var nameMap: [String: String] {
        var m: [String: String] = [:]
        for p in model.holdings?.positions ?? [] { m[p.code] = p.name }
        for q in model.watchlist {
            if let c = q.code { m[c] = q.name }
        }
        for q in model.indices {
            if let c = q.code { m[c] = q.name }
        }
        return m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            HStack {
                Text("今日热点")
                    .font(DS.sectionTitle)
                Spacer()
                if !topNews.isEmpty {
                    Text("\(topNews.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if topNews.isEmpty {
                if model.newsByCode.isEmpty {
                    loadingState
                } else {
                    emptyState
                }
            } else {
                ForEach(topNews, id: \.item.url) { pair in
                    newsRow(code: pair.code, item: pair.item)
                    Divider().opacity(0.4)
                }
            }
        }
        .padding(DS.spaceL)
        .cardStyle(padding: 0)
    }

    private func newsRow(code: String, item: NewsItem) -> some View {
        Button {
            NotificationCenter.default.post(
                name: .switchToNewsTab,
                object: NewsJumpPayload(code: code, url: item.url)
            )
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: DS.spaceS) {
                    TagBadge(text: nameMap[code] ?? code, color: .accentColor)
                    Text(item.date)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let src = item.source {
                        Text(src)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loadingState: some View {
        VStack(spacing: DS.spaceS) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.08))
                    .frame(height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.06))
                    .frame(width: 80, height: 8)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: DS.spaceS) {
            Image(systemName: "newspaper")
                .font(.system(size: 20))
                .foregroundStyle(.tertiary)
            Text("暂无新闻")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }
}

/// 点击新闻时跨 Tab 传 (code, url)
struct NewsJumpPayload {
    let code: String
    let url: String
}
```

- [ ] **Step 3: NewsTab 监听跳转**

Modify `Sources/StockBar/Views/NewsTab.swift`，在根 view body 末尾追加：

```swift
.onReceive(NotificationCenter.default.publisher(for: .switchToNewsTab)) { note in
    if let payload = note.object as? NewsJumpPayload {
        model.selectNewsStock(code: payload.code)
        model.newsSelectedURL = payload.url
        model.requestArticle(url: payload.url)
    }
}
```

注：`selectNewsStock` 已存在于 AppModel（line 101）。`newsSelectedURL` 已是 @Published var。`requestArticle` 已存在。无需改 AppModel。

- [ ] **Step 4: 构建 + 视觉验证**

```bash
bash scripts/build.sh
```

启动 App：
- 「今日」Tab 三栏齐了；右栏 "今日热点"
- 显示前 10 条新闻，每条：标题 + 股票 chip + 日期 + 来源
- 没数据时显示骨架（3 个灰条）
- 点新闻 → 切到「新闻」Tab + 选中该股 + 打开该篇

---

## Task 9: QuantTab 监听 quantHighlightOrderId 滚动 + 高亮

**Files:**
- Modify: `Sources/StockBar/Views/QuantTab.swift`（在订单表所在的 ScrollViewReader 区域加 onChange 处理）

- [ ] **Step 1: 找到订单表的 ScrollView，包成 ScrollViewReader**

读 QuantTab.swift 定位"订单清单"那段。预期结构（具体行号实施时再定位）：

```swift
ScrollView {
    LazyVStack {
        ForEach(orders) { o in
            QuantOrderRow(...)
                .id(o.id)            // ← 加 id 锚点
        }
    }
}
```

包成：

```swift
ScrollViewReader { proxy in
    ScrollView {
        LazyVStack {
            ForEach(orders) { o in
                QuantOrderRow(...)
                    .id(o.id)
                    .background(
                        highlightBg(for: o.id)
                    )
            }
        }
    }
    .onChange(of: model.quantHighlightOrderId) { _, newId in
        guard let id = newId else { return }
        withAnimation(.easeInOut(duration: 0.4)) {
            proxy.scrollTo(id, anchor: .center)
        }
        // 1 秒后清空 highlight
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if model.quantHighlightOrderId == id {
                model.quantHighlightOrderId = nil
            }
        }
    }
}

@ViewBuilder
private func highlightBg(for id: String) -> some View {
    if model.quantHighlightOrderId == id {
        RoundedRectangle(cornerRadius: 6)
            .fill(DS.accent.opacity(0.18))
            .transition(.opacity)
    } else {
        Color.clear
    }
}
```

注：如果 QuantTab 当前没用 `ForEach` 直接遍历 orders（例如分了 sell/buy 两段），则在两段都加 `.id` + `.background`。

- [ ] **Step 2: 构建 + 视觉验证**

```bash
bash scripts/build.sh
```

启动 App，进「今日」Tab，点量化建议某条订单：
- 切到「量化」Tab
- 列表滚动到该订单居中
- 该订单 1s 内有淡蓝色高亮背景
- 1s 后高亮消失

---

## Task 10: 响应式布局验证

**Files:** 无新增改动；仅人工验证

- [ ] **Step 1: 缩窄窗口验证**

启动 App，把主窗口宽度从 1200 拖到 700：
- ≥ 960：三栏并排（grid `.adaptive(minimum: 280)` 给 3 列）
- 660-960：折回 2 列
- < 660：折回 1 列

Hero 卡片始终全宽不折。

- [ ] **Step 2: 验证 Hero 在窄窗口下不挤压**

Hero 内 HStack 已经用 `Spacer(minLength: DS.spaceXL)`，若 mini 指标三列在窄窗下挤压严重，把右侧三列改成：

```swift
if geometry.size.width > 800 {
    // 三列水平
} else {
    // 单列或两列
}
```

但 `geometry` 增加复杂度，且窗口最小宽度由 MainContentView 设的 `minWidth: 980` 保底——所以**实际不会出现 < 800 的情况**，不动 Hero 即可。

Step 2 仅在拖动看到挤压时才动；正常情况跳过。

---

## Task 11: 状态完整性（loading / empty / error）

**Files:** 无新增改动；走查并补缺

- [ ] **Step 1: 按 spec Section 5 走查 5 个降级场景**

| 场景 | 触发方式 | 期望表现 |
|------|----------|----------|
| helper 未启动 | App 启动后立即看 | Hero 显示 "--"，三栏分别 skeleton |
| snapshot 失败 | 把 portfolio.json 改成非法 JSON | Hero 显示 "刷新失败" 文案 |
| quant 跑挂 | 等 quant 超时 | 量化卡片显示红色 banner |
| 单 chart 失败 | 把某 index code 改成不存在 | 该 mini 分时显示 "分时加载中" |
| news 全空 | 清空 newsByCode | 右栏 loading skeleton |

如果哪个场景没正确降级，回到对应子 view 加 if 分支补缺。

- [ ] **Step 2: 构建并改回 portfolio.json**

```bash
bash scripts/build.sh
```

确保改坏的 portfolio.json 已经改回原样。

---

## Task 12: 视觉打磨 + 暗色模式

**Files:** `TodayTab.swift`（视觉微调）

- [ ] **Step 1: 暗色模式视觉走查**

系统设置切换深色模式，进「今日」Tab：
- 所有色彩走 `DS.*` 静态色或系统 dynamic color → 自动适配
- 重点检查：
  - Hero `tintBg(for:)` 在深色背景下是否够轻盈
  - mini 分时染色面积是否还能看清
  - TagBadge / ChangeChip 在深色背景对比度

- [ ] **Step 2: 间距 / 字号微调**

主观调整，原则：
- 标题之间留够呼吸（`DS.spaceM` 起步）
- 数字字号梯度：Hero 主数 40 → mini 指标 18 → 列表行内 13
- 卡片之间 `DS.spaceL`（16pt）

- [ ] **Step 3: 最终构建**

```bash
bash scripts/build.sh
```

Expected：`Build complete!` 无 warning（除了 QuantTab 既有的 isActive unused warning，那个不在本期范围内）。

---

## 整体验收

按 spec Section 7 验收清单逐条勾：

- [ ] App 启动默认进入「今日」Tab
- [ ] Hero 卡片正确显示今日盈亏（红涨绿跌、ChangeChip 方向正确）
- [ ] 持仓为空时 Hero 降级为"现金 + 加持仓 CTA"
- [ ] 量化卡片显示评分前 5 订单，点击跳量化 Tab 并高亮
- [ ] 大盘卡片显示 4 个指数 + mini 分时；点击跳大盘 Tab 并选中
- [ ] 热点卡片显示前 10 条新闻；点击跳新闻 Tab 并打开
- [ ] 窗口宽 < 960 时三栏折回
- [ ] 暗色模式正常

全过即可向用户演示。
