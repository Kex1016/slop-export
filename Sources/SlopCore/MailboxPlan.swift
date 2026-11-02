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
        // Anything Bridge adds that the plan does not know about is kept under its own name,
        // with the same clash protection as custom folders.
        return .export(target: folderTarget(components))
    }

    /// Parent for custom folders whose name clashes with an iCloud system folder (D-007).
    public static let clashParent = "Proton Folders"

    /// Top-level iCloud names a custom folder must not land on. Compared case-insensitively,
    /// because iCloud treats `archive` and `Archive` as the same folder.
    static let reservedTopLevel: Set<String> = Set(
        (systemTargets.values.compactMap(\.first) + ["INBOX", "Unfiled", clashParent]).map { $0.lowercased() })

    static func isReserved(_ name: String) -> Bool { reservedTopLevel.contains(name.lowercased()) }

    /// Custom folders keep their nesting. One whose top-level name is an iCloud system folder,
    /// `Unfiled` or `Proton Folders` itself goes under `Proton Folders/` so two folders never merge.
    static func folderTarget(_ path: [String]) -> [String] {
        if let top = path.first, isReserved(top) { return [clashParent] + path }
        return path
    }
}
