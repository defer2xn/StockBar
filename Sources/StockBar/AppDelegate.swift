import AppKit
import Foundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appModel = AppModel()
    private var portfolio: PortfolioStore!
    private var helper: HelperProcess?
    private var statusController: StatusItemController?
    private var mainWindowController: MainWindowController?

    /// 旧的 持仓.md 路径（只用于首次迁移）。可通过环境变量 STOCKBAR_LEGACY_MD 覆盖。
    private var legacyMarkdownPath: String {
        if let env = ProcessInfo.processInfo.environment["STOCKBAR_LEGACY_MD"], !env.isEmpty {
            return env
        }
        return (NSHomeDirectory() as NSString).appendingPathComponent("github/vnpy/持仓.md")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let resources = resourcesDirectory() else {
            fatalError("Cannot resolve Resources directory")
        }
        let helperDir = resources.appendingPathComponent("helper", isDirectory: true)
        let scriptURL = helperDir.appendingPathComponent("fetch.py")
        let venvDir = userDataDirectory().appendingPathComponent("venv", isDirectory: true)
        let pythonExe = venvDir.appendingPathComponent("bin/python")
        let portfolioURL = userDataDirectory().appendingPathComponent("portfolio.json")

        ensureVenv(at: venvDir, requirements: helperDir.appendingPathComponent("requirements.txt"))

        // 初始化 PortfolioStore + 首次迁移
        let store = PortfolioStore(fileURL: portfolioURL)
        store.migrateFromMarkdownIfNeeded(mdPath: URL(fileURLWithPath: legacyMarkdownPath))
        self.portfolio = store

        let h = HelperProcess(
            pythonExecutable: pythonExe,
            scriptURL: scriptURL,
            portfolioPath: portfolioURL.path,
            onResponse: { [weak appModel] resp in
                appModel?.ingest(resp)
            }
        )
        self.helper = h
        appModel.bind(helper: h)

        // store 变化 → 立刻刷新一次行情（持仓/自选可能变了）
        store.onChange = { [weak appModel] in
            appModel?.requestRefresh()
        }

        // 菜单栏：点击弹菜单
        statusController = StatusItemController(
            appModel: appModel,
            onOpenMainWindow: { [weak self] in self?.showMainWindow() }
        )

        h.start()
        appModel.startAutoRefresh()
        // 先跑健康检查（毫秒级），再启动量化自动刷新
        appModel.requestHealthCheck()
        appModel.startQuantAutoRefresh()
    }

    func applicationWillTerminate(_ notification: Notification) {
        helper?.stop()
    }

    /// Dock 上没有图标，但保留这个钩子：双击 .app 时再开一次主窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    // MARK: - Window

    private func showMainWindow() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController(appModel: appModel, portfolio: portfolio)
        }
        mainWindowController?.show()
    }

    // MARK: - Paths

    private func resourcesDirectory() -> URL? {
        if let url = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: url.appendingPathComponent("helper/fetch.py").path) {
            return url
        }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var candidate = exe.deletingLastPathComponent()
        for _ in 0..<5 {
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("helper/fetch.py").path) {
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        // 开发时 fallback：从当前工作目录或 $STOCKBAR_PROJECT_ROOT 找
        if let envRoot = ProcessInfo.processInfo.environment["STOCKBAR_PROJECT_ROOT"] {
            let url = URL(fileURLWithPath: envRoot)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("helper/fetch.py").path) {
                return url
            }
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        if FileManager.default.fileExists(atPath: cwd.appendingPathComponent("helper/fetch.py").path) {
            return cwd
        }
        return nil
    }

    private func userDataDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("StockBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Venv 自举

    /// 创建/更新 venv。requirements 内容变了才重装依赖（指纹比对）。
    private func ensureVenv(at venvDir: URL, requirements: URL) {
        let pythonExe = venvDir.appendingPathComponent("bin/python")
        let sentinel = venvDir.appendingPathComponent(".requirements.sha")
        let needsCreate = !FileManager.default.fileExists(atPath: pythonExe.path)
        let reqContent = (try? String(contentsOf: requirements, encoding: .utf8)) ?? ""
        let prevContent = (try? String(contentsOf: sentinel, encoding: .utf8)) ?? ""
        let needsInstall = needsCreate || (reqContent != prevContent)
        if !needsInstall { return }

        if needsCreate {
            NSLog("[StockBar] creating venv at \(venvDir.path)")
            let system = findSystemPython() ?? "/usr/bin/python3"
            run(executable: system, args: ["-m", "venv", venvDir.path])
        } else {
            NSLog("[StockBar] requirements changed, updating venv deps")
        }

        let pip = venvDir.appendingPathComponent("bin/pip").path
        if needsCreate {
            run(executable: pip, args: ["install", "--quiet", "--upgrade", "pip"])
        }
        run(executable: pip, args: ["install", "--quiet", "-r", requirements.path])
        try? reqContent.write(to: sentinel, atomically: true, encoding: .utf8)
        NSLog("[StockBar] venv ready")
    }

    private func findSystemPython() -> String? {
        for path in ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return nil
    }

    private func run(executable: String, args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            NSLog("[StockBar] run failed (\(executable)): \(error)")
        }
    }
}
