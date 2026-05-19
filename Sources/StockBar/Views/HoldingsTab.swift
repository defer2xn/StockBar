import SwiftUI

struct HoldingsTab: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var portfolio: PortfolioStore
    @State private var selectedCode: String?
    @State private var sheet: ActiveSheet?

    private var positions: [Position] { model.holdings?.positions ?? [] }
    private var holdings: Holdings? { model.holdings }

    enum ActiveSheet: Identifiable {
        case addPosition
        case editPosition(PortfolioStore.Position)
        case editCash
        var id: String {
            switch self {
            case .addPosition: return "add"
            case .editPosition(let p): return "edit-\(p.code)"
            case .editCash: return "cash"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "持仓",
                subtitle: holdingsSubtitle,
                counter: positions.isEmpty ? nil : "\(positions.count) 只",
                onRefresh: { model.requestRefresh() },
                timestamp: shortTime(model.lastUpdated),
                addLabel: "加持仓",
                onAdd: { sheet = .addPosition }
            )

            ScrollView {
                VStack(spacing: DS.spaceL) {
                    summaryRow
                    if !positions.isEmpty {
                        positionsCard
                    } else {
                        EmptyStateCard(
                            icon: "tray",
                            title: "当前空仓",
                            hint: "点击右上角「加持仓」开始记录"
                        )
                    }
                    chartCard
                }
                .padding(.horizontal, DS.spaceXL)
                .padding(.bottom, DS.spaceXL)
            }
            .refreshable {
                model.requestRefresh()
                if let code = selectedCode { model.requestChart(code: code) }
            }
        }
        .sheet(item: $sheet) { active in
            switch active {
            case .addPosition:
                PositionEditorSheet(editing: nil)
                    .environmentObject(portfolio)
                    .environmentObject(model)
            case .editPosition(let p):
                PositionEditorSheet(editing: p)
                    .environmentObject(portfolio)
                    .environmentObject(model)
            case .editCash:
                CashEditorSheet()
                    .environmentObject(portfolio)
            }
        }
    }

    private var holdingsSubtitle: String {
        guard let h = holdings else { return "—" }
        let mv = formatMoney(h.totalMarketValue)
        let cash = formatMoney(h.cash ?? 0)
        return "总市值 \(mv)  ·  剩余资金 \(cash)"
    }

    // MARK: - 汇总卡片

    private var summaryRow: some View {
        let h = holdings
        return HStack(spacing: DS.spaceM) {
            HeroCard(
                title: "总市值",
                value: formatMoney(h?.totalMarketValue ?? 0),
                tint: .primary,
                bg: DS.surface
            )
            HeroCard(
                title: "今日盈亏",
                value: Optional(h?.totalPnlToday ?? 0).signedMoneyString(),
                subtitle: h?.totalPnlTodayPct.pctString() ?? "—",
                tint: DS.tint(for: h?.totalPnlToday),
                bg: DS.tintBg(for: h?.totalPnlToday)
            )
            HeroCard(
                title: "投入成本",
                value: formatMoney(h?.totalCost ?? 0),
                tint: .secondary,
                bg: DS.surface
            )
            HeroCard(
                title: "剩余资金",
                value: formatMoney(h?.cash ?? 0),
                tint: .secondary,
                bg: DS.surface
            )
            .overlay(alignment: .topTrailing) {
                Button {
                    sheet = .editCash
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(6)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
                .help("编辑剩余资金")
            }
        }
    }

    // MARK: - 持仓列表（卡片化的 List 行）

    private var positionsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("持仓明细")
                    .font(DS.sectionTitle)
                Spacer()
            }
            .padding(.horizontal, DS.spaceL)
            .padding(.top, DS.spaceM)
            .padding(.bottom, DS.spaceS)

            // 表头
            PositionHeader()
                .padding(.horizontal, DS.spaceL)
                .padding(.bottom, 4)
            Divider()

            ForEach(positions) { p in
                PositionRow(
                    position: p,
                    selected: selectedCode == p.code
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    selectedCode = p.code
                    model.requestChart(code: p.code)
                }
                .contextMenu {
                    Button("编辑…") { editPosition(code: p.code) }
                    Button("删除", role: .destructive) {
                        portfolio.removePosition(code: p.code)
                    }
                }
                if p.id != positions.last?.id {
                    Divider().padding(.leading, DS.spaceL)
                }
            }
        }
        .cardStyle(padding: 0)
    }

    // MARK: - 分时图卡片

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let code = selectedCode, let chart = model.chartByCode[code] {
                IntradayChartView(data: chart)
                    .padding(DS.spaceL)
            } else if selectedCode != nil {
                ProgressView("加载分时…")
                    .frame(maxWidth: .infinity, minHeight: 240)
            } else {
                ContentUnavailableView(
                    "点选上方任一持仓查看分时",
                    systemImage: "chart.xyaxis.line"
                )
                .frame(minHeight: 240)
            }
        }
        .cardStyle(padding: 0)
    }

    private func shortTime(_ ts: String?) -> String? {
        guard let ts else { return nil }
        return ts.split(separator: " ").last.map(String.init)
    }

    /// 在 portfolio store 里按 code 找到 position 并触发编辑 sheet。
    private func editPosition(code: String) {
        guard let p = portfolio.positions.first(where: { $0.code == code }) else { return }
        sheet = .editPosition(p)
    }
}

// MARK: - 汇总 Hero 卡

private struct HeroCard: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var tint: Color = .primary
    var bg: Color = DS.surface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DS.cardTitle)
                .foregroundStyle(.secondary)
                .textCase(nil)
            Text(value)
                .font(DS.hero(26))
                .foregroundColor(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let s = subtitle {
                Text(s)
                    .font(DS.subnumber(12))
                    .foregroundColor(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.spaceL)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                .fill(bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                .strokeBorder(DS.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: DS.cardShadow, radius: 4, x: 0, y: 1)
    }
}

// MARK: - 持仓表头 / 行

private struct PositionHeader: View {
    var body: some View {
        HStack(spacing: 0) {
            HeaderCell("代码").frame(width: 70, alignment: .leading)
            HeaderCell("名称").frame(width: 110, alignment: .leading)
            HeaderCell("现价").frame(width: 70, alignment: .trailing)
            HeaderCell("涨跌").frame(width: 80, alignment: .trailing)
            HeaderCell("持仓").frame(width: 90, alignment: .trailing)
            HeaderCell("成本价").frame(width: 70, alignment: .trailing)
            HeaderCell("市值").frame(width: 100, alignment: .trailing)
            HeaderCell("今日盈亏").frame(maxWidth: .infinity, alignment: .trailing)
            HeaderCell("总盈亏").frame(width: 100, alignment: .trailing)
        }
    }

    private struct HeaderCell: View {
        let text: String
        init(_ text: String) { self.text = text }
        var body: some View {
            Text(text)
                .font(.caption.weight(.medium))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct PositionRow: View {
    let position: Position
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text(position.code).monospaced().font(.system(size: 12))
                .frame(width: 70, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(position.name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)
            Text(position.price.priceString(decimals: 3))
                .font(DS.tabular)
                .foregroundColor(DS.tint(for: position.changePct))
                .frame(width: 70, alignment: .trailing)
            ChangeChip(value: position.changePct, compact: true)
                .frame(width: 80, alignment: .trailing)
            Text(position.shares.map { sharesString($0) } ?? "—")
                .font(DS.tabular)
                .frame(width: 90, alignment: .trailing)
            Text(position.costPrice.priceString(decimals: 3))
                .font(DS.tabular)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(position.marketValue.map { String(format: "%.0f", $0) } ?? "—")
                .font(DS.tabular)
                .frame(width: 100, alignment: .trailing)
            Text(position.pnlToday.signedMoneyString())
                .font(DS.tabular)
                .foregroundColor(DS.tint(for: position.pnlToday))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(position.pnlTotal.signedMoneyString())
                .font(DS.tabular)
                .foregroundColor(DS.tint(for: position.pnlTotal))
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.horizontal, DS.spaceL)
        .padding(.vertical, 10)
        .background(selected ? DS.accent.opacity(0.10) : Color.clear)
    }

    private func sharesString(_ s: Double) -> String {
        if s == s.rounded() { return String(Int(s)) }
        return String(format: "%.2f", s)
    }
}

// MARK: - 空状态卡

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: DS.spaceM) {
            Image(systemName: icon)
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title)
                .font(.system(.headline))
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.space2XL)
        .cardStyle()
    }
}
