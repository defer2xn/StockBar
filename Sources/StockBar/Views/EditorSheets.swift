import SwiftUI

/// 容错数字解析：去掉逗号、空白后 parse；返回 nil 表示无效。
/// 兼容用户输入「760,716」「1,234.5」这种含千位分隔的格式。
private func parseDouble(_ s: String) -> Double? {
    Double(s.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces))
}

// MARK: - 持仓编辑

struct PositionEditorSheet: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// 传入已存在的持仓做编辑；nil 表示新增
    var editing: PortfolioStore.Position?

    @State private var code = ""
    @State private var name = ""
    @State private var sharesText = ""
    @State private var costText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceL) {
            Text(editing == nil ? "添加持仓" : "编辑持仓")
                .font(.system(size: 18, weight: .semibold))

            Form {
                LabeledContent("股票代码") {
                    TextField("如 600519 / 159742", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .disabled(editing != nil)   // 编辑时不允许改 code
                        .frame(width: 200)
                        .onChange(of: code) { _, new in
                            tryFillNameFromMarket(for: new)
                        }
                }
                LabeledContent("名称 (可选)") {
                    TextField("留空则跟随实时行情自动填充", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("持仓数 (股/份)") {
                    TextField("如 1000", text: $sharesText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
                LabeledContent("成本价") {
                    TextField("如 42.50", text: $costText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                }
            }
            .formStyle(.grouped)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if editing != nil {
                    Button(role: .destructive) {
                        portfolio.removePosition(code: code)
                        dismiss()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.spaceXL)
        .frame(width: 460)
        .onAppear { populateFromEditing() }
    }

    private func populateFromEditing() {
        guard let p = editing else { return }
        code = p.code
        name = p.name
        // 浮点比较加容差（1e-6），避免 4.9999999 被显示成 "4.9999"
        let rounded = p.shares.rounded()
        sharesText = abs(p.shares - rounded) < 1e-6 ? "\(Int(rounded))" : String(format: "%.4f", p.shares)
        costText = String(format: "%.3f", p.costPrice)
    }

    private func tryFillNameFromMarket(for code: String) {
        guard editing == nil, !code.isEmpty, name.isEmpty else { return }
        // 尝试从已有快照里找
        if let p = model.holdings?.positions.first(where: { $0.code == code }) { name = p.name; return }
        if let q = model.watchlist.first(where: { $0.code == code }), !q.name.isEmpty { name = q.name; return }
        if let q = model.indices.first(where: { $0.code == code }), !q.name.isEmpty { name = q.name; return }
    }

    private func save() {
        let cleanCode = code.trimmingCharacters(in: .whitespaces)
        guard isValidStockCode(cleanCode) else {
            error = "请输入合法的 6 位代码（沪 6/科创板 68/深 00/创业板 30/ETF 15/51/56/58）"
            return
        }
        guard let rawShares = parseDouble(sharesText), rawShares >= 1 else {
            error = "请输入有效的持仓数（≥1 股）"; return
        }
        // 强制整数：A 股 / ETF 持有单位必为整数股/份
        let rounded = rawShares.rounded()
        guard abs(rawShares - rounded) < 1e-6 else {
            error = "持仓数必须是正整数（A 股 / ETF 交易单位为股/份）"; return
        }
        guard let cost = parseDouble(costText), cost > 0 else {
            error = "请输入有效的成本价（> 0）"; return
        }
        let pos = PortfolioStore.Position(
            code: cleanCode,
            name: name.trimmingCharacters(in: .whitespaces),
            shares: rounded,
            costPrice: cost
        )
        portfolio.upsertPosition(pos)
        dismiss()
    }
}

/// 校验 6 位 A 股 / ETF 代码白名单 prefix。
/// 沪市股 6/科创板 68；深市股 00/30；ETF 15/51/56/58；指数 000/399 由其它模块处理。
private func isValidStockCode(_ s: String) -> Bool {
    guard s.count == 6, Int(s) != nil else { return false }
    let p2 = String(s.prefix(2))
    let p3 = String(s.prefix(3))
    let valid2: Set<String> = ["60", "68", "00", "30", "51", "56", "58"]
    let valid3: Set<String> = ["159"]
    return valid2.contains(p2) || valid3.contains(p3)
}

// MARK: - 自选编辑

struct WatchEditorSheet: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var editing: PortfolioStore.WatchItem?

    @State private var code = ""
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceL) {
            Text(editing == nil ? "添加自选" : "编辑自选")
                .font(.system(size: 18, weight: .semibold))

            Form {
                LabeledContent("股票代码") {
                    TextField("如 600519 / 159742", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .disabled(editing != nil)
                        .frame(width: 200)
                        .onChange(of: code) { _, new in tryFillNameFromMarket(for: new) }
                }
                LabeledContent("名称 (可选)") {
                    TextField("留空则跟随实时行情自动填充", text: $name)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                if editing != nil {
                    Button(role: .destructive) {
                        portfolio.removeWatch(code: code)
                        dismiss()
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.spaceXL)
        .frame(width: 460)
        .onAppear {
            if let w = editing { code = w.code; name = w.name }
        }
    }

    private func tryFillNameFromMarket(for code: String) {
        guard editing == nil, !code.isEmpty, name.isEmpty else { return }
        if let q = model.watchlist.first(where: { $0.code == code }), !q.name.isEmpty { name = q.name; return }
        if let p = model.holdings?.positions.first(where: { $0.code == code }) { name = p.name; return }
    }

    private func save() {
        let cleanCode = code.trimmingCharacters(in: .whitespaces)
        guard isValidStockCode(cleanCode) else {
            error = "请输入合法的 6 位代码（沪 6/科创板 68/深 00/创业板 30/ETF 15/51/56/58）"
            return
        }
        let item = PortfolioStore.WatchItem(
            code: cleanCode,
            name: name.trimmingCharacters(in: .whitespaces)
        )
        portfolio.upsertWatch(item)
        dismiss()
    }
}

// MARK: - 现金编辑

struct CashEditorSheet: View {
    @EnvironmentObject private var portfolio: PortfolioStore
    @Environment(\.dismiss) private var dismiss

    @State private var cashText = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.spaceL) {
            Text("编辑剩余资金")
                .font(.system(size: 18, weight: .semibold))

            HStack {
                Text("剩余资金 (元)")
                    .frame(width: 110, alignment: .leading)
                TextField("如 760716", text: $cashText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
            }

            if let err = error {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    guard let v = parseDouble(cashText), v >= 0 else {
                        error = "请输入有效的金额（≥0，可含逗号分隔）"; return
                    }
                    portfolio.setCash(v)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.spaceXL)
        .frame(width: 420)
        .onAppear {
            cashText = portfolio.cash == 0 ? "" : String(format: "%g", portfolio.cash)
        }
    }
}
