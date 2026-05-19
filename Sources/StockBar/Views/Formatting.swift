import SwiftUI

/// 涨跌颜色：A 股传统配色，涨红跌绿。
enum ChangeColor {
    static func color(for change: Double?) -> Color {
        guard let c = change else { return .secondary }
        if c > 0 { return Color(red: 0.85, green: 0.18, blue: 0.18) }
        if c < 0 { return Color(red: 0.12, green: 0.6, blue: 0.32) }
        return .secondary
    }
}

/// 全局货币格式化（带千位逗号，加 "元"）。
func formatMoney(_ v: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 2
    return (f.string(from: NSNumber(value: v)) ?? "\(v)") + " 元"
}

extension Optional where Wrapped == Double {
    func priceString(decimals: Int = 2) -> String {
        guard let v = self else { return "---" }
        return String(format: "%.\(decimals)f", v)
    }

    func pctString() -> String {
        guard let v = self else { return "---" }
        let sign = v > 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", v))%"
    }

    func signedMoneyString() -> String {
        guard let v = self else { return "---" }
        let sign = v > 0 ? "+" : ""
        return sign + formatMoney(v)
    }

    func moneyString() -> String {
        guard let v = self else { return "---" }
        return formatMoney(v)
    }
}
