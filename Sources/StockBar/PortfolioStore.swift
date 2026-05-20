import Foundation
import Combine

/// 用户的持仓 / 自选 / 现金 数据，持久化到 `~/Library/Application Support/StockBar/portfolio.json`。
/// 这是 App 内的单一真源 —— 旧的 持仓.md 仅在首次启动时被一次性迁移。
@MainActor
final class PortfolioStore: ObservableObject {

    struct Position: Identifiable, Codable, Hashable {
        var code: String
        var name: String
        var shares: Double
        var costPrice: Double
        /// 若整笔都是当日买入，填 costDate 即可；今日盈亏走 (现价 - costPrice)。
        var costDate: String? = nil
        /// 若是"部分今日新买 + 部分隔夜"，用 intradayShares + intradayCost 拆。
        /// 今日盈亏 = intradayShares × (现价 - intradayCost) + (shares - intradayShares) × (现价 - 昨收)
        var intradayShares: Double? = nil
        var intradayCost: Double? = nil

        var id: String { code }
    }

    struct WatchItem: Identifiable, Codable, Hashable {
        var code: String
        var name: String

        var id: String { code }
    }

    @Published private(set) var cash: Double = 0
    @Published private(set) var positions: [Position] = []
    @Published private(set) var watchlist: [WatchItem] = []

    private let url: URL
    private var didLoad = false

    /// 当 store 变化时调用（让 AppModel 触发 helper refresh）
    var onChange: (() -> Void)?

    init(fileURL: URL) {
        self.url = fileURL
        load()
    }

    var fileURL: URL { url }

    // MARK: - 加载 / 保存

    func load() {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            didLoad = true
            return
        }
        do {
            let dto = try JSONDecoder().decode(PortfolioDTO.self, from: data)
            cash = dto.cash ?? 0
            positions = dto.positions ?? []
            watchlist = dto.watchlist ?? []
        } catch {
            NSLog("[StockBar] portfolio load failed: \(error)")
        }
        didLoad = true
    }

    func save() {
        let dto = PortfolioDTO(cash: cash, positions: positions, watchlist: watchlist)
        do {
            let data = try JSONEncoder.pretty.encode(dto)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            onChange?()
        } catch {
            NSLog("[StockBar] portfolio save failed: \(error)")
        }
    }

    // MARK: - 突变

    func setCash(_ value: Double) {
        cash = max(0, value)
        save()
    }

    func upsertPosition(_ p: Position) {
        if let idx = positions.firstIndex(where: { $0.code == p.code }) {
            positions[idx] = p
        } else {
            positions.append(p)
        }
        save()
    }

    func removePosition(code: String) {
        positions.removeAll { $0.code == code }
        save()
    }

    func upsertWatch(_ w: WatchItem) {
        if let idx = watchlist.firstIndex(where: { $0.code == w.code }) {
            watchlist[idx] = w
        } else {
            watchlist.append(w)
        }
        save()
    }

    func removeWatch(code: String) {
        watchlist.removeAll { $0.code == code }
        save()
    }

    // MARK: - 首次迁移

    /// 如果 portfolio.json 不存在，但 持仓.md 存在，做一次性迁移。
    /// 注意：迁移后 .md 不再被读取，纯由 App 维护。
    func migrateFromMarkdownIfNeeded(mdPath: URL) {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        guard FileManager.default.fileExists(atPath: mdPath.path) else { return }
        guard let text = try? String(contentsOf: mdPath, encoding: .utf8) else { return }

        let parsed = MarkdownPortfolioParser.parse(text)
        cash = parsed.cash ?? 0
        positions = parsed.positions
        watchlist = parsed.watchlist
        NSLog("[StockBar] migrated portfolio from \(mdPath.path)")
        save()
    }
}

// MARK: - JSON 持久化 DTO

private struct PortfolioDTO: Codable {
    var cash: Double?
    var positions: [PortfolioStore.Position]?
    var watchlist: [PortfolioStore.WatchItem]?

    enum CodingKeys: String, CodingKey {
        case cash, positions, watchlist
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }
}

// MARK: - 持仓.md 一次性迁移解析器

private enum MarkdownPortfolioParser {
    struct Result {
        var cash: Double?
        var positions: [PortfolioStore.Position] = []
        var watchlist: [PortfolioStore.WatchItem] = []
    }

    static func parse(_ text: String) -> Result {
        var r = Result()
        var section: Section = .none

        let codeRe = try! NSRegularExpression(pattern: #"\b(\d{6})\b"#)
        let numRe = try! NSRegularExpression(pattern: #"-?\d+(?:,\d{3})*(?:\.\d+)?"#)

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if let title = sectionTitle(of: line) {
                switch title {
                case "positions":
                    if line.contains("空仓") { section = .skip } else { section = .positions }
                case "cash":
                    section = .cash
                    if let m = numRe.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                        let s = (line as NSString).substring(with: m.range).replacingOccurrences(of: ",", with: "")
                        r.cash = Double(s)
                    }
                case "watchlist":
                    section = .watchlist
                default:
                    section = .skip
                }
                continue
            }

            switch section {
            case .positions:
                if let p = parsePositionLine(line, codeRe: codeRe) { r.positions.append(p) }
            case .watchlist:
                if let w = parseWatchLine(line, codeRe: codeRe) { r.watchlist.append(w) }
            case .cash:
                if r.cash == nil,
                   let m = numRe.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                    let s = (line as NSString).substring(with: m.range).replacingOccurrences(of: ",", with: "")
                    r.cash = Double(s)
                }
            case .skip, .none:
                break
            }
        }
        return r
    }

    private enum Section { case none, positions, cash, watchlist, skip }

    private static func sectionTitle(of line: String) -> String? {
        // 形如 "段标题：尾巴"，且首字不是列表符号
        guard let first = line.unicodeScalars.first, !"-•*#".unicodeScalars.contains(first) else { return nil }
        guard let r = line.range(of: "[：:]", options: .regularExpression) else { return nil }
        let title = line[..<r.lowerBound]
        if title.contains("持仓") && !title.contains("已平仓") && !title.contains("历史") { return "positions" }
        if title.contains("剩余资金") || title.contains("现金") { return "cash" }
        if title.contains("关注") || title.contains("自选") { return "watchlist" }
        if title.contains("已平仓") || title.contains("历史") || title.contains("备注") || title.contains("已清仓") { return "skip" }
        return "skip"
    }

    private static func parsePositionLine(_ raw: String, codeRe: NSRegularExpression) -> PortfolioStore.Position? {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t"))
        let ns = line as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let m = codeRe.firstMatch(in: line, range: range) else { return nil }
        let code = ns.substring(with: m.range)

        // 名称：代码之后到第一个数字/分隔符前
        let after = ns.substring(from: m.range.location + m.range.length)
        let name = after.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: CharacterSet(charactersIn: "：:@＠ 0123456789"))
            .first?.trimmingCharacters(in: .whitespaces) ?? code

        // 数字 1 / 数字 2 出现的两个值 → cost_price + shares 推测
        let numRe = try! NSRegularExpression(pattern: #"\d+(?:\.\d+)?"#)
        let numbers = numRe.matches(in: line, range: range)
            .map { ns.substring(with: $0.range) }
            .compactMap(Double.init)
        // 去掉日期数字（开头长串）
        var nums = numbers
        if let first = nums.first, first > 9999 { nums.removeFirst() }
        var shares: Double = 0
        var cost: Double = 0
        if nums.count >= 2 {
            // 通常 第一个是成本价 第二个是金额 / 股数
            cost = nums[0]
            shares = nums[1]
            // 如果第二个看起来是"金额"（>1000），用 amount/cost 反推 shares
            if shares > 1000, cost > 0 {
                shares = shares / cost
            }
        }
        return PortfolioStore.Position(code: code, name: name, shares: shares, costPrice: cost)
    }

    private static func parseWatchLine(_ raw: String, codeRe: NSRegularExpression) -> PortfolioStore.WatchItem? {
        let line = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-•* \t"))
        let ns = line as NSString
        guard let m = codeRe.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let code = ns.substring(with: m.range)
        let after = ns.substring(from: m.range.location + m.range.length)
        let name = after.trimmingCharacters(in: .whitespaces)
        return PortfolioStore.WatchItem(code: code, name: name.isEmpty ? code : name)
    }
}
