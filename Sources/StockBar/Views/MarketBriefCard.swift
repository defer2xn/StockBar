import SwiftUI

/// 大盘研判卡：方向徽章 + 一句话研判 + 关键点位。数据来自 analyze 000001（上证）。
struct MarketBriefCard: View {
    let analysis: StockAnalysis?
    let isLoading: Bool

    var body: some View {
        HStack(spacing: DS.spaceL) {
            if let a = analysis, !a.hasError {
                badge(a.verdict)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(a.name)研判 · \(a.reason)")
                        .font(.system(size: 13, weight: .semibold))
                    if !a.signals.isEmpty {
                        Text(a.signals.joined(separator: "  ·  "))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                levels(a)
            } else if isLoading {
                ProgressView().controlSize(.small)
                Text("正在研判大盘…").font(.callout).foregroundStyle(.secondary)
                Spacer()
            } else {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("大盘研判暂不可用").font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(.vertical, DS.spaceM)
        .padding(.horizontal, DS.spaceL)
        .frame(maxWidth: .infinity)
        .cardStyle()
    }

    private func badge(_ v: String) -> some View {
        let color: Color = v == "多" ? DS.up : v == "空" ? DS.down : DS.flat
        return Text(v)
            .font(.system(size: 16, weight: .bold))
            .foregroundColor(.white)
            .frame(width: 34, height: 34)
            .background(Circle().fill(color))
    }

    private func levels(_ a: StockAnalysis) -> some View {
        HStack(spacing: DS.spaceL) {
            cell("支撑", a.levels.support)
            cell("压力", a.levels.resistance)
        }
    }

    private func cell(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(DS.label).foregroundStyle(.tertiary)
            Text(value.priceString(decimals: 2))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}
