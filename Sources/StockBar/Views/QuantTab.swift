import SwiftUI

/// 量化 Tab：扫描 + 评分 + 生成可粘到券商的订单表 + 详细操作介绍
/// 数据由 helper/quant.py 计算，盘中 5 分钟自动刷新（盘外 30min），UI 顶部可手动刷新。
struct QuantTab: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedOrderID: String?
    @State private var sortMode: SortMode = .actionThenScore

    enum SortMode: String, CaseIterable, Identifiable {
        case actionThenScore = "操作优先"
        case scoreDesc       = "评分 ↓"
        case scoreAsc        = "评分 ↑"
        case rrDesc          = "盈亏比 ↓"
        case codeAsc         = "代码 ↑"

        var id: String { rawValue }
    }

    private var snap: QuantSnapshot? { model.quantSnapshot }
    private var selectedOrder: QuantOrder? {
        guard let id = selectedOrderID else { return nil }
        return snap?.orders.first { $0.id == id }
    }

    /// 根据 sortMode 排序的订单列表
    private var sortedOrders: [QuantOrder] {
        guard let s = snap else { return [] }
        switch sortMode {
        case .actionThenScore:
            // 卖单优先（按 score asc），买单按 score desc
            let sells = s.orders.filter { $0.isSell }.sorted { ($0.score ?? 0) < ($1.score ?? 0) }
            let buys  = s.orders.filter { !$0.isSell }.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            return sells + buys
        case .scoreDesc:
            return s.orders.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        case .scoreAsc:
            return s.orders.sorted { ($0.score ?? 0) < ($1.score ?? 0) }
        case .rrDesc:
            // 卖单（无 RR）排末尾
            return s.orders.sorted {
                let a = $0.rr ?? -1, b = $1.rr ?? -1
                return a > b
            }
        case .codeAsc:
            return s.orders.sorted { $0.code < $1.code }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "量化",
                subtitle: subtitleText,
                counter: orderCounter,
                onRefresh: { model.requestQuant() },
                timestamp: snap.map { shortTime($0.ts) }
            )

            // 健康检查不通过（vnpy 不可达）→ banner 警告，不阻塞 UI 但提醒
            if model.quantHealthy == false {
                healthBanner
            }

            if model.quantLoading && snap == nil {
                loadingView
            } else if let err = model.quantError, snap == nil {
                errorView(err)
            } else if let s = snap {
                content(s)
            } else {
                ContentUnavailableView(
                    "首次扫描中…",
                    systemImage: "function",
                    description: Text("候选 + 持仓全量扫描需要 30-60s")
                )
            }
        }
        .onChange(of: snap?.orders.first?.id) { _, newID in
            // 数据刷新后保留旧选中（若不存在则选 Top1）
            if let sel = selectedOrderID,
               !(snap?.orders.contains(where: { $0.id == sel }) ?? false) {
                selectedOrderID = newID
            } else if selectedOrderID == nil {
                selectedOrderID = newID
            }
        }
    }

    private var subtitleText: String {
        guard let s = snap else { return "等待数据" }
        return "\(s.session) · 市场 \(s.market) · 持仓 \(s.summary.holdingsCount) 只 · 现金 \(formatMoney(s.summary.cash))"
    }

    private var orderCounter: String? {
        guard let s = snap, !s.orders.isEmpty else { return nil }
        return "\(s.orders.count) 笔（\(s.summary.buys) 买 / \(s.summary.sells) 卖）"
    }

    // MARK: - 主体

    @ViewBuilder
    private func content(_ s: QuantSnapshot) -> some View {
        VSplitView {
            topPane(s)
                .frame(minHeight: 200, idealHeight: 360)
            detailPane
                .frame(minHeight: 220, idealHeight: 320)
        }
    }

    // MARK: - 上栏：状态条 + 订单表

    @ViewBuilder
    private func topPane(_ s: QuantSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.spaceM) {
                if model.quantLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("后台扫描中…").font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, DS.spaceXL)
                }
                if !s.notes.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle").foregroundColor(.orange)
                        Text(s.notes.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.horizontal, DS.spaceXL)
                }
                if s.orders.isEmpty {
                    EmptyStateCard(
                        icon: "tray.fill",
                        title: "无可成交订单",
                        hint: "候选未通过短线评分门槛或盈亏比 (≥1.5) 校验；下次刷新再试"
                    ).padding(.horizontal, DS.spaceXL)
                } else {
                    orderTable(sortedOrders)
                        .padding(.horizontal, DS.spaceXL)
                }
                footerRow(s)
                    .padding(.horizontal, DS.spaceXL)
                    .padding(.bottom, DS.spaceL)
            }
        }
        .refreshable {
            model.requestQuant()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    private func orderTable(_ orders: [QuantOrder]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.spaceM) {
                Text("订单清单").font(DS.sectionTitle)
                Spacer()
                // 排序 picker
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.caption2).foregroundStyle(.tertiary)
                    Picker("排序", selection: $sortMode) {
                        ForEach(SortMode.allCases) { m in
                            Text(m.rawValue).tag(m)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 110)
                }
                Text("点击行查看详情").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, DS.spaceL)
            .padding(.top, DS.spaceM)
            .padding(.bottom, DS.spaceS)

            OrderHeader(activeSort: sortMode)
                .padding(.horizontal, DS.spaceL).padding(.bottom, 4)
            Divider()

            ForEach(Array(orders.enumerated()), id: \.element.id) { idx, o in
                OrderRow(index: idx + 1, order: o, selected: selectedOrderID == o.id)
                    .onTapGesture { selectedOrderID = o.id }
                if o.id != orders.last?.id {
                    Divider().padding(.leading, DS.spaceL)
                }
            }
        }
        .cardStyle(padding: 0)
    }

    private func footerRow(_ s: QuantSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.spaceXS) {
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange)
                Text("单日波动 > ATR% 撤单观望 · 大盘单日跌 > 1.5% 全撤 · 价格基于 \(shortTime(s.ts)) 数据")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: MarketSession.isOpen ? "clock.fill" : "clock")
                    .font(.caption2).foregroundStyle(.tertiary)
                Text(MarketSession.isOpen ? "盘中：每 5 分钟自动刷新" : "盘外：每 30 分钟刷新")
                    .font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                if !s.orders.isEmpty {
                    Text("候选扫描 \(s.summary.candidatesScanned ?? 0) 只")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 下栏：详情面板

    @ViewBuilder
    private var detailPane: some View {
        if let o = selectedOrder {
            OrderDetailView(order: o)
        } else {
            ContentUnavailableView(
                "点上方任一订单看详细操作介绍",
                systemImage: "doc.text.magnifyingglass"
            )
        }
    }

    // MARK: - 健康检查 banner

    private var healthBanner: some View {
        HStack(alignment: .top, spacing: DS.spaceS) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("量化引擎环境不完整")
                    .font(.subheadline.weight(.semibold))
                ForEach(model.quantHealthErrors, id: \.self) { e in
                    Text("· \(e)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("设置 STOCKBAR_VNPY_PATH 环境变量或在 ~/Library/Application Support/StockBar/config.json 写 vnpy_path")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(DS.spaceM)
        .background(Color.orange.opacity(0.10))
        .cornerRadius(DS.radiusS)
        .padding(.horizontal, DS.spaceXL)
        .padding(.bottom, DS.spaceS)
    }

    // MARK: - Loading / Error

    private var loadingView: some View {
        VStack(spacing: DS.spaceL) {
            ProgressView().controlSize(.large)
            Text("量化引擎首次扫描…").font(.headline)
            Text("拉 40+ 候选标的 K 线 / 实时报价 / 算指标 / 算订单价")
                .font(.caption).foregroundStyle(.secondary)
            Text("约 30-60 秒，期间可切走做别的")
                .font(.caption2).foregroundStyle(.tertiary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorView(_ err: String) -> some View {
        VStack(spacing: DS.spaceM) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 32)).foregroundStyle(.red)
            Text("量化引擎错误").font(.headline)
            Text(err).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, DS.spaceXL)
            Button("重试") { model.requestQuant() }
                .buttonStyle(.borderedProminent)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortTime(_ ts: String) -> String {
        ts.split(separator: " ").last.map(String.init) ?? ts
    }
}

// MARK: - 表头

private struct OrderHeader: View {
    let activeSort: QuantTab.SortMode

    var body: some View {
        HStack(spacing: 0) {
            Cell("#",   width: 26,  align: .leading, indicator: nil)
            Cell("代码", width: 70,  align: .leading, indicator: activeSort == .codeAsc ? "↑" : nil)
            Cell("名称", width: 120, align: .leading, indicator: nil)
            Cell("操作", width: 70,  align: .leading, indicator: activeSort == .actionThenScore ? "·" : nil)
            Cell("数量", width: 70,  align: .trailing, indicator: nil)
            Cell("买价", width: 80,  align: .trailing, indicator: nil)
            Cell("止盈", width: 80,  align: .trailing, indicator: nil)
            Cell("止损", width: 80,  align: .trailing, indicator: nil)
            Cell("盈亏比", width: 56, align: .trailing, indicator: activeSort == .rrDesc ? "↓" : nil)
            Cell("分",   width: 36,  align: .trailing,
                 indicator: activeSort == .scoreDesc ? "↓" :
                            activeSort == .scoreAsc ? "↑" :
                            activeSort == .actionThenScore ? "·" : nil)
            Cell("信号", width: nil, align: .leading, indicator: nil)
        }
    }

    private struct Cell: View {
        let text: String
        let width: CGFloat?
        let align: Alignment
        let indicator: String?
        init(_ t: String, width: CGFloat?, align: Alignment, indicator: String?) {
            self.text = t; self.width = width; self.align = align; self.indicator = indicator
        }
        var body: some View {
            let isActive = indicator != nil
            let composed: AnyView = {
                if let i = indicator {
                    return AnyView(
                        HStack(spacing: 2) {
                            if align == .trailing {
                                Spacer(minLength: 0)
                                Text(text).font(.caption.weight(.semibold))
                                Text(i).font(.caption2.weight(.bold))
                            } else {
                                Text(text).font(.caption.weight(.semibold))
                                Text(i).font(.caption2.weight(.bold))
                            }
                        }
                        .foregroundColor(DS.accent)
                    )
                } else {
                    return AnyView(
                        Text(text).font(.caption.weight(.medium)).foregroundStyle(.tertiary)
                    )
                }
            }()
            if let w = width {
                composed.frame(width: w, alignment: align)
            } else {
                composed.frame(maxWidth: .infinity, alignment: align)
            }
        }
    }
}

// MARK: - 行

private struct OrderRow: View {
    let index: Int
    let order: QuantOrder
    let selected: Bool

    var body: some View {
        HStack(spacing: 0) {
            Text("\(index)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 26, alignment: .leading)

            Text(order.code)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(order.name)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(width: 120, alignment: .leading)

            actionBadge
                .frame(width: 70, alignment: .leading)

            Text("\(order.shares)")
                .font(DS.tabular)
                .frame(width: 70, alignment: .trailing)

            // 买价 / 卖价 + 距现价 %
            VStack(alignment: .trailing, spacing: 1) {
                Text(priceString(order.price))
                    .font(DS.tabular.weight(.semibold))
                    .foregroundColor(actionColor)
                if let pct = priceDistance {
                    Text(String(format: "%+.2f%%", pct))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 80, alignment: .trailing)

            // 止盈
            if let tp = order.tp {
                Text(priceString(tp))
                    .font(DS.tabular)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text("—").font(DS.tabular).foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }

            // 止损
            if let sl = order.sl {
                Text(priceString(sl))
                    .font(DS.tabular)
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .trailing)
            } else {
                Text("—").font(DS.tabular).foregroundStyle(.tertiary)
                    .frame(width: 80, alignment: .trailing)
            }

            // 盈亏比
            if let rr = order.rr {
                Text(String(format: "%.2f", rr))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundColor(rrColor(rr))
                    .frame(width: 56, alignment: .trailing)
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 56, alignment: .trailing)
            }

            // 评分
            if let s = order.score {
                Text("\(s)")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(scoreColor(s))
                    .frame(width: 36, alignment: .trailing)
            } else {
                Text("—").font(.caption).foregroundStyle(.tertiary)
                    .frame(width: 36, alignment: .trailing)
            }

            // 信号（原 reason）
            Text(order.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8)
        }
        .padding(.horizontal, DS.spaceL)
        .padding(.vertical, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if selected { return DS.accent.opacity(0.12) }
        if order.isSell { return DS.tintBg(for: -1) }    // 卖单浅绿底
        return .clear
    }

    @ViewBuilder
    private var actionBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: order.action == "买入" ? "arrow.down.right" : "arrow.up.right")
                .font(.system(size: 9, weight: .bold))
            Text(shortAction).font(.system(size: 11, weight: .semibold))
        }
        .foregroundColor(actionColor)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(actionColor.opacity(0.12)))
    }

    private var shortAction: String {
        switch order.action {
        case "买入": return "买入"
        case "止盈卖出": return "止盈"
        case "止损卖出": return "止损"
        case "清仓": return "清仓"
        default: return order.action
        }
    }

    private var actionColor: Color {
        switch order.action {
        case "买入", "止盈卖出": return DS.up
        case "止损卖出", "清仓": return DS.down
        default: return .secondary
        }
    }

    private func priceString(_ p: Double) -> String {
        order.isETF ? String(format: "¥%.3f", p) : String(format: "¥%.2f", p)
    }

    /// 操作价相对当前价的距离 %（买单用 buyPct，卖单用 sellPct）
    private var priceDistance: Double? {
        order.isSell ? order.sellPct : order.buyPct
    }

    private func rrColor(_ r: Double) -> Color {
        if r >= 3 { return DS.up }
        if r >= 2 { return .primary }
        return .secondary
    }

    private func scoreColor(_ s: Int) -> Color {
        if s >= 85 { return DS.up }
        if s >= 70 { return .primary }
        return .secondary
    }
}

// MARK: - 详情面板

private struct OrderDetailView: View {
    let order: QuantOrder

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.spaceL) {
                header
                priceCards
                if let dims = order.dimensions {
                    dimensionBars(dims)
                }
                if let sigs = order.signals, !sigs.isEmpty {
                    signalsSection(sigs)
                }
                if let op = order.operation {
                    operationSection(op)
                }
                if let inv = order.invalidation {
                    invalidationSection(inv)
                }
            }
            .padding(DS.spaceXL)
        }
        .background(DS.canvas)
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: DS.spaceM) {
            actionBadge
            VStack(alignment: .leading, spacing: 2) {
                Text("\(order.name)  \(order.code)")
                    .font(.system(size: 18, weight: .semibold))
                if let cp = order.currentPrice {
                    HStack(spacing: 8) {
                        Text("当前 \(priceString(cp))")
                            .font(.caption).foregroundStyle(.secondary)
                        if let ind = order.indicators {
                            Text("今日 \(String(format: "%+.2f%%", ind.changePct))")
                                .font(.caption).foregroundColor(DS.tint(for: ind.changePct))
                        }
                    }
                }
            }
            Spacer()
            if let s = order.score {
                VStack {
                    Text("\(s)")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundColor(scoreColor(s))
                    Text("短线评分").font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var actionBadge: some View {
        VStack(spacing: 4) {
            Image(systemName: actionIcon)
                .font(.system(size: 18, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(actionColor))
            Text(order.action)
                .font(.caption.weight(.semibold))
                .foregroundColor(actionColor)
        }
    }

    // MARK: 价格卡 (3 档 / 卖单 1 档+持仓)

    @ViewBuilder
    private var priceCards: some View {
        if order.isSell {
            sellPriceCard
        } else {
            buyPriceCards
        }
    }

    private var buyPriceCards: some View {
        HStack(spacing: DS.spaceM) {
            priceCard(
                label: "限价买入",
                value: priceString(order.price),
                sub: order.buyPct.map { String(format: "距现价 %+.2f%%", $0) },
                bg: DS.tintBg(for: 1),
                tint: DS.up
            )
            if let tp = order.tp {
                priceCard(
                    label: "止盈卖出",
                    value: priceString(tp),
                    sub: order.tpPct.map { String(format: "+%.2f%% · 收益 ¥%@", $0, fmtAmt(order.profitTarget ?? 0)) },
                    bg: DS.tintBg(for: 1),
                    tint: DS.up
                )
            }
            if let sl = order.sl {
                priceCard(
                    label: "止损卖出",
                    value: priceString(sl),
                    sub: order.slPct.map { String(format: "%.2f%% · 亏损 ¥%@", $0, fmtAmt(order.lossLimit ?? 0)) },
                    bg: DS.tintBg(for: -1),
                    tint: DS.down
                )
            }
            if let rr = order.rr {
                priceCard(
                    label: "盈亏比",
                    value: String(format: "%.2f : 1", rr),
                    sub: rrSubtitle(rr),
                    bg: DS.surface,
                    tint: rr >= 2 ? DS.up : .primary
                )
            }
        }
    }

    private var sellPriceCard: some View {
        HStack(spacing: DS.spaceM) {
            priceCard(
                label: order.action,
                value: priceString(order.price),
                sub: order.pnlPct.map { String(format: "成交后 %+.2f%% · ¥%@", $0, fmtAmt(order.pnlAmount ?? 0)) },
                bg: DS.tintBg(for: order.pnlPct ?? 0),
                tint: actionColor
            )
            if let cp = order.costPrice {
                priceCard(label: "持仓成本", value: priceString(cp), sub: "\(order.shares) 股", bg: DS.surface, tint: .secondary)
            }
            if let s = order.support {
                priceCard(label: "近支撑", value: priceString(s), sub: nil, bg: DS.surface, tint: .secondary)
            }
            if let r = order.resistance {
                priceCard(label: "近阻力", value: priceString(r), sub: nil, bg: DS.surface, tint: .secondary)
            }
        }
    }

    private func priceCard(label: String, value: String, sub: String?, bg: Color, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(tint).monospacedDigit()
            if let s = sub {
                Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(DS.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous).fill(bg))
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                .strokeBorder(DS.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    // MARK: 6 维评分条

    private func dimensionBars(_ d: QuantDimensions) -> some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            Text("评分细节（满分 10，加权汇总）").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 4) {
                ForEach(d.items(), id: \.0) { name, score, weight in
                    dimensionBar(name: name, score: score, weight: weight)
                }
            }
        }
    }

    private func dimensionBar(name: String, score: Int, weight: Int) -> some View {
        HStack(spacing: DS.spaceS) {
            Text(name).font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.12))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(barColor(score))
                        .frame(width: geo.size.width * CGFloat(score) / 10)
                }
            }
            .frame(height: 8)
            Text("\(score)/10").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
            Text("权\(weight)").font(.caption2).foregroundStyle(.tertiary).frame(width: 32, alignment: .trailing)
        }
    }

    private func barColor(_ s: Int) -> Color {
        if s >= 8 { return DS.up }
        if s >= 5 { return Color.orange.opacity(0.7) }
        return DS.down.opacity(0.5)
    }

    // MARK: 触发信号

    private func signalsSection(_ sigs: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("触发信号").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(sigs, id: \.self) { s in
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").foregroundStyle(.tertiary)
                        Text(s).font(.callout).foregroundStyle(.primary)
                    }
                }
            }
        }
    }

    // MARK: 操作说明

    private func operationSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet.clipboard")
                    .font(.caption).foregroundColor(DS.accent)
                Text("操作步骤").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .lineSpacing(4)
                .padding(DS.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                        .fill(DS.accent.opacity(0.06))
                )
                .textSelection(.enabled)
        }
    }

    // MARK: 失效条件

    private func invalidationSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "xmark.octagon")
                    .font(.caption).foregroundStyle(.orange)
                Text("失效条件").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            Text(text)
                .font(.callout)
                .padding(DS.spaceM)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                        .fill(Color.orange.opacity(0.08))
                )
                .textSelection(.enabled)
        }
    }

    // MARK: 辅助

    private var actionIcon: String {
        switch order.action {
        case "买入": return "arrow.down.right"
        case "止盈卖出": return "arrow.up.right.circle.fill"
        case "止损卖出": return "arrow.up.right"
        case "清仓": return "xmark.circle.fill"
        default: return "questionmark"
        }
    }

    private var actionColor: Color {
        switch order.action {
        case "买入", "止盈卖出": return DS.up
        case "止损卖出", "清仓": return DS.down
        default: return .secondary
        }
    }

    private func priceString(_ p: Double) -> String {
        order.isETF ? String(format: "¥%.3f", p) : String(format: "¥%.2f", p)
    }

    private func fmtAmt(_ v: Double) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: v)) ?? "\(Int(v))"
    }

    private func rrSubtitle(_ rr: Double) -> String {
        if rr >= 3 { return "极佳（≥3:1）" }
        if rr >= 2 { return "良好（≥2:1）" }
        return "合格（≥1.5:1）"
    }

    private func scoreColor(_ s: Int) -> Color {
        if s >= 85 { return DS.up }
        if s >= 70 { return .primary }
        return .secondary
    }
}
