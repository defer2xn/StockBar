import Foundation
import Combine
import AppKit

/// 整个 App 的单例数据中心。HelperProcess 的响应集中流向这里，
/// SwiftUI 视图通过 @EnvironmentObject 订阅。
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: HelperResponse?
    @Published private(set) var holdings: Holdings?
    @Published private(set) var watchlist: [Quote] = []
    @Published private(set) var indices: [Quote] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: String?
    /// snapshot 刷新是否正在进行，用于按钮转圈反馈
    @Published private(set) var isRefreshing: Bool = false
    /// 「今日」Tab 点击订单 → 量化 Tab 滚动并高亮。消费后由量化 Tab 清空。
    @Published var quantHighlightOrderId: String?

    /// code → 最新一次拉到的新闻列表
    @Published private(set) var newsByCode: [String: [NewsItem]] = [:]

    /// 正在请求新闻的 code 集合（非空 → 新闻 Tab 顶部刷新按钮转圈）
    @Published private(set) var newsLoadingCodes: Set<String> = []
    /// 新闻是否正在刷新（供 PageHeader 转圈用）
    var newsLoading: Bool { !newsLoadingCodes.isEmpty }

    /// code → 今日分时数据
    @Published private(set) var chartByCode: [String: ChartData] = [:]

    /// code → 单股/指数研判结果（含失败态）
    @Published private(set) var analysisByCode: [String: StockAnalysis] = [:]
    /// 正在分析中的 code（卡片转 loading）
    @Published private(set) var analyzingCodes: Set<String> = []

    /// 行业板块榜（按涨跌幅降序）
    @Published private(set) var sectors: [Sector] = []
    /// 板块是否正在刷新（供 PageHeader 转圈用）
    @Published private(set) var sectorsLoading: Bool = false
    /// 板块最近一次更新时间
    @Published private(set) var sectorsUpdated: String?

    /// url → 抓取并清洗后的文章正文
    @Published private(set) var articleByURL: [String: Article] = [:]

    /// 量化引擎最新一次输出（订单列表 + 时段 + 市场方向 + 汇总）
    @Published private(set) var quantSnapshot: QuantSnapshot?
    /// 量化是否正在跑（粗略状态，用于 UI loading）
    @Published private(set) var quantLoading: Bool = false
    /// 量化失败时的错误（一次性 banner）
    @Published private(set) var quantError: String?

    /// 启动健康检查结果：vnpy 是否可达 + 详细错误
    @Published private(set) var quantHealthy: Bool? = nil   // nil 表示尚未检测
    @Published private(set) var quantHealthErrors: [String] = []

    /// 新闻 Tab 当前选中的股票 code（持久化在 Model 层，切 tab / 刷新不丢）
    @Published var newsSelectedCode: String?

    /// 新闻 Tab 当前选中的文章 URL
    @Published var newsSelectedURL: String?

    private var helper: HelperProcess?
    private var refreshTimer: Timer?
    private var quantTimer: Timer?

    func bind(helper: HelperProcess) {
        self.helper = helper
    }

    // MARK: - 命令转发

    func requestRefresh() {
        isRefreshing = true
        helper?.requestRefresh()
    }

    func requestNews(code: String) {
        newsLoadingCodes.insert(code)
        helper?.requestNews(code: code, name: nameFor(code: code))
    }

    /// 大盘 / 指数代码 → 名称（新闻 Tab 大盘入口用；不在持仓/自选里）
    static let indexNames = ["000001": "上证指数", "399001": "深证成指",
                             "399006": "创业板指", "000300": "沪深300"]

    /// 从持仓 / 自选 / 指数解析股票名称（用于按名称搜新闻，提升关联度）
    private func nameFor(code: String) -> String {
        if let p = holdings?.positions.first(where: { $0.code == code }) { return p.name }
        if let q = watchlist.first(where: { $0.code == code }) { return q.name }
        if let n = Self.indexNames[code] { return n }
        return ""
    }

    /// 触发单股 / 指数研判。持仓传 costPrice + shares，自选/指数不传。
    func requestAnalyze(code: String, costPrice: Double? = nil, shares: Double? = nil) {
        analyzingCodes.insert(code)
        helper?.requestAnalyze(code: code, costPrice: costPrice, shares: shares)
    }

    func requestChart(code: String) {
        helper?.requestChart(code: code)
    }

    func requestSectors() {
        sectorsLoading = true
        helper?.requestSectors()
    }

    func requestArticle(url: String) {
        // 已抓过的不重复请求
        if articleByURL[url] != nil { return }
        helper?.requestArticle(url: url)
    }

    /// 主动触发一次量化（手动刷新按钮 / 定时器）
    func requestQuant() {
        quantLoading = true
        quantError = nil
        helper?.requestQuant()
    }

    /// 启动时跑一次健康检查（vnpy 是否可达等），快速给 UI 警告
    func requestHealthCheck() {
        helper?.requestHealth()
    }

    /// 开启量化自动刷新：盘中 5 分钟一次，盘外不自动跑（数据不变）
    func startQuantAutoRefresh() {
        scheduleQuantTimer()
        // 首次立即跑一次
        requestQuant()
    }

    private func scheduleQuantTimer() {
        // 盘中 5 分钟；盘外 30 分钟（等下次盘前/盘后切换被触发）
        let interval: TimeInterval = MarketSession.isOpen ? 300 : 1800
        // 同 interval 不重建定时器，避免每次 quant 响应到达都重置周期
        if let t = quantTimer, abs(t.timeInterval - interval) < 0.5 { return }
        quantTimer?.invalidate()
        quantTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestQuant() }
        }
    }

    /// 切换新闻 Tab 当前选中的股票：拉新闻，并清空文章选择（等新闻到了自动选第一篇）。
    func selectNewsStock(code: String) {
        newsSelectedCode = code
        newsSelectedURL = nil
        if newsByCode[code] == nil {
            requestNews(code: code)
        } else {
            autoSelectFirstNews(for: code)
        }
    }

    /// 用户点了某篇新闻
    func selectNewsArticle(url: String) {
        newsSelectedURL = url
        requestArticle(url: url)
    }

    /// 给定 code 的新闻列表加载完毕后，若当前正选这只股且未选文章，自动选第一篇。
    private func autoSelectFirstNews(for code: String) {
        guard newsSelectedCode == code, newsSelectedURL == nil else { return }
        if let first = newsByCode[code]?.first?.url {
            newsSelectedURL = first
            requestArticle(url: first)
        }
    }

    /// 一次性把持仓+自选所有 code 的新闻 / 分时刷新一遍。
    /// 用于打开新闻 Tab 或主窗口时预拉。
    func refreshAllNews() {
        for code in allTrackedCodes() {
            requestNews(code: code)
        }
    }

    func refreshAllCharts() {
        for code in allTrackedCodes() {
            helper?.requestChart(code: code)
        }
    }

    func allTrackedCodes() -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for p in holdings?.positions ?? [] where !seen.contains(p.code) {
            ordered.append(p.code)
            seen.insert(p.code)
        }
        for q in watchlist {
            if let c = q.code, !seen.contains(c) {
                ordered.append(c)
                seen.insert(c)
            }
        }
        return ordered
    }

    // MARK: - 接收响应

    func ingest(_ resp: HelperResponse) {
        lastUpdated = resp.ts
        switch resp.type {
        case "snapshot":
            isRefreshing = false
            scheduleTimer()   // 每次响应后按当前交易时段重算刷新节奏（盘前启动 → 开盘后自动提速到 10s）
            if resp.ok {
                snapshot = resp
                holdings = resp.holdings
                watchlist = resp.watchlist ?? []
                indices = resp.indices ?? []
                lastError = nil
            } else {
                lastError = resp.error
            }
        case "news":
            if let code = resp.code {
                newsLoadingCodes.remove(code)   // 无论成功失败都结束转圈
                if resp.ok {
                    newsByCode[code] = resp.items ?? []
                    autoSelectFirstNews(for: code)
                }
            }
        case "chart":
            if resp.ok, let code = resp.code {
                chartByCode[code] = ChartData(
                    code: code,
                    name: resp.name ?? "",
                    prevClose: resp.prevClose,
                    ticks: resp.ticks ?? []
                )
            }
        case "article":
            if let url = resp.url {
                articleByURL[url] = Article(
                    url: url,
                    title: resp.title ?? "",
                    summary: resp.summary ?? "",
                    date: resp.date ?? "",
                    source: resp.source ?? "",
                    author: resp.author ?? "",
                    paragraphs: resp.paragraphs ?? [],
                    images: resp.images ?? [],
                    error: resp.ok ? nil : resp.error
                )
            }
        case "analyze_pending":
            break   // 结果稍后异步到达；analyzingCodes 已在 requestAnalyze 置位
        case "analyze":
            if let code = resp.code {
                analyzingCodes.remove(code)
                analysisByCode[code] = StockAnalysis(
                    code: code,
                    kind: resp.kind ?? "",
                    name: resp.name ?? "",
                    verdict: resp.verdict ?? "",
                    reason: resp.reason ?? "",
                    score: resp.score,
                    levels: resp.levels ?? AnalysisLevels(buy: nil, tp: nil, sl: nil, support: nil, resistance: nil),
                    signals: resp.signals ?? [],
                    newsSentiment: resp.newsSentiment,
                    newsSignals: resp.newsSignals ?? [],
                    pnlPct: resp.pnlPct,
                    pnlAmount: resp.pnlAmount,
                    error: resp.ok ? nil : (resp.error ?? "分析失败")
                )
            }
        case "sectors":
            sectorsLoading = false
            if resp.ok {
                sectors = resp.sectors ?? []
                sectorsUpdated = resp.ts
            } else {
                lastError = resp.error
            }
        case "health":
            quantHealthy = resp.ok
            quantHealthErrors = resp.errors ?? []
        case "quant":
            quantLoading = false
            if resp.ok, let sum = resp.quantSummary {
                quantSnapshot = QuantSnapshot(
                    ts: resp.ts,
                    session: resp.session ?? "",
                    market: resp.market ?? "→",
                    orders: resp.orders ?? [],
                    summary: sum,
                    notes: resp.notes ?? []
                )
                quantError = nil
                scheduleQuantTimer()   // 时段切换时调整定时器节奏
            } else {
                quantError = resp.error ?? "量化引擎出错"
            }
        default:
            break
        }
    }

    // MARK: - 定时器（行情）

    func startAutoRefresh() {
        scheduleTimer()
        requestRefresh()
    }

    private func scheduleTimer() {
        let interval: TimeInterval = MarketSession.isOpen ? 10 : 300
        if let t = refreshTimer, abs(t.timeInterval - interval) < 0.5 { return }
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.requestRefresh() }
        }
    }
}
