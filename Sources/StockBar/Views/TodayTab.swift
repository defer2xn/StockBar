import SwiftUI

// MARK: - 跨 Tab 跳转通知

extension Notification.Name {
    static let switchToQuantTab = Notification.Name("StockBar.switchToQuantTab")
    static let switchToIndicesTab = Notification.Name("StockBar.switchToIndicesTab")
    static let switchToNewsTab = Notification.Name("StockBar.switchToNewsTab")
}

/// 点击新闻时跨 Tab 传 (code, url)
struct NewsJumpPayload {
    let code: String
    let url: String
}

// MARK: - 「今日」Tab 根视图

/// 启动默认页：Hero（盈亏大数）+ 三栏（量化建议 / 大盘 mini 分时 / 今日热点）。
/// 所有数据复用 AppModel 既有 @Published 字段，零新 helper API。
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
                    TodayHero()
                    threeColumnGrid
                }
                .padding(.horizontal, DS.spaceXL)
                .padding(.bottom, DS.spaceXL)
                .padding(.top, DS.spaceM)
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

    private var threeColumnGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280, maximum: .infinity), spacing: DS.spaceL)],
            alignment: .leading,
            spacing: DS.spaceL
        ) {
            OrderShortlistCard()
            IndicesGridCard()
            HotNewsCard()
        }
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
            HStack(spacing: DS.spaceXL) {
                miniStat(title: "总市值", value: formatMoney(h.totalMarketValue))
                miniStat(title: "持仓", value: "\(h.positions.count) 只")
                miniStat(title: "现金", value: formatMoney(h.cash ?? 0))
            }
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
                .fill(DS.tintBg(for: h.totalPnlToday))
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

// MARK: - 量化建议卡片

private struct OrderShortlistCard: View {
    @EnvironmentObject private var model: AppModel

    private var allOrders: [QuantOrder] {
        model.quantSnapshot?.orders ?? []
    }

    /// 取 score 倒排前 5；score 相同时 sell 优先（持仓信号更紧急）
    private var topOrders: [QuantOrder] {
        Array(
            allOrders.sorted { a, b in
                let sa = a.score ?? 0
                let sb = b.score ?? 0
                if sa != sb { return sa > sb }
                return a.isSell && !b.isSell
            }.prefix(5)
        )
    }

    private var buyCount: Int { allOrders.filter { !$0.isSell }.count }
    private var sellCount: Int { allOrders.filter { $0.isSell }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            header
            content
        }
        .padding(DS.spaceL)
        .cardStyle(padding: 0)
    }

    @ViewBuilder
    private var content: some View {
        if model.quantLoading && model.quantSnapshot == nil {
            ProgressView("量化扫描中…")
                .frame(maxWidth: .infinity, minHeight: 160)
        } else if let err = model.quantError {
            errorBanner(err)
        } else if topOrders.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                ForEach(topOrders) { o in
                    orderRow(o)
                    if o.id != topOrders.last?.id {
                        Divider().opacity(0.3)
                    }
                }
            }
            viewAllLink
        }
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
            NotificationCenter.default.post(name: .switchToQuantTab, object: nil)
        } label: {
            HStack(spacing: DS.spaceS) {
                actionBadge(o)
                    .frame(width: 56, alignment: .leading)
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
                    .frame(width: 56, alignment: .trailing)
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

// MARK: - 今日热点新闻卡片

private struct HotNewsCard: View {
    @EnvironmentObject private var model: AppModel

    /// 合并所有 newsByCode 条目，按 date desc 去重（url）取前 10
    private var topNews: [(code: String, item: NewsItem)] {
        var pairs: [(code: String, item: NewsItem)] = []
        for (code, items) in model.newsByCode {
            for item in items {
                pairs.append((code: code, item: item))
            }
        }
        pairs.sort { $0.item.date > $1.item.date }
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

    /// code → name 映射，从 holdings / watchlist / indices 合并
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
            content
        }
        .padding(DS.spaceL)
        .cardStyle(padding: 0)
    }

    @ViewBuilder
    private var content: some View {
        if topNews.isEmpty {
            if model.newsByCode.isEmpty {
                loadingState
            } else {
                emptyState
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(topNews.enumerated()), id: \.element.item.url) { idx, pair in
                    newsRow(code: pair.code, item: pair.item)
                    if idx != topNews.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
            }
        }
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
                    if let src = item.source, !src.isEmpty {
                        Text(src)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var loadingState: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            ForEach(0..<3, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.10))
                        .frame(height: 12)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.06))
                        .frame(width: 100, height: 8)
                }
            }
        }
        .padding(.vertical, 4)
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
