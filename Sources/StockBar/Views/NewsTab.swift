import SwiftUI
import WebKit

struct NewsTab: View {
    @EnvironmentObject private var model: AppModel

    private var selectedCode: String? { model.newsSelectedCode }
    private var selectedURL: String? { model.newsSelectedURL }

    /// 把 持仓 + 自选 合并成统一的「可看新闻的股票」列表。
    /// 持仓 + 自选 都为空时显示空状态。
    private var allStocks: [StockRef] {
        var seen = Set<String>()
        var out: [StockRef] = []
        for p in model.holdings?.positions ?? [] {
            if seen.insert(p.code).inserted {
                out.append(.init(code: p.code, name: p.name, kind: .holding))
            }
        }
        for q in model.watchlist {
            guard let code = q.code else { continue }
            if seen.insert(code).inserted {
                out.append(.init(code: code, name: q.name, kind: .watch))
            }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "新闻",
                subtitle: subtitleText,
                counter: selectedNewsCount,
                onRefresh: refresh,
                timestamp: shortTime(model.lastUpdated)
            )

            if allStocks.isEmpty {
                EmptyStateCard(
                    icon: "newspaper",
                    title: "暂无可看新闻的股票",
                    hint: "在持仓或自选里加一只，App 会自动同步"
                )
                .padding(DS.spaceXL)
                Spacer()
            } else {
                chipStrip
                Divider()
                HSplitView {
                    newsListPane
                        .frame(minWidth: 340, idealWidth: 420)
                    detailPane
                        .frame(minWidth: 360)
                }
            }
        }
        .onAppear(perform: autoSelectFirstStockIfNeeded)
        .onChange(of: allStocks) { _, _ in autoSelectFirstStockIfNeeded() }
        .onReceive(NotificationCenter.default.publisher(for: .switchToNewsTab)) { note in
            if let payload = note.object as? NewsJumpPayload {
                model.selectNewsStock(code: payload.code)
                model.newsSelectedURL = payload.url
                model.requestArticle(url: payload.url)
            }
        }
    }

    /// 进入页面时如果还没选股票，默认选第一只（持仓优先，没持仓就第一个自选）。
    private func autoSelectFirstStockIfNeeded() {
        guard model.newsSelectedCode == nil, let first = allStocks.first else { return }
        model.selectNewsStock(code: first.code)
    }

    private var subtitleText: String {
        if let code = selectedCode, let s = allStocks.first(where: { $0.code == code }) {
            return "\(s.name) \(s.code)"
        }
        return "持仓 + 自选 个股资讯"
    }

    private var selectedNewsCount: String? {
        guard let code = selectedCode, let items = model.newsByCode[code] else { return nil }
        return "\(items.count) 条"
    }

    // MARK: - 顶部 Chip 横条

    private var chipStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.spaceS) {
                ForEach(allStocks) { s in
                    StockChip(
                        stock: s,
                        selected: selectedCode == s.code
                    )
                    .onTapGesture { model.selectNewsStock(code: s.code) }
                }
            }
            .padding(.horizontal, DS.spaceXL)
            .padding(.vertical, DS.spaceM)
        }
        .background(DS.surface.opacity(0.4))
    }

    // MARK: - 中：新闻列表（下拉刷新）

    private var newsListPane: some View {
        Group {
            if let code = selectedCode {
                if let items = model.newsByCode[code] {
                    if items.isEmpty {
                        ContentUnavailableView(
                            "暂无相关新闻",
                            systemImage: "newspaper",
                            description: Text("下拉重试，或换一只股票")
                        )
                    } else {
                        ScrollView {
                            LazyVStack(spacing: DS.spaceS) {
                                ForEach(items) { item in
                                    NewsCard(item: item, selected: selectedURL == item.url)
                                        .onTapGesture {
                                            model.selectNewsArticle(url: item.url)
                                        }
                                }
                            }
                            .padding(.horizontal, DS.spaceM)
                            .padding(.vertical, DS.spaceS)
                        }
                        .refreshable { model.requestNews(code: code) }
                    }
                } else {
                    ProgressView("加载新闻…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "选一只股票看相关新闻",
                    systemImage: "hand.tap"
                )
            }
        }
        .background(DS.canvas)
    }

    // MARK: - 右：整理后的正文（不嵌 WebView）

    private var detailPane: some View {
        Group {
            if let url = selectedURL {
                if let article = model.articleByURL[url] {
                    ArticleView(article: article) {
                        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
                    }
                } else {
                    VStack(spacing: DS.spaceM) {
                        ProgressView()
                        Text("正在抓取正文…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "点击左侧新闻查看正文",
                    systemImage: "doc.text",
                    description: Text("App 会自动抓取、清洗并展示原文")
                )
            }
        }
    }

    // MARK: - 行为

    private func refresh() {
        if let code = selectedCode {
            model.requestNews(code: code)
        } else {
            model.refreshAllNews()
        }
    }

    private func shortTime(_ ts: String?) -> String? {
        guard let ts else { return nil }
        return ts.split(separator: " ").last.map(String.init)
    }
}

// MARK: - 模型：股票引用

private struct StockRef: Identifiable, Hashable {
    let code: String
    let name: String
    let kind: Kind

    var id: String { code }

    enum Kind { case holding, watch }
}

// MARK: - Chip

private struct StockChip: View {
    let stock: StockRef
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: stock.kind == .holding ? "briefcase.fill" : "star.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(selected ? .white : DS.accent)
            Text(stock.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(selected ? .white : .primary)
            Text(stock.code)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(selected ? .white.opacity(0.75) : .secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(selected ? DS.accent : DS.surface)
        )
        .overlay(
            Capsule().strokeBorder(DS.border.opacity(selected ? 0 : 0.7), lineWidth: 0.5)
        )
        .contentShape(Capsule())
        .animation(.easeInOut(duration: 0.12), value: selected)
    }
}

// MARK: - 新闻条目卡

private struct NewsCard: View {
    let item: NewsItem
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title)
                .font(.system(size: 13.5, weight: .medium))
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .foregroundColor(.primary)
            HStack(spacing: 6) {
                Text(formattedDate(item.date))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                if let src = item.source, !src.isEmpty {
                    Text("·").foregroundStyle(.tertiary)
                    Text(src)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(DS.spaceM)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                .fill(selected ? DS.accent.opacity(0.14) : DS.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.radiusS, style: .continuous)
                .strokeBorder(selected ? DS.accent.opacity(0.5) : DS.border.opacity(0.5),
                              lineWidth: selected ? 1 : 0.5)
        )
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.12), value: selected)
    }

    private func formattedDate(_ raw: String) -> String {
        let parts = raw.split(separator: " ")
        guard parts.count == 2 else { return raw }
        let date = parts[0].split(separator: "-")
        let time = parts[1].split(separator: ":")
        guard date.count == 3, time.count >= 2 else { return raw }
        return "\(date[1])-\(date[2]) \(time[0]):\(time[1])"
    }
}

// MARK: - WKWebView 包装（自动 HTTPS 升级 + 加载指示器 + 失败 fallback）

struct NewsWebView: View {
    let url: URL

    @State private var isLoading = true
    @State private var loadError: String?
    @State private var webViewRef: WKWebView?

    var body: some View {
        ZStack(alignment: .top) {
            WebViewContainer(
                url: secureURL,
                isLoading: $isLoading,
                loadError: $loadError,
                webViewRef: $webViewRef
            )

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, DS.spaceL)
            }

            if let err = loadError {
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
                    Button("在浏览器打开") {
                        NSWorkspace.shared.open(secureURL)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(DS.spaceXL)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: DS.radiusM))
                .padding(DS.spaceXL)
            }
        }
    }

    /// 把 http:// 升级成 https:// — 大部分新闻站都同时支持。
    private var secureURL: URL {
        guard url.scheme == "http",
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        comps.scheme = "https"
        return comps.url ?? url
    }
}

private struct WebViewContainer: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadError: String?
    @Binding var webViewRef: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let conf = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: conf)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.load(URLRequest(url: url))
        DispatchQueue.main.async { webViewRef = webView }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if webView.url?.absoluteString != url.absoluteString {
            DispatchQueue.main.async {
                isLoading = true
                loadError = nil
            }
            webView.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WebViewContainer
        init(_ parent: WebViewContainer) { self.parent = parent }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
            parent.loadError = nil
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.loadError = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
            parent.loadError = error.localizedDescription
        }
    }
}
