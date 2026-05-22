import Foundation

/// 管理 Python helper 子进程的生命周期、IPC 与崩溃自动重启。
///
/// 协议（每行一条）：
///   - 命令: `refresh` / `news <code>` / `chart <code>` / `quit`
///   - 响应: 一行 JSON，含 `type` 字段（snapshot / news / chart）
///
/// 所有响应通过 `onResponse` 回调到主线程。
final class HelperProcess {
    private let pythonExecutable: URL
    private let scriptURL: URL
    private let portfolioPath: String
    private let onResponse: (HelperResponse) -> Void

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutBuffer = Data()
    private var restartAttempts = 0
    private var pendingCommands: [String] = []

    init(
        pythonExecutable: URL,
        scriptURL: URL,
        portfolioPath: String,
        onResponse: @escaping (HelperResponse) -> Void
    ) {
        self.pythonExecutable = pythonExecutable
        self.scriptURL = scriptURL
        self.portfolioPath = portfolioPath
        self.onResponse = onResponse
    }

    // MARK: - Lifecycle

    func start() {
        guard process == nil else { return }
        spawn()
    }

    func stop() {
        if let pipe = stdinPipe {
            _ = try? pipe.fileHandleForWriting.write(contentsOf: Data("quit\n".utf8))
            try? pipe.fileHandleForWriting.close()
        }
        process?.terminate()
        process = nil
        stdinPipe = nil
    }

    func requestRefresh() { send("refresh") }
    func requestNews(code: String, name: String) { send("news \(code) \(name)") }
    func requestChart(code: String) { send("chart \(code)") }
    func requestArticle(url: String) { send("article \(url)") }
    func requestSectors() { send("sectors") }
    /// analyze <code> [cost_price] [shares]：cost/shares 仅持仓传
    func requestAnalyze(code: String, costPrice: Double?, shares: Double?) {
        if let c = costPrice {
            send("analyze \(code) \(c) \(Int(shares ?? 0))")
        } else {
            send("analyze \(code)")
        }
    }
    func requestQuant() { send("quant") }
    func requestHealth() { send("health") }

    private func send(_ command: String) {
        guard let pipe = stdinPipe else {
            // 还没启动好，先攒着；spawn 完后会一次性发出
            pendingCommands.append(command)
            return
        }
        do {
            try pipe.fileHandleForWriting.write(contentsOf: Data((command + "\n").utf8))
        } catch {
            NSLog("[StockBar] write to helper stdin failed: \(error)")
            restartAfterCrash()
        }
    }

    // MARK: - Private

    private func spawn() {
        let proc = Process()
        proc.executableURL = pythonExecutable
        proc.arguments = [scriptURL.path]

        var env = ProcessInfo.processInfo.environment
        env["STOCKBAR_PORTFOLIO"] = portfolioPath
        env["PYTHONUNBUFFERED"] = "1"
        proc.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendStdout(data)
        }

        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
            // 一次可能有多行，原样打印
            NSLog("[StockBar.helper] %@", s.trimmingCharacters(in: .newlines))
        }

        proc.terminationHandler = { [weak self] _ in
            NSLog("[StockBar] helper exited")
            DispatchQueue.main.async { self?.restartAfterCrash() }
        }

        do {
            try proc.run()
        } catch {
            NSLog("[StockBar] failed to launch helper: \(error)")
            return
        }

        process = proc
        stdinPipe = stdin
        restartAttempts = 0

        let pending = pendingCommands
        pendingCommands.removeAll()
        for cmd in pending { send(cmd) }
    }

    private func restartAfterCrash() {
        guard process != nil else { return }   // 主动 stop() 不要重启
        process = nil
        stdinPipe = nil
        stdoutBuffer.removeAll()

        restartAttempts += 1
        let delay = min(pow(2.0, Double(restartAttempts)), 30.0)
        NSLog("[StockBar] respawning helper in \(delay)s (attempt \(restartAttempts))")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.spawn()
        }
    }

    private func appendStdout(_ data: Data) {
        stdoutBuffer.append(data)
        while let nl = stdoutBuffer.firstIndex(of: 0x0A) {
            let lineData = stdoutBuffer.subdata(in: 0..<nl)
            stdoutBuffer.removeSubrange(0...nl)
            handleLine(lineData)
        }
    }

    private func handleLine(_ data: Data) {
        guard !data.isEmpty else { return }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let resp = try decoder.decode(HelperResponse.self, from: data)
            DispatchQueue.main.async { [weak self] in self?.onResponse(resp) }
        } catch {
            let raw = String(data: data, encoding: .utf8) ?? "<binary>"
            NSLog("[StockBar] decode failed: \(error)\n  raw: \(raw)")
        }
    }
}
