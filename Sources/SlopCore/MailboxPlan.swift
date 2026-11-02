/// What slop-export does with each mailbox Bridge lists (PLAN.md, "What Bridge exposes").
public enum MailboxRole: Sendable, Hashable, Codable {
    /// Exported into the named iCloud folder.
    case export(target: [String])
    /// Bridge's virtual "All Mail": read for completeness; messages found only here go to `Unfiled`.
    case allMail
    /// Bridge's virtual "Starred": becomes the \Flagged flag, not a folder.
    case starred
    /// `Labels/*`: not exported (D-001).
    case skippedLabel
    /// A container that cannot hold mail, such as `Folders` or `Labels` themselves.
    case container
}

public enum MailboxPlan {
    /// Folder that receives messages present only in All Mail.
    public static let unfiled = ["Unfiled"]

    /// Bridge's system folders and their iCloud names.
    static let systemTargets: [String: [String]] = [
        "INBOX": ["INBOX"],
        "Sent": ["Sent Messages"],
        "Drafts": ["Drafts"],
        "Archive": ["Archive"],
        "Spam": ["Junk"],
        "Trash": ["Deleted Messages"],
    ]

    public static func role(for mailbox: ListedMailbox) -> MailboxRole {
        role(components: mailbox.components, selectable: mailbox.isSelectable)
    }

    public static func role(components: [String], selectable: Bool) -> MailboxRole {
        guard let first = components.first else { return .container }
        if components.count == 1 {
            if first.caseInsensitiveCompare("INBOX") == .orderedSame { return .export(target: ["INBOX"]) }
            if let target = systemTargets[first] { return .export(target: target) }
            if first == "All Mail" { return .allMail }
            if first == "Starred" { return .starred }
        }
        if first == "Labels" { return components.count == 1 ? .container : .skippedLabel }
        if !selectable { return .container }
        if first == "Folders" {
            guard components.count > 1 else { return .container }
            return .export(target: folderTarget(Array(components.dropFirst())))
        }
        // Anything Bridge adds that the plan does not know about is kept under its own name.
        return .export(target: components)
    }

    /// Custom folders keep their nesting. One that would land on a system folder's iCloud name
    /// (a custom folder called "Archive" or "Junk", or anything below one) goes under `Proton Folders/` instead so the
    /// two never merge.
    static func folderTarget(_ path: [String]) -> [String] {
        let reserved = Set(systemTargets.values.compactMap(\.first)).union(["Unfiled"])
        if let top = path.first, reserved.contains(top) || top.caseInsensitiveCompare("INBOX") == .orderedSame {
            return ["Proton Folders"] + path
        }
        return path
    }
}
