import Foundation

public enum ProbeFormatter {
    public static func table(_ report: ProbeReport) -> String {
        var lines: [String] = []
        if !report.server.isEmpty {
            let name = report.server["name"] ?? "?"
            let version = report.server["version"] ?? "?"
            lines.append("Server: \(name) \(version)")
        }
        lines.append("Capabilities: \(report.capabilities.joined(separator: " "))")
        lines.append("")
        let width = max(report.mailboxes.map(\.path.count).max() ?? 0, 7)
        lines.append("Mailbox".padding(toLength: width, withPad: " ", startingAt: 0) + "  Messages        Size  Plan")
        for box in report.mailboxes {
            let count = box.messages.map(String.init) ?? "-"
            let size = box.size.map(byteString) ?? "-"
            lines.append(box.path.padding(toLength: width, withPad: " ", startingAt: 0)
                + "  " + count.leftPad(8) + "  " + size.leftPad(10) + "  " + describe(box.role))
        }
        lines.append("")
        lines.append("Messages in exported folders: \(report.exportedMessageCount)")
        if let all = report.allMailCount { lines.append("Messages in All Mail: \(all)") }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ role: MailboxRole) -> String {
        switch role {
        case .export(let target): return "-> " + target.joined(separator: "/")
        case .allMail: return "completeness check; extras -> " + MailboxPlan.unfiled.joined(separator: "/")
        case .starred: return "becomes the Flagged flag"
        case .skippedLabel: return "skipped (labels, D-001)"
        case .container: return "container"
        }
    }

    public static func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

extension String {
    func leftPad(_ width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}
