import SwiftUI

struct IndicesTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedCode: String?

    private var indices: [Quote] { model.indices }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "大盘",
                subtitle: "上证 / 深证 / 创业板 / 沪深300",
                onRefresh: { model.requestRefresh() },
                timestamp: shortTime(model.lastUpdated)
            )

            // 顶部指数卡（固定高度）+ 下方分时图填满剩余空间，避免大片空白
            VStack(spacing: DS.spaceL) {
                indexGrid
                chartCard
            }
            .padding(.horizontal, DS.spaceXL)
            .padding(.bottom, DS.spaceXL)
        }
        .onAppear { autoSelectFirst() }
        .onChange(of: indices.count) { _, _ in autoSelectFirst() }
        .onReceive(NotificationCenter.default.publisher(for: .switchToIndicesTab)) { note in
            if let code = note.object as? String {
                selectedCode = code
                model.requestChart(code: code)
            }
        }
    }

    /// 进入页面/指数加载后，默认选中第一只（上证），让分时图立即填满下方空间。
    private func autoSelectFirst() {
        guard selectedCode == nil, let first = indices.first?.code else { return }
        selectedCode = first
        model.requestChart(code: first)
    }

    private var indexGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 240), spacing: DS.spaceM)],
            spacing: DS.spaceM
        ) {
            ForEach(indices) { q in
                IndexHero(quote: q, selected: selectedCode == q.code)
                    .onTapGesture {
                        if let c = q.code {
                            selectedCode = c
                            model.requestChart(code: c)
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
                    "点选上方指数查看分时",
                    systemImage: "chart.xyaxis.line"
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardStyle(padding: 0)
    }

    private func shortTime(_ ts: String?) -> String? {
        guard let ts else { return nil }
        return ts.split(separator: " ").last.map(String.init)
    }
}

private struct IndexHero: View {
    let quote: Quote
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            HStack {
                Text(quote.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                ChangeChip(value: quote.changePct, compact: true)
            }
            Text(quote.price.priceString(decimals: 2))
                .font(DS.hero(32))
                .foregroundColor(DS.tint(for: quote.changePct))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let c = quote.code {
                Text(c.uppercased())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(DS.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                    .fill(DS.tintBg(for: quote.changePct))
                LinearGradient(
                    colors: [
                        DS.tint(for: quote.changePct).opacity(0.04),
                        Color.clear,
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous))
            }
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
