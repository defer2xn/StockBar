import SwiftUI

struct WatchlistTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var portfolio: PortfolioStore
    @State private var selectedCode: String?
    @State private var sheet: ActiveSheet?

    private var items: [Quote] { model.watchlist }

    enum ActiveSheet: Identifiable {
        case add
        case edit(PortfolioStore.WatchItem)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let w): return "edit-\(w.code)"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "自选",
                subtitle: items.isEmpty ? "点击右上角「加自选」开始追踪" : "持续监控这些标的",
                counter: items.isEmpty ? nil : "\(items.count) 只",
                onRefresh: { model.requestRefresh() },
                timestamp: shortTime(model.lastUpdated),
                addLabel: "加自选",
                onAdd: { sheet = .add }
            )

            if items.isEmpty {
                EmptyStateCard(
                    icon: "star.slash",
                    title: "暂无自选",
                    hint: "点击右上角「加自选」开始追踪"
                )
                .padding(DS.spaceXL)
                Spacer()
            } else {
                // 顶部自选卡 + 下方分时图填满剩余空间，避免大片空白
                VStack(spacing: DS.spaceL) {
                    watchlistGrid
                    chartCard
                }
                .padding(.horizontal, DS.spaceXL)
                .padding(.bottom, DS.spaceXL)
            }
        }
        .onAppear { autoSelectFirst() }
        .onChange(of: items.count) { _, _ in autoSelectFirst() }
        .sheet(item: $sheet) { active in
            switch active {
            case .add:
                WatchEditorSheet(editing: nil)
                    .environmentObject(portfolio)
                    .environmentObject(model)
            case .edit(let w):
                WatchEditorSheet(editing: w)
                    .environmentObject(portfolio)
                    .environmentObject(model)
            }
        }
    }

    private var watchlistGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: DS.spaceM)],
            spacing: DS.spaceM
        ) {
            ForEach(items) { q in
                WatchCard(
                    quote: q,
                    selected: selectedCode == q.code
                )
                .onTapGesture {
                    if let c = q.code {
                        selectedCode = c
                        model.requestChart(code: c)
                    }
                }
                .contextMenu {
                    if let c = q.code {
                        Button("编辑…") { editWatch(code: c) }
                        Button("删除", role: .destructive) {
                            portfolio.removeWatch(code: c)
                        }
                    }
                }
            }
        }
    }

    private var chartCard: some View {
        Group {
            if let code = selectedCode, let chart = model.chartByCode[code] {
                IntradayChartView(data: chart)
                    .padding(DS.spaceL)
            } else if selectedCode != nil {
                ProgressView("加载分时…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "点选上方自选查看分时",
                    systemImage: "chart.xyaxis.line"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardStyle(padding: 0)
    }

    /// 进入页面/自选变化后，默认选中第一只，让分时图立即填满下方空间。
    private func autoSelectFirst() {
        guard selectedCode == nil, let first = items.first?.code else { return }
        selectedCode = first
        model.requestChart(code: first)
    }

    private func shortTime(_ ts: String?) -> String? {
        guard let ts else { return nil }
        return ts.split(separator: " ").last.map(String.init)
    }

    private func editWatch(code: String) {
        guard let w = portfolio.watchlist.first(where: { $0.code == code }) else { return }
        sheet = .edit(w)
    }
}

private struct WatchCard: View {
    let quote: Quote
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            HStack(alignment: .firstTextBaseline) {
                Text(quote.name)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if let c = quote.code {
                    Text(c).font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                Text(quote.price.priceString(decimals: 3))
                    .font(DS.hero(24))
                    .foregroundColor(DS.tint(for: quote.changePct))
                Spacer()
                ChangeChip(value: quote.changePct)
            }
        }
        .padding(DS.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                .fill(DS.tintBg(for: quote.changePct))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                .strokeBorder(selected ? DS.accent : DS.border.opacity(0.6),
                              lineWidth: selected ? 1.5 : 0.5)
        )
        .shadow(color: DS.cardShadow, radius: 4, x: 0, y: 1)
        .animation(.easeInOut(duration: 0.15), value: selected)
    }
}
