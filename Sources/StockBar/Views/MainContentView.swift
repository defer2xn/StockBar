import SwiftUI

/// 主窗口根视图：左侧 Sidebar 导航，右侧内容区。
/// 移除原来的顶 TabView，改成 macOS 原生应用形态（类似 Mail / Notes / Stocks）。
struct MainContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var section: SidebarSection? = .holdings
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar(selection: $section)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 980, minHeight: 600)
    }

    @ViewBuilder
    private var detail: some View {
        switch section {
        case .holdings:  HoldingsTab()
        case .watchlist: WatchlistTab()
        case .indices:   IndicesTab()
        case .news:      NewsTab()
        case .quant:     QuantTab()
        case .none:      HoldingsTab()
        }
    }
}

enum SidebarSection: Hashable, CaseIterable {
    case holdings, watchlist, indices, news, quant

    var title: String {
        switch self {
        case .holdings:  return "持仓"
        case .watchlist: return "自选"
        case .indices:   return "大盘"
        case .news:      return "新闻"
        case .quant:     return "量化"
        }
    }

    var symbol: String {
        switch self {
        case .holdings:  return "briefcase.fill"
        case .watchlist: return "star.fill"
        case .indices:   return "chart.bar.fill"
        case .news:      return "newspaper.fill"
        case .quant:     return "function"
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarSection?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarSection.allCases, id: \.self) { s in
                        SidebarRow(section: s)
                            .tag(s)
                    }
                } header: {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .foregroundColor(DS.accent)
                        Text("StockBar")
                            .font(.system(.headline, design: .rounded).weight(.bold))
                    }
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.sidebar)

            Divider()
            MarketStatusBar()
                .padding(DS.spaceM)
        }
    }
}

private struct SidebarRow: View {
    let section: SidebarSection

    var body: some View {
        Label {
            Text(section.title)
                .font(.system(size: 13, weight: .medium))
        } icon: {
            Image(systemName: section.symbol)
                .foregroundColor(DS.accent)
                .frame(width: 18)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 侧栏底部：市场状态

private struct MarketStatusBar: View {
    @EnvironmentObject private var model: AppModel

    private var topIndex: Quote? {
        model.indices.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            HStack(spacing: 6) {
                Circle()
                    .fill(MarketSession.isOpen ? DS.up : DS.flat)
                    .frame(width: 8, height: 8)
                Text(MarketSession.isOpen ? "交易中" : "休市")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }

            if let q = topIndex {
                HStack(alignment: .firstTextBaseline) {
                    Text(q.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(q.price.priceString(decimals: 2))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .foregroundColor(DS.tint(for: q.changePct))
                        .monospacedDigit()
                }
                ChangeChip(value: q.changePct, compact: true)
            }

            if let ts = model.lastUpdated {
                Text("更新 \(shortTime(ts))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func shortTime(_ ts: String) -> String {
        // "2026-05-18 14:23:45" → "14:23:45"
        ts.split(separator: " ").last.map(String.init) ?? ts
    }
}
