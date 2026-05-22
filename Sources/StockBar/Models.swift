import Foundation

/// Python helper 的统一响应结构。
/// 字段按 type 分组使用：snapshot / news / chart。
struct HelperResponse: Decodable {
    let ok: Bool
    let type: String
    let ts: String
    let error: String?

    // type == "snapshot"
    let holdings: Holdings?
    let watchlist: [Quote]?
    let indices: [Quote]?

    // type == "news" or "chart"
    let code: String?

    // type == "news"
    let items: [NewsItem]?

    // type == "chart"
    let ticks: [ChartTick]?
    let prevClose: Double?
    let name: String?

    // type == "article"
    let url: String?
    let title: String?
    let summary: String?
    let date: String?
    let source: String?
    let author: String?
    let paragraphs: [String]?
    let images: [String]?

    // type == "sectors"
    let sectors: [Sector]?

    // type == "analyze"（部分字段与其它 type 复用 code/name/error）
    let kind: String?            // holding / watch / index
    let verdict: String?
    let reason: String?
    let score: Int?
    let levels: AnalysisLevels?
    let signals: [String]?
    let newsSentiment: String?
    let newsSignals: [String]?
    let pnlPct: Double?
    let pnlAmount: Double?

    // type == "quant"
    let session: String?
    let market: String?
    let orders: [QuantOrder]?
    let quantSummary: QuantSummary?
    let notes: [String]?

    // type == "health"
    let vnpyPath: String?
    let vnpyPython: String?
    let errors: [String]?
}

struct QuantOrder: Decodable, Identifiable, Equatable, Hashable {
    let code: String
    let name: String
    /// "买入" / "止盈卖出" / "止损卖出" / "清仓"
    let action: String
    let shares: Int
    let price: Double
    let type: String      // "LIMIT"
    let reason: String
    let score: Int?
    let tp: Double?
    let sl: Double?
    let rr: Double?
    let currentPrice: Double?

    // 详情字段（详情面板用）
    let dimensions: QuantDimensions?
    let signals: [String]?
    let indicators: QuantIndicators?
    let support: Double?
    let resistance: Double?
    let buyPct: Double?         // 买价距现价 % (买单)
    let tpPct: Double?          // 止盈距买价 %
    let slPct: Double?          // 止损距买价 %
    let sellPct: Double?        // 卖价距现价 % (卖单)
    let affordable: Bool?       // 当前现金能否买 100 股；false=参考订单（资金不足）
    let costTotal: Double?      // 总成本
    let profitTarget: Double?   // 触及止盈潜在收益
    let lossLimit: Double?      // 触及止损最大亏损
    let costPrice: Double?      // 仅卖单：持仓成本
    let pnlPct: Double?
    let pnlAmount: Double?
    let atrPct: Double?
    let operation: String?      // 详细操作说明（长文本）
    let invalidation: String?   // 失效条件

    var id: String { "\(action)-\(code)" }
    var isSell: Bool { action.contains("卖") || action == "清仓" }
    var isETF: Bool {
        code.hasPrefix("15") || code.hasPrefix("51") || code.hasPrefix("56") || code.hasPrefix("58")
    }
}

struct QuantDimensions: Decodable, Equatable, Hashable {
    let drawdown: Int    // 回调深度（满 10，权 25）
    let trend: Int       // 趋势强度（满 10，权 20）
    let support: Int     // 支撑接近（满 10，权 20）
    let hotness: Int     // 热点强度（满 10，权 15）
    let volume: Int      // 量价配合（满 10，权 10）
    let news: Int        // 消息面（满 10，权 10）

    static let weights: [(String, Int, Int)] = [   // (名称, 权重, 最大原始分=10)
        ("回调深度", 25, 10),
        ("趋势强度", 20, 10),
        ("支撑接近", 20, 10),
        ("热点强度", 15, 10),
        ("量价配合", 10, 10),
        ("消息面",   10, 10),
    ]

    func items() -> [(String, Int, Int)] {
        [
            ("回调深度", drawdown, 25),
            ("趋势强度", trend, 20),
            ("支撑接近", support, 20),
            ("热点强度", hotness, 15),
            ("量价配合", volume, 10),
            ("消息面",   news, 10),
        ]
    }
}

struct QuantIndicators: Decodable, Equatable, Hashable {
    let close: Double
    let ma5: Double
    let ma10: Double
    let ma20: Double
    let ma20Slope: Double      // 百分比
    let atrPct: Double
    let drawdown: Double
    let volRatio: Double
    let changePct: Double
    let high5: Double
    let low20: Double
}

struct QuantSummary: Decodable, Equatable {
    let cash: Double
    let holdingsCount: Int
    let buys: Int
    let sells: Int
    let holdCount: Int
    let candidatesScanned: Int?
}

struct QuantSnapshot: Equatable {
    let ts: String
    let session: String
    let market: String
    let orders: [QuantOrder]
    let summary: QuantSummary
    let notes: [String]
}

struct Article: Equatable, Identifiable {
    let url: String
    let title: String
    let summary: String
    let date: String
    let source: String
    let author: String
    let paragraphs: [String]
    let images: [String]
    let error: String?

    var id: String { url }
}

struct Holdings: Decodable, Equatable {
    let positions: [Position]
    let cash: Double?
    let totalMarketValue: Double
    let totalPnlToday: Double
    let totalPnlTodayPct: Double?
    let totalCost: Double
}

struct Position: Decodable, Identifiable, Equatable, Hashable {
    let code: String
    let name: String
    let shares: Double?
    let costPrice: Double?
    let price: Double?
    let changePct: Double?
    let marketValue: Double?
    let pnlToday: Double?
    let pnlTotal: Double?

    var id: String { code }
}

struct Quote: Decodable, Identifiable, Equatable, Hashable {
    let code: String?
    let name: String
    let price: Double?
    let changePct: Double?

    var id: String { code ?? name }
}

/// 单股 / 指数研判（analyze 命令结果）。
struct StockAnalysis: Equatable {
    let code: String
    let kind: String            // holding / watch / index
    let name: String
    let verdict: String         // 持仓:持有/止盈/止损/清仓; 自选:买入/观望/回避; 大盘:多/空/震荡
    let reason: String
    let score: Int?             // 0-100 短线评分（大盘为 nil）
    let levels: AnalysisLevels
    let signals: [String]
    let newsSentiment: String?  // bull / bear / neutral（大盘为 nil）
    let newsSignals: [String]
    let pnlPct: Double?         // 仅持仓
    let pnlAmount: Double?      // 仅持仓
    let error: String?

    var hasError: Bool { error != nil }
}

struct AnalysisLevels: Decodable, Equatable {
    let buy: Double?
    let tp: Double?
    let sl: Double?
    let support: Double?
    let resistance: Double?
}

/// 新浪行业板块（实时榜）。
struct Sector: Decodable, Identifiable, Equatable, Hashable {
    let label: String          // 新浪内部标识，如 "new_qczz"
    let name: String           // 板块名，如 "汽车制造"
    let count: Int             // 公司家数
    let avgPrice: Double?
    let changePct: Double?     // 板块涨跌幅（%）
    let volume: Double?        // 总成交量（股）
    let turnover: Double?      // 总成交额（元）
    let leaderCode: String?    // 领涨股 6 位代码
    let leaderName: String?    // 领涨股名称
    let leaderChangePct: Double?
    let leaderPrice: Double?

    var id: String { label }
}

struct NewsItem: Decodable, Identifiable, Equatable, Hashable {
    let title: String
    let url: String
    let date: String
    let source: String?
    let summary: String?
    let sentiment: String?   // bull / bear / neutral
    let relevance: Int?      // 2=标题含名称 / 1=含代码 / 0=泛市场

    var id: String { url }
}

struct ChartTick: Decodable, Equatable {
    let time: String   // "0930"
    let price: Double
    let volume: Int
}

struct ChartData: Equatable {
    let code: String
    let name: String
    let prevClose: Double?
    let ticks: [ChartTick]
}

/// A 股交易时段判断（北京时间 9:30-11:30 / 13:00-15:00, 周一至周五）。
enum MarketSession {
    static var isOpen: Bool {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let now = Date()
        let weekday = cal.component(.weekday, from: now) // 1=Sun, 7=Sat
        guard weekday >= 2 && weekday <= 6 else { return false }
        let comp = cal.dateComponents([.hour, .minute], from: now)
        let minutes = (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
        return (minutes >= 570 && minutes <= 690) || (minutes >= 780 && minutes <= 900)
    }
}
