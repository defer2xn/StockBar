import SwiftUI

/// 全局设计系统：色板、字号、间距、圆角、阴影。
/// 所有视图通过这里统一取，避免散落硬编码。
enum DS {

    // MARK: - 色板

    /// 主背景（适配深浅色模式）
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// 卡片背景
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// 卡片之上的强调表面（hover/selected）
    static let surfaceRaised = Color(nsColor: .underPageBackgroundColor)
    /// 1px 边框
    static let border = Color(nsColor: .separatorColor)
    /// 强调蓝（Apple system）
    static let accent = Color.accentColor

    /// A 股配色：涨红、跌绿、中性灰
    static let up = Color(red: 0.91, green: 0.27, blue: 0.31)
    static let down = Color(red: 0.20, green: 0.66, blue: 0.36)
    static let flat = Color(nsColor: .secondaryLabelColor)

    /// 涨跌染色：根据 change 返回前景色
    static func tint(for change: Double?) -> Color {
        guard let c = change else { return flat }
        if c > 0 { return up }
        if c < 0 { return down }
        return flat
    }

    /// 涨跌染色：超浅 alpha 用于背景（卡片底色）
    static func tintBg(for change: Double?) -> Color {
        guard let c = change, c != 0 else { return surface }
        return (c > 0 ? up : down).opacity(0.08)
    }

    // MARK: - 字号 / 字体

    /// 英雄数字（汇总卡片主数据、指数大数）
    static func hero(_ size: CGFloat = 34) -> Font {
        .system(size: size, weight: .semibold, design: .rounded).monospacedDigit()
    }

    /// 副数字（变化幅度、辅助指标）
    static func subnumber(_ size: CGFloat = 15) -> Font {
        .system(size: size, weight: .medium, design: .rounded).monospacedDigit()
    }

    /// 表格数字（持仓表、列对齐）
    static let tabular: Font = .system(.body, design: .rounded).monospacedDigit()

    /// 段落标题（如 "持仓 / 今日盈亏 / 大盘指数"）
    static let sectionTitle: Font = .system(.headline, design: .default)

    /// 卡片小标题
    static let cardTitle: Font = .system(.caption, design: .default).weight(.medium)

    /// 标签 / 来源 badge
    static let label: Font = .system(.caption2, design: .default)

    // MARK: - 间距

    static let spaceXS: CGFloat = 4
    static let spaceS:  CGFloat = 8
    static let spaceM:  CGFloat = 12
    static let spaceL:  CGFloat = 16
    static let spaceXL: CGFloat = 24
    static let space2XL: CGFloat = 32

    // MARK: - 圆角

    static let radiusS:  CGFloat = 6
    static let radiusM:  CGFloat = 10
    static let radiusL:  CGFloat = 14

    // MARK: - 阴影

    /// 卡片浮起阴影（极克制）
    static let cardShadow: Color = Color.black.opacity(0.06)
}


// MARK: - 通用 View 修饰符

extension View {
    /// 标准卡片样式：圆角 + 边框 + 极轻阴影。
    func cardStyle(
        background: Color = DS.surface,
        cornerRadius: CGFloat = DS.radiusM,
        padding: CGFloat? = nil
    ) -> some View {
        modifier(CardStyle(background: background,
                           cornerRadius: cornerRadius,
                           padding: padding))
    }
}

private struct CardStyle: ViewModifier {
    let background: Color
    let cornerRadius: CGFloat
    let padding: CGFloat?

    func body(content: Content) -> some View {
        Group {
            if let p = padding {
                content.padding(p)
            } else {
                content
            }
        }
        .background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(DS.border.opacity(0.6), lineWidth: 0.5)
        )
        .shadow(color: DS.cardShadow, radius: 4, x: 0, y: 1)
    }
}


// MARK: - 通用小组件

/// 涨跌幅 chip（带方向箭头 + 染色背景）
struct ChangeChip: View {
    let value: Double?
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: arrowName)
                .font(.system(size: compact ? 9 : 11, weight: .bold))
            Text(text)
                .font(.system(size: compact ? 11 : 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundColor(DS.tint(for: value))
        .padding(.horizontal, compact ? 6 : 8)
        .padding(.vertical, compact ? 2 : 3)
        .background(
            Capsule().fill(DS.tint(for: value).opacity(0.12))
        )
    }

    private var arrowName: String {
        guard let v = value else { return "minus" }
        if v > 0 { return "arrow.up" }
        if v < 0 { return "arrow.down" }
        return "minus"
    }

    private var text: String {
        guard let v = value else { return "--" }
        return String(format: "%@%.2f%%", v > 0 ? "+" : "", v)
    }
}

/// 简单徽章（来源/分类等）
struct TagBadge: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(DS.label)
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(0.12))
            )
    }
}
