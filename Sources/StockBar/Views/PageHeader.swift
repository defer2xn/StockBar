import SwiftUI

/// 各页统一顶部：左侧大标题/副标题，右侧时间戳 + 操作按钮。
struct PageHeader: View {
    let title: String
    var subtitle: String? = nil
    var counter: String? = nil
    let onRefresh: () -> Void
    var timestamp: String? = nil
    /// 可选的"+"按钮（添加持仓 / 自选 等）
    var addLabel: String? = nil
    var onAdd: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .default))
                    if let c = counter {
                        Text(c)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                }
                if let s = subtitle {
                    Text(s)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let ts = timestamp {
                Text(ts)
                    .font(.system(.caption, design: .rounded).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            if let label = addLabel, let onAdd {
                Button(action: onAdd) {
                    Label(label, systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            Button(action: onRefresh) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .help("立即刷新 ⌘R")
            .keyboardShortcut("r", modifiers: .command)
        }
        .padding(.horizontal, DS.spaceXL)
        .padding(.top, DS.spaceL)
        .padding(.bottom, DS.spaceM)
    }
}
