import SwiftUI
import Charts

/// 今日分时图。横轴 minute index (0..241)，纵轴价格。
/// 一条昨收虚线作为参考；涨绿跌红，整体染色。
struct IntradayChartView: View {
    let data: ChartData

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            header
            chart
                .frame(minHeight: 220)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.spaceM) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(data.name.isEmpty ? data.code : data.name)
                        .font(.system(.title3, design: .default).weight(.semibold))
                    Text(data.code)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                Text("今日分时")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let last = data.ticks.last, let prev = data.prevClose {
                let pct = (last.price - prev) / prev * 100
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.3f", last.price))
                        .font(DS.hero(22))
                        .foregroundColor(DS.tint(for: pct))
                    ChangeChip(value: pct)
                }
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if data.ticks.isEmpty {
            ContentUnavailableView(
                "暂无分时数据",
                systemImage: "chart.xyaxis.line"
            )
        } else {
            Chart {
                ForEach(Array(data.ticks.enumerated()), id: \.offset) { idx, tick in
                    AreaMark(
                        x: .value("index", idx),
                        y: .value("price", tick.price)
                    )
                    .foregroundStyle(
                        LinearGradient(
                            colors: [DS.tint(for: changePct).opacity(0.25), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.linear)
                    LineMark(
                        x: .value("index", idx),
                        y: .value("price", tick.price)
                    )
                    .foregroundStyle(DS.tint(for: changePct))
                    .interpolationMethod(.linear)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
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
            }
            .chartXAxis {
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
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(.secondary.opacity(0.3))
                    AxisValueLabel()
                        .font(.caption2)
                }
            }
            // AreaMark 默认会把 0 纳入 Y 域，导致股价 26 块上下的票被压成一条直线。
            // 用真实价格范围 + 适当 padding（包含昨收线），让分时波动清晰可见。
            .chartYScale(domain: yDomain())
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 计算 Y 轴显示范围：覆盖所有 tick 价格 + 昨收线，再左右各扩 15% 给波动留余量。
    private func yDomain() -> ClosedRange<Double> {
        let prices = data.ticks.map(\.price)
        guard let lo = prices.min(), let hi = prices.max(), lo > 0 else {
            return 0...1
        }
        var minV = lo
        var maxV = hi
        if let prev = data.prevClose, prev > 0 {
            minV = min(minV, prev)
            maxV = max(maxV, prev)
        }
        let pad = max((maxV - minV) * 0.15, maxV * 0.001)
        return (minV - pad)...(maxV + pad)
    }

    private var changePct: Double? {
        guard let last = data.ticks.last?.price, let prev = data.prevClose, prev > 0 else {
            return nil
        }
        return (last - prev) / prev * 100
    }

    private func tickIndicesForLabels() -> [Int] {
        let n = data.ticks.count
        guard n > 1 else { return [0] }
        return Array(Set([0, n / 4, n / 2, (3 * n) / 4, n - 1])).sorted()
    }

    private func formatHHMM(_ s: String) -> String {
        guard s.count == 4 else { return s }
        let idx = s.index(s.startIndex, offsetBy: 2)
        return "\(s[..<idx]):\(s[idx...])"
    }
}
