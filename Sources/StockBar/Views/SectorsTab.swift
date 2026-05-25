import SwiftUI

/// 「板块」Tab：新浪行业板块实时榜。
/// 顶部汇总（领涨/领跌/涨跌家数）+ 排序切换 + 热力图卡片网格。
struct SectorsTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var sortMode: SortMode = .hot

    enum SortMode: String, CaseIterable, Identifiable {
        case hot = "热度"
        case change = "涨跌幅"
        case turnover = "成交额"
        var id: String { rawValue }
    }

    private var sectors: [Sector] { model.sectors }

    /// 按涨跌幅降序（汇总用，与服务端排序一致，此处防御性重排）
    private var byChange: [Sector] {
        sectors.sorted { ($0.changePct ?? -999) > ($1.changePct ?? -999) }
    }

    /// 综合热度分：成交额 55% + 涨跌幅 30% + 领涨股涨幅 15%，跨板块 min-max 归一化到 0-100。
    private var hotScores: [String: Double] {
        guard !sectors.isEmpty else { return [:] }
        let turnovers = sectors.map { $0.turnover ?? 0 }
        let changes = sectors.map { $0.changePct ?? 0 }
        let leaders = sectors.map { $0.leaderChangePct ?? 0 }
        func norm(_ v: Double, _ arr: [Double]) -> Double {
            let lo = arr.min() ?? 0, hi = arr.max() ?? 0
            guard hi > lo else { return 0.5 }
            return (v - lo) / (hi - lo)
        }
        var out: [String: Double] = [:]
        for s in sectors {
            let score = norm(s.turnover ?? 0, turnovers) * 0.55
                + norm(s.changePct ?? 0, changes) * 0.30
                + norm(s.leaderChangePct ?? 0, leaders) * 0.15
            out[s.label] = score * 100
        }
        return out
    }

    /// 当前展示顺序
    private var displayed: [Sector] {
        switch sortMode {
        case .hot:
            let scores = hotScores
            return sectors.sorted { (scores[$0.label] ?? 0) > (scores[$1.label] ?? 0) }
        case .change:   return byChange
        case .turnover: return sectors.sorted { ($0.turnover ?? 0) > ($1.turnover ?? 0) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "板块",
                subtitle: "新浪行业",
                counter: sectors.isEmpty ? nil : "\(sectors.count) 个",
                onRefresh: { model.requestSectors() },
                timestamp: shortTime(model.sectorsUpdated),
                isRefreshing: model.sectorsLoading,
                onExportCSV: sectors.isEmpty ? nil : {
                    TableExport.saveCSV(rows: exportRows(), suggestedName: TableExport.defaultName("板块"))
                },
                onExportClipboard: sectors.isEmpty ? nil : {
                    TableExport.copyTSV(rows: exportRows())
                }
            )

            if sectors.isEmpty {
                emptyOrLoading
            } else {
                ScrollView {
                    VStack(spacing: DS.spaceL) {
                        summaryRow
                        sortBar
                        sectorGrid
                    }
                    .padding(.horizontal, DS.spaceXL)
                    .padding(.bottom, DS.spaceXL)
                }
                .refreshable { model.requestSectors() }
            }
        }
        .onAppear {
            // 首次进入（或上次为空）时自动拉一次
            if model.sectors.isEmpty && !model.sectorsLoading {
                model.requestSectors()
            }
        }
    }

    // MARK: - 空 / 加载态

    @ViewBuilder
    private var emptyOrLoading: some View {
        if model.sectorsLoading {
            ProgressView("加载板块行情…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                EmptyStateCard(
                    icon: "square.grid.2x2",
                    title: "暂无板块数据",
                    hint: "点击右上角「刷新」重新获取"
                )
                .padding(.horizontal, DS.spaceXL)
                Spacer()
            }
            .padding(.top, DS.spaceXL)
        }
    }

    // MARK: - 汇总条

    private var summaryRow: some View {
        let up = sectors.filter { ($0.changePct ?? 0) > 0 }.count
        let down = sectors.filter { ($0.changePct ?? 0) < 0 }.count
        return HStack(spacing: DS.spaceM) {
            if let top = byChange.first {
                SectorStatTile(
                    title: "领涨板块",
                    name: top.name,
                    value: top.changePct.pctString(),
                    tint: DS.tint(for: top.changePct),
                    bg: DS.tintBg(for: top.changePct)
                )
            }
            SectorStatTile(
                title: "涨跌家数",
                name: "上涨 \(up) · 下跌 \(down)",
                value: breadthText(up: up, down: down),
                tint: up >= down ? DS.up : DS.down,
                bg: DS.surface
            )
            if let bottom = byChange.last {
                SectorStatTile(
                    title: "领跌板块",
                    name: bottom.name,
                    value: bottom.changePct.pctString(),
                    tint: DS.tint(for: bottom.changePct),
                    bg: DS.tintBg(for: bottom.changePct)
                )
            }
        }
    }

    private func breadthText(up: Int, down: Int) -> String {
        let total = up + down
        guard total > 0 else { return "—" }
        return String(format: "红盘 %.0f%%", Double(up) / Double(total) * 100)
    }

    // MARK: - 排序切换

    private var sortBar: some View {
        HStack {
            Picker("排序", selection: $sortMode) {
                ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
        }
    }

    // MARK: - 板块卡片网格

    private var sectorGrid: some View {
        let scores = hotScores
        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 230), spacing: DS.spaceM)],
            spacing: DS.spaceM
        ) {
            ForEach(displayed) { SectorCard(sector: $0, hotScore: scores[$0.label]) }
        }
    }

    // MARK: - 导出

    private func exportRows() -> [[String]] {
        let scores = hotScores
        var rows: [[String]] = [["板块", "热度", "涨跌幅(%)", "公司家数", "成交额(亿)", "领涨股", "领涨股涨跌幅(%)"]]
        for s in displayed {
            rows.append([
                s.name,
                scores[s.label].map { String(format: "%.0f", $0) } ?? "",
                s.changePct.map { String(format: "%.2f", $0) } ?? "",
                String(s.count),
                s.turnover.map { String(format: "%.1f", $0 / 1e8) } ?? "",
                s.leaderName ?? "",
                s.leaderChangePct.map { String(format: "%.2f", $0) } ?? "",
            ])
        }
        return rows
    }

    private func shortTime(_ ts: String?) -> String? {
        guard let ts else { return nil }
        return ts.split(separator: " ").last.map(String.init)
    }
}

// MARK: - 汇总小卡

private struct SectorStatTile: View {
    let title: String
    let name: String
    let value: String
    var tint: Color = .primary
    var bg: Color = DS.surface

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DS.cardTitle)
                .foregroundStyle(.secondary)
            Text(name)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(DS.subnumber(14))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.spaceL)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous).fill(bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                .strokeBorder(DS.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: DS.cardShadow, radius: 4, x: 0, y: 1)
    }
}

// MARK: - 板块卡片（热力图风格）

private struct SectorCard: View {
    let sector: Sector
    var hotScore: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            HStack(alignment: .firstTextBaseline) {
                Text(sector.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: DS.spaceS)
                ChangeChip(value: sector.changePct, compact: true)
            }

            // 领涨股
            if let leader = sector.leaderName, !leader.isEmpty {
                HStack(spacing: 6) {
                    Text("领涨")
                        .font(DS.label)
                        .foregroundStyle(.tertiary)
                    Text(leader)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let lc = sector.leaderChangePct {
                        Text(Optional(lc).pctString())
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundColor(DS.tint(for: lc))
                            .monospacedDigit()
                    }
                    Spacer(minLength: 0)
                }
            }

            Divider().opacity(0.5)

            HStack(spacing: DS.spaceS) {
                if let h = hotScore {
                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 10))
                        Text(String(format: "%.0f", h))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    .foregroundColor(.orange)
                    .help("综合热度分（成交额/涨跌幅/领涨股加权）")
                }
                Text("\(sector.count) 家")
                    .font(DS.label)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(formatTurnover(sector.turnover))
                    .font(.system(size: 11, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DS.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                    .fill(DS.tintBg(for: sector.changePct))
                LinearGradient(
                    colors: [DS.tint(for: sector.changePct).opacity(0.05), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous)
                .strokeBorder(DS.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: DS.cardShadow, radius: 4, x: 0, y: 1)
    }

    /// 成交额（元）→ 亿 / 万。
    private func formatTurnover(_ v: Double?) -> String {
        guard let v, v > 0 else { return "—" }
        if v >= 1e8 { return String(format: "%.0f 亿", v / 1e8) }
        if v >= 1e4 { return String(format: "%.0f 万", v / 1e4) }
        return String(format: "%.0f", v)
    }
}
