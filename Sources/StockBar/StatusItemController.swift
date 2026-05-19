import AppKit
import Combine
import ServiceManagement

/// 菜单栏图标：
///   - 左/右键点击均弹出菜单（持仓 / 自选 / 大盘 / 设置 / 打开主窗口）
///   - 菜单顶部有「打开主窗口」入口，用户也可以双击 .app 打开
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let appModel: AppModel
    private let onOpenMainWindow: () -> Void
    private let menu = NSMenu()

    init(appModel: AppModel, onOpenMainWindow: @escaping () -> Void) {
        self.appModel = appModel
        self.onOpenMainWindow = onOpenMainWindow
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            let img = NSImage(systemSymbolName: "chart.line.uptrend.xyaxis",
                              accessibilityDescription: "StockBar")
            img?.isTemplate = true
            button.image = img
        }
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    // MARK: - 构建菜单

    private func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        // 顶部强调：打开主窗口
        let open = NSMenuItem(title: "打开主窗口", action: #selector(openMainWindow), keyEquivalent: "o")
        open.target = self
        open.attributedTitle = NSAttributedString(
            string: "  打开主窗口",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor,
            ]
        )
        menu.addItem(open)
        menu.addItem(.separator())

        appendHoldingsSummary(to: menu)
        menu.addItem(.separator())
        appendPositions(to: menu)
        menu.addItem(.separator())
        appendWatchlist(to: menu)
        menu.addItem(.separator())
        appendIndices(to: menu)
        menu.addItem(.separator())
        appendFooter(to: menu)
    }

    private func appendHoldingsSummary(to menu: NSMenu) {
        menu.addItem(sectionHeader("持仓盈亏" + (MarketSession.isOpen ? "" : "  · 非交易时段")))
        if let err = appModel.lastError {
            menu.addItem(disabledItem("⚠️ \(err)"))
            return
        }
        guard let h = appModel.holdings else {
            menu.addItem(disabledItem("  加载中..."))
            return
        }
        menu.addItem(disabledItem("  总市值: \(formatMoney(h.totalMarketValue))"))
        let pct = h.totalPnlTodayPct.pctString()
        menu.addItem(disabledItem("  今日盈亏: \(Optional(h.totalPnlToday).signedMoneyString())  (\(pct))"))
        if let cash = h.cash {
            menu.addItem(disabledItem("  剩余资金: \(formatMoney(cash))"))
        }
    }

    private func appendPositions(to menu: NSMenu) {
        menu.addItem(sectionHeader("持仓明细"))
        let positions = appModel.holdings?.positions ?? []
        if positions.isEmpty {
            menu.addItem(disabledItem("  (空仓)"))
            return
        }
        for p in positions {
            menu.addItem(disabledItem(formatPositionLine(p)))
        }
    }

    private func appendWatchlist(to menu: NSMenu) {
        menu.addItem(sectionHeader("自选 / 关注"))
        if appModel.watchlist.isEmpty {
            menu.addItem(disabledItem("  (无)"))
            return
        }
        for q in appModel.watchlist {
            menu.addItem(disabledItem(formatQuoteLine(q)))
        }
    }

    private func appendIndices(to menu: NSMenu) {
        menu.addItem(sectionHeader("大盘指数"))
        if appModel.indices.isEmpty {
            menu.addItem(disabledItem("  (无)"))
            return
        }
        for q in appModel.indices {
            menu.addItem(disabledItem(formatQuoteLine(q)))
        }
    }

    private func appendFooter(to menu: NSMenu) {
        if let ts = appModel.lastUpdated {
            menu.addItem(disabledItem("最后更新: \(ts)"))
        }
        let refresh = NSMenuItem(title: "立即刷新", action: #selector(refreshAction), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let launch = NSMenuItem(title: "开机自启", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)

        let quit = NSMenuItem(title: "退出 StockBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Actions

    @objc private func openMainWindow() { onOpenMainWindow() }

    @objc private func refreshAction() {
        appModel.requestRefresh()
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("[StockBar] toggle LaunchAtLogin failed: \(error)")
        }
    }

    // MARK: - 菜单条目样式

    private func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        return item
    }

    private func disabledItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        return item
    }

    private func formatPositionLine(_ p: Position) -> String {
        let priceStr = p.price.priceString(decimals: decimalsFor(code: p.code))
        let pctStr = p.changePct.pctString()
        let pnlStr = p.pnlToday.signedMoneyString()
        return "  \(p.code) \(p.name)  \(priceStr)  \(pctStr)  \(pnlStr)"
    }

    private func formatQuoteLine(_ q: Quote) -> String {
        let decimals = decimalsFor(code: q.code ?? "")
        let priceStr = q.price.priceString(decimals: decimals)
        let pctStr = q.changePct.pctString()
        let codePart = q.code.map { "\($0) " } ?? ""
        return "  \(codePart)\(q.name)  \(priceStr)  \(pctStr)"
    }

    /// ETF (15/51/56/58 开头) 用 3 位小数 (tick 0.001)；股票用 2 位 (tick 0.01)
    private func decimalsFor(code: String) -> Int {
        let isETF = code.hasPrefix("15") || code.hasPrefix("51")
                 || code.hasPrefix("56") || code.hasPrefix("58")
        return isETF ? 3 : 2
    }
}
