import SwiftUI

/// 醒目的「分析这只」入口条（持仓 / 自选共用）。选中股票且未分析时显示，引导用户触发研判。
struct AnalyzePromptBar: View {
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.spaceS) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14, weight: .semibold))
                Text(text)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Spacer(minLength: DS.spaceS)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .opacity(0.8)
            }
            .foregroundColor(.white)
            .padding(.horizontal, DS.spaceL)
            .padding(.vertical, DS.spaceM)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.radiusM, style: .continuous).fill(DS.accent)
            )
        }
        .buttonStyle(.plain)
        .help("点开看该怎么操作这只")
    }
}

/// 单股研判卡（持仓 / 自选共用）。按需触发，含 loading / 失败降级。
/// 内容：结论徽章 + 一句理由 + 关键价位 + 技术信号 + 短线评分 + 利好/利空。
struct StockAnalysisCard: View {
    let code: String
    let analysis: StockAnalysis?
    let isLoading: Bool
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            header
            if isLoading && analysis == nil {
                loading
            } else if let a = analysis, a.hasError {
                errorView(a.error ?? "分析失败")
            } else if let a = analysis {
                content(a)
            }
        }
        .padding(DS.spaceL)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    // MARK: - 头部（标题 + 关闭）

    private var header: some View {
        HStack {
            Label("研判", systemImage: "wand.and.stars")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("收起研判")
        }
    }

    private var loading: some View {
        HStack(spacing: DS.spaceS) {
            ProgressView().controlSize(.small)
            Text("正在分析…").font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.vertical, DS.spaceL)
    }

    private func errorView(_ msg: String) -> some View {
        HStack(spacing: DS.spaceS) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text("分析暂不可用：\(msg)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, DS.spaceS)
    }

    // MARK: - 正文

    private func content(_ a: StockAnalysis) -> some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            // 结论 + 理由
            HStack(alignment: .firstTextBaseline, spacing: DS.spaceS) {
                Text(a.verdict)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(verdictColor(a.verdict)))
                Text(a.reason)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
                if let s = a.score {
                    scoreBadge(s)
                }
            }

            levelsRow(a)

            if let pnl = a.pnlPct {   // 持仓浮盈亏
                HStack(spacing: 4) {
                    Text("浮动盈亏").font(DS.label).foregroundStyle(.tertiary)
                    Text(Optional(pnl).pctString())
                        .font(DS.subnumber(13))
                        .foregroundColor(DS.tint(for: pnl))
                    if let amt = a.pnlAmount {
                        Text(Optional(amt).signedMoneyString())
                            .font(DS.subnumber(13))
                            .foregroundColor(DS.tint(for: pnl))
                    }
                }
            }

            if !a.signals.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(a.signals.prefix(5), id: \.self) { sig in
                        HStack(alignment: .top, spacing: 6) {
                            Text("·").foregroundStyle(.tertiary)
                            Text(sig).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let tag = sentimentTag(a) {
                HStack(spacing: 6) {
                    Text(tag.0)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(tag.1)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(tag.1.opacity(0.14)))
                    if !a.newsSignals.isEmpty {
                        Text(a.newsSignals.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - 关键价位

    @ViewBuilder
    private func levelsRow(_ a: StockAnalysis) -> some View {
        let dec = isETF ? 3 : 2
        HStack(spacing: DS.spaceL) {
            if a.kind == "holding" {
                priceCell("止盈", a.levels.tp, dec, DS.up)
                priceCell("止损", a.levels.sl, dec, DS.down)
            } else {
                priceCell("买点", a.levels.buy, dec, DS.accent)
            }
            priceCell("支撑", a.levels.support, dec, .secondary)
            priceCell("压力", a.levels.resistance, dec, .secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, DS.spaceS)
        .padding(.horizontal, DS.spaceM)
        .background(RoundedRectangle(cornerRadius: DS.radiusS).fill(DS.surfaceRaised.opacity(0.4)))
    }

    private func priceCell(_ label: String, _ value: Double?, _ dec: Int, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(DS.label).foregroundStyle(.tertiary)
            Text(value.priceString(decimals: dec))
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundColor(value == nil ? .secondary : color)
        }
    }

    private func scoreBadge(_ s: Int) -> some View {
        let color: Color = s >= 70 ? DS.up : s >= 50 ? .orange : DS.down
        return HStack(spacing: 4) {
            Text("评分").font(DS.label).foregroundStyle(.tertiary)
            Text("\(s)")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(color)
        }
    }

    // MARK: - 工具

    private var isETF: Bool {
        code.hasPrefix("15") || code.hasPrefix("51") || code.hasPrefix("56") || code.hasPrefix("58")
    }

    /// A 股配色：买入/看多 红，止损/清仓/回避 绿（卖），止盈 橙，持有/观望 蓝。
    private func verdictColor(_ v: String) -> Color {
        switch v {
        case "买入": return DS.up
        case "止盈": return .orange
        case "止损", "清仓", "回避": return DS.down
        default: return DS.accent   // 持有 / 观望
        }
    }

    private func sentimentTag(_ a: StockAnalysis) -> (String, Color)? {
        switch a.newsSentiment {
        case "bull": return ("利好", DS.up)
        case "bear": return ("利空", DS.down)
        default: return nil
        }
    }
}
