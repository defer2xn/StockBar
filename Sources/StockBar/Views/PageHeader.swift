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

    @EnvironmentObject private var model: AppModel
    @State private var spin = false

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
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(
                            model.isRefreshing
                                ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                                : .default,
                            value: spin
                        )
                    Text(model.isRefreshing ? "刷新中" : "刷新")
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isRefreshing)
            .help("立即刷新 ⌘R")
            .keyboardShortcut("r", modifiers: .command)
            .onChange(of: model.isRefreshing) { _, refreshing in
                // 刷新开始：spin 切到 360°，配合 repeatForever 持续转
                // 刷新结束：spin 切回 0°，自然停止
                spin = refreshing
            }
        }
        .padding(.horizontal, DS.spaceXL)
        .padding(.top, DS.spaceL)
        .padding(.bottom, DS.spaceM)
    }
}
