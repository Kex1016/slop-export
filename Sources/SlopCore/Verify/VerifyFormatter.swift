import Foundation

/// Plain-text and HTML renderings of a `VerifyReport`. Folder names and Message-IDs come from
/// mail servers, so the HTML escapes everything it prints.
public enum VerifyFormatter {
    public static func text(_ report: VerifyReport) -> String {
        var lines: [String] = []
        lines.append("slop-export verify report, \(timestamp(report.generatedAt))")
        lines.append("")
        lines.append("Bridge vs export")
        var rows = [["Mailbox", "Bridge", "Scanned", "Exported", "Skipped", "Missing"]]
        for row in report.sources where countsSource(row) {
            rows.append([row.mailbox, row.bridge.map(String.init) ?? "-", row.scanned.map(String.init) ?? "-",
                         String(row.exported), String(row.skipped), String(row.missing)])
        }
        lines.append(contentsOf: table(rows))
        if let all = report.allMailCount {
            lines.append("All Mail: \(all) messages, \(report.allMailAccountedFor) in the store")
        }
        lines.append("Distinct messages in the store: \(report.distinctMessages)")
        lines.append("")
        lines.append("Target folders")
        var targetRows = [["Folder", "Expected", "mbox", "iCloud", "Missing in iCloud", "Extra in iCloud"]]
        for row in report.targets {
            targetRows.append([row.folder, String(row.expected), row.mbox.map(String.init) ?? "-",
                               row.icloud.map(String.init) ?? "-",
                               row.icloud == nil ? "-" : String(row.missingInICloud.count),
                               row.icloud == nil ? "-" : String(row.extraInICloud)])
        }
        lines.append(contentsOf: table(targetRows))

        let missing = report.targets.flatMap { row in row.missingInICloud.map { (row.folder, $0) } }
        if !missing.isEmpty {
            lines.append("")
            lines.append("Missing in iCloud")
            for (folder, message) in missing {
                lines.append("  \(folder): \(message.messageID ?? "(no Message-ID)") [\(message.hash.prefix(12))]")
            }
        }
        if !report.skipped.isEmpty {
            lines.append("")
            lines.append("Skipped on Bridge (the server would not hand them over)")
            for skip in report.skipped {
                lines.append("  \(skip.mailbox) UID \(skip.uid): \(skip.reason)")
            }
        }
        lines.append("")
        lines.append("Result: " + (report.passed ? "PASSED" : "FAILED"))
        for problem in problems(report) { lines.append("  - \(problem)") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Human-readable reasons the report did not pass. Empty when it passed.
    public static func problems(_ report: VerifyReport) -> [String] {
        var out: [String] = []
        let missing = report.sources.filter { countsSource($0) }.reduce(0) { $0 + $1.missing }
        if missing > 0 { out.append("\(missing) message(s) on Bridge are not in the export. Run export again.") }
        if let all = report.allMailCount, !report.allMailComplete {
            out.append("All Mail has \(all) messages but \(report.allMailAccountedFor) are in the store. Run export again.")
        }
        if report.mboxComplete == false {
            out.append("The Apple Mail folders do not hold the expected number of messages. Rebuild them.")
        }
        if report.icloudComplete == false {
            let count = report.targets.reduce(0) { $0 + $1.missingInICloud.count }
            out.append("\(count) message(s) are not in iCloud. Run upload again; anything iCloud refuses is in \"Not uploaded\".")
        }
        return out
    }

    public static func html(_ report: VerifyReport) -> String {
        func cell(_ s: String, numeric: Bool = false, bad: Bool = false) -> String {
            var cls: [String] = []
            if numeric { cls.append("n") }
            if bad { cls.append("bad") }
            return "<td\(cls.isEmpty ? "" : " class=\"\(cls.joined(separator: " "))\"")>\(escape(s))</td>"
        }
        var body = ""
        body += "<h1>slop-export verify report</h1>\n"
        body += "<p>\(escape(timestamp(report.generatedAt)))</p>\n"
        body += "<p class=\"result \(report.passed ? "ok" : "bad")\">\(report.passed ? "Passed" : "Failed")</p>\n"
        let problems = problems(report)
        if !problems.isEmpty {
            body += "<ul>" + problems.map { "<li>\(escape($0))</li>" }.joined() + "</ul>\n"
        }

        body += "<h2>Bridge vs export</h2>\n<table><thead><tr><th>Mailbox</th><th>Bridge</th><th>Scanned</th>"
        body += "<th>Exported</th><th>Skipped</th><th>Missing</th></tr></thead><tbody>\n"
        for row in report.sources where countsSource(row) {
            body += "<tr>" + cell(row.mailbox) + cell(row.bridge.map(String.init) ?? "–", numeric: true)
                + cell(row.scanned.map(String.init) ?? "–", numeric: true) + cell(String(row.exported), numeric: true)
                + cell(String(row.skipped), numeric: true, bad: row.skipped > 0)
                + cell(String(row.missing), numeric: true, bad: row.missing > 0) + "</tr>\n"
        }
        body += "</tbody></table>\n"
        if let all = report.allMailCount {
            body += "<p>All Mail: \(all) messages, \(report.allMailAccountedFor) in the store. "
        } else {
            body += "<p>"
        }
        body += "Distinct messages in the store: \(report.distinctMessages).</p>\n"

        body += "<h2>Target folders</h2>\n<table><thead><tr><th>Folder</th><th>Expected</th><th>Apple Mail</th>"
        body += "<th>iCloud</th><th>Missing in iCloud</th><th>Extra in iCloud</th></tr></thead><tbody>\n"
        for row in report.targets {
            body += "<tr>" + cell(row.folder) + cell(String(row.expected), numeric: true)
                + cell(row.mbox.map(String.init) ?? "–", numeric: true, bad: row.mbox.map { $0 != row.expected } ?? false)
                + cell(row.icloud.map(String.init) ?? "–", numeric: true)
                + cell(row.icloud == nil ? "–" : String(row.missingInICloud.count), numeric: true, bad: !row.missingInICloud.isEmpty)
                + cell(row.icloud == nil ? "–" : String(row.extraInICloud), numeric: true) + "</tr>\n"
        }
        body += "</tbody></table>\n"

        let missing = report.targets.flatMap { row in row.missingInICloud.map { (row.folder, $0) } }
        if !missing.isEmpty {
            body += "<h2>Missing in iCloud</h2>\n<table><thead><tr><th>Folder</th><th>Message-ID</th><th>Hash</th></tr></thead><tbody>\n"
            for (folder, message) in missing {
                body += "<tr>" + cell(folder) + cell(message.messageID ?? "(none)") + cell(String(message.hash.prefix(12))) + "</tr>\n"
            }
            body += "</tbody></table>\n"
        }
        if !report.skipped.isEmpty {
            body += "<h2>Skipped on Bridge</h2>\n<table><thead><tr><th>Mailbox</th><th>UID</th><th>Reason</th></tr></thead><tbody>\n"
            for skip in report.skipped {
                body += "<tr>" + cell(skip.mailbox) + cell(String(skip.uid), numeric: true) + cell(skip.reason) + "</tr>\n"
            }
            body += "</tbody></table>\n"
        }

        return """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>slop-export verify report</title>
            <style>
            :root { color-scheme: light dark; --fg: #1d1d1f; --bg: #fff; --line: #d2d2d7; --ok: #1a7f37; --bad: #c62828; }
            @media (prefers-color-scheme: dark) { :root { --fg: #f5f5f7; --bg: #1d1d1f; --line: #424245; --ok: #4ac26b; --bad: #ff6b6b; } }
            body { font: 14px -apple-system, system-ui, sans-serif; color: var(--fg); background: var(--bg); margin: 2rem auto; max-width: 960px; padding: 0 16px; }
            table { border-collapse: collapse; width: 100%; margin: .5rem 0 1.5rem; }
            th, td { text-align: left; padding: 4px 8px; border-bottom: 1px solid var(--line); }
            td.n { text-align: right; font-variant-numeric: tabular-nums; }
            .bad { color: var(--bad); font-weight: 600; }
            .ok { color: var(--ok); font-weight: 600; }
            .result { font-size: 1.3rem; }
            </style></head><body>
            \(body)</body></html>

            """
    }

    // MARK: Helpers

    /// Labels and container-only mailboxes are not exported, so they have nothing to compare.
    static func countsSource(_ row: VerifyReport.SourceRow) -> Bool {
        row.role != .skippedLabel && row.role != .container
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func table(_ rows: [[String]]) -> [String] {
        guard let first = rows.first else { return [] }
        var widths = first.map(\.count)
        for row in rows { for (i, cell) in row.enumerated() { widths[i] = max(widths[i], cell.count) } }
        return rows.map { row in
            "  " + row.enumerated().map { i, cell in
                i == 0 ? cell.padding(toLength: widths[i], withPad: " ", startingAt: 0)
                    : String(repeating: " ", count: widths[i] - cell.count) + cell
            }.joined(separator: "  ")
        }
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
