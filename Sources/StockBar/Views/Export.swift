import AppKit
import UniformTypeIdentifiers

/// 表格导出：把二维字符串（首行表头）导成 CSV 文件，或复制为 TSV 到剪贴板。
enum TableExport {
    /// 存为 CSV：弹系统保存面板，写 UTF-8（带 BOM，便于 Excel 正确识别中文）。
    static func saveCSV(rows: [[String]], suggestedName: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = "\u{FEFF}" + rows
            .map { $0.map(escapeCSV).joined(separator: ",") }
            .joined(separator: "\r\n")
        try? csv.data(using: .utf8)?.write(to: url)
    }

    /// 复制为 TSV 到剪贴板：方便直接粘到 Excel / 券商表格。
    static func copyTSV(rows: [[String]]) {
        let tsv = rows
            .map { line in
                // 字段里的 tab/换行替换成空格，避免破坏列对齐
                line.map {
                    $0.replacingOccurrences(of: "\t", with: " ")
                        .replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: "\t")
            }
            .joined(separator: "\n")
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(tsv, forType: .string)
    }

    /// 默认文件名：前缀_yyyyMMdd_HHmm.csv
    static func defaultName(_ prefix: String) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmm"
        return "\(prefix)_\(f.string(from: Date())).csv"
    }

    /// CSV 字段转义：含逗号/引号/换行时用引号包裹，内部引号翻倍。
    private static func escapeCSV(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
