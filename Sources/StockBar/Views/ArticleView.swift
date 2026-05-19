import SwiftUI

/// 整理后的新闻正文展示。不再使用 WKWebView，纯 SwiftUI 渲染。
struct ArticleView: View {
    let article: Article
    var onOpenInBrowser: (() -> Void)? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.spaceL) {
                if let err = article.error {
                    errorBox(err)
                } else {
                    header
                    if !article.summary.isEmpty,
                       article.summary != article.paragraphs.first {
                        summaryBox
                    }
                    paragraphs
                    if !article.images.isEmpty {
                        images
                    }
                    footer
                }
            }
            .padding(DS.spaceXL)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DS.canvas)
    }

    // MARK: - 头部

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            Text(article.title)
                .font(.system(size: 24, weight: .bold))
                .lineSpacing(4)
                .textSelection(.enabled)

            HStack(spacing: DS.spaceS) {
                if !article.source.isEmpty {
                    TagBadge(text: article.source, color: DS.accent)
                }
                if !article.author.isEmpty {
                    TagBadge(text: article.author, color: .secondary)
                }
                if !article.date.isEmpty {
                    Text(article.date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let cb = onOpenInBrowser {
                    Button {
                        cb()
                    } label: {
                        Label("浏览器打开", systemImage: "safari")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .help("跳到东方财富原文")
                }
            }
        }
    }

    // MARK: - 摘要

    private var summaryBox: some View {
        HStack(alignment: .top, spacing: DS.spaceM) {
            Rectangle()
                .fill(DS.accent)
                .frame(width: 3)
            Text(article.summary)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .textSelection(.enabled)
        }
        .padding(DS.spaceM)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                .fill(DS.accent.opacity(0.06))
        )
    }

    // MARK: - 正文段落

    private var paragraphs: some View {
        VStack(alignment: .leading, spacing: DS.spaceM) {
            ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, p in
                Text(p)
                    .font(.system(size: 15))
                    .lineSpacing(7)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
    }

    // MARK: - 图片

    private var images: some View {
        VStack(alignment: .leading, spacing: DS.spaceS) {
            ForEach(article.images, id: \.self) { src in
                if let u = URL(string: src) {
                    AsyncImage(url: u) { phase in
                        switch phase {
                        case .empty:
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        case .success(let img):
                            img.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: DS.radiusS))
                        case .failure:
                            EmptyView()
                        @unknown default:
                            EmptyView()
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Text("StockBar · 数据来自东方财富网")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.top, DS.spaceL)
    }

    private func errorBox(_ err: String) -> some View {
        VStack(spacing: DS.spaceM) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            Text("加载失败")
                .font(.headline)
            Text(err)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let cb = onOpenInBrowser {
                Button("在浏览器打开", action: cb)
                    .buttonStyle(.bordered)
            }
        }
        .padding(DS.spaceXL)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusM))
    }
}
