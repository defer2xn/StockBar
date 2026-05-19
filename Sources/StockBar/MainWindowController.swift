import AppKit
import SwiftUI

/// 主窗口控制器：用 NSWindow 承载 SwiftUI 根视图。
/// 关闭窗口只是隐藏，App 仍驻留菜单栏。
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private let appModel: AppModel
    private let portfolio: PortfolioStore
    private(set) var window: NSWindow

    init(appModel: AppModel, portfolio: PortfolioStore) {
        self.appModel = appModel
        self.portfolio = portfolio

        let initialRect = NSRect(x: 0, y: 0, width: 1280, height: 760)
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let win = NSWindow(
            contentRect: initialRect,
            styleMask: style,
            backing: .buffered,
            defer: false
        )
        win.title = "StockBar"
        win.titlebarAppearsTransparent = false
        win.minSize = NSSize(width: 1100, height: 600)
        win.center()
        win.setFrameAutosaveName("StockBarMainWindow")
        win.isReleasedWhenClosed = false   // 关闭不要释放

        let root = MainContentView()
            .environmentObject(appModel)
            .environmentObject(portfolio)
        win.contentView = NSHostingView(rootView: root)

        self.window = win
        super.init()
        win.delegate = self
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // 打开窗口时把新闻 / 分时一起预拉一遍
        appModel.refreshAllNews()
        appModel.refreshAllCharts()
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // 用户点关闭，只隐藏；下次 show() 还能弹出
        sender.orderOut(nil)
        return false
    }
}
