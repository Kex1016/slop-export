import Foundation

/// One place a message was seen on Bridge.
public struct MessageLocation: Codable, Hashable, Sendable {
    /// Bridge mailbox, display form (`Folders/Work`).
    public var mailbox: String
    public var uidValidity: UInt32
    public var uid: UInt32
    public var flags: [String]
    public var internalDate: IMAPDate?
}

/// A distinct message (by content hash) and everywhere it was found.
public struct MessageEntry: Codable, Hashable, Sendable {
    public var hash: String
    public var size: Int
    public var messageID: String?
    public var locations: [MessageLocation]
}

public struct MailboxState: Codable, Hashable, Sendable {
    public var path: String
    public var role: MailboxRole
    public var uidValidity: UInt32?
    /// Message count seen at the last scan.
    public var count: Int?
    /// Every message in it at the last scan has a location in the journal.
    public var complete: Bool
}

/// The append-only journal (`journal.jsonl`) that makes export resumable. Each line is one
/// event; replaying them rebuilds the state. Writes are flushed after every batch, so a crash
/// loses at most the batch in flight, and the store files for it are reused on the next run.
enum JournalEvent: Codable, Sendable {
    case mailbox(MailboxState)
    case location(hash: String, size: Int, messageID: String?, location: MessageLocation)
    /// The server would not hand this message over even on its own.
    case skipped(mailbox: String, uidValidity: UInt32, uid: UInt32, reason: String)
}

public struct SkippedMessage: Codable, Hashable, Sendable {
    public var mailbox: String
    public var uidValidity: UInt32
    public var uid: UInt32
    public var reason: String
}

/// The export's state: what has been downloaded and where each message lives.
public struct ExportState: Sendable {
    public private(set) var mailboxes: [String: MailboxState] = [:]
    public private(set) var messages: [String: MessageEntry] = [:]
    public private(set) var skipped: [SkippedMessage] = []
    /// Message-ID -> hashes, in the order they were first stored.
    private var byMessageID: [String: [String]] = [:]
    /// (mailbox, uidValidity) -> UIDs already recorded.
    private var seen: [String: [UInt32: Set<UInt32>]] = [:]

    public init() {}

    mutating func apply(_ event: JournalEvent) {
        switch event {
        case .mailbox(let state):
            if let old = mailboxes[state.path], old.uidValidity != state.uidValidity, let oldValidity = old.uidValidity {
                // UIDVALIDITY changed: Bridge rebuilt the mailbox, old UIDs mean nothing now.
                forget(mailbox: state.path, uidValidity: oldValidity)
            }
            mailboxes[state.path] = state
        case .location(let hash, let size, let messageID, let location):
            guard seen[location.mailbox, default: [:]][location.uidValidity, default: []].insert(location.uid).inserted
            else { return }
            if messages[hash] == nil, let messageID {
                byMessageID[messageID, default: []].append(hash)
            }
            messages[hash, default: MessageEntry(hash: hash, size: size, messageID: messageID, locations: [])]
                .locations.append(location)
        case .skipped(let mailbox, let uidValidity, let uid, let reason):
            guard seen[mailbox, default: [:]][uidValidity, default: []].insert(uid).inserted else { return }
            skipped.append(SkippedMessage(mailbox: mailbox, uidValidity: uidValidity, uid: uid, reason: reason))
        }
    }

    private mutating func forget(mailbox: String, uidValidity: UInt32) {
        seen[mailbox]?[uidValidity] = nil
        skipped.removeAll { $0.mailbox == mailbox && $0.uidValidity == uidValidity }
        for hash in Array(messages.keys) {
            messages[hash]!.locations.removeAll { $0.mailbox == mailbox && $0.uidValidity == uidValidity }
            if messages[hash]!.locations.isEmpty {
                if let mid = messages[hash]!.messageID { byMessageID[mid]?.removeAll { $0 == hash } }
                messages[hash] = nil
            }
        }
    }

    /// Replays `journal.jsonl` in an export folder.
    public static func load(from exportDirectory: URL) throws -> ExportState {
        try Journal(url: exportDirectory.appendingPathComponent("journal.jsonl")).load()
    }

    func hashes(forMessageID messageID: String) -> [String] {
        byMessageID[messageID] ?? []
    }

    func hasSeen(mailbox: String, uidValidity: UInt32, uid: UInt32) -> Bool {
        seen[mailbox]?[uidValidity]?.contains(uid) ?? false
    }

    func seenCount(mailbox: String, uidValidity: UInt32) -> Int {
        seen[mailbox]?[uidValidity]?.count ?? 0
    }

    /// Mailboxes whose messages become real folders in iCloud.
    func isExportMailbox(_ path: String) -> Bool {
        if case .export = mailboxes[path]?.role { return true }
        return false
    }

    /// Where a message goes: the targets of every export mailbox it is in, or `Unfiled` if it
    /// is only in All Mail (or only starred).
    public func targets(for entry: MessageEntry) -> [[String]] {
        var out: [[String]] = []
        for location in entry.locations {
            if case .export(let target) = mailboxes[location.mailbox]?.role, !out.contains(target) {
                out.append(target)
            }
        }
        return out.isEmpty ? [MailboxPlan.unfiled] : out
    }

    /// Flags to give the message in `target`: that folder's flags, plus \Flagged if the message
    /// is starred anywhere (Bridge's Starred mailbox, D-001 keeps no labels but stars survive).
    public func flags(for entry: MessageEntry, in target: [String]) -> [String] {
        var flags = Set<String>()
        var matched = false
        for location in entry.locations {
            if case .export(let t) = mailboxes[location.mailbox]?.role, t == target {
                flags.formUnion(location.flags)
                matched = true
            }
        }
        if !matched {
            // Unfiled: take what All Mail says.
            for location in entry.locations { flags.formUnion(location.flags) }
        }
        let starred = entry.locations.contains {
            mailboxes[$0.mailbox]?.role == .starred || $0.flags.contains(#"\Flagged"#)
        }
        if starred { flags.insert(#"\Flagged"#) }
        flags.remove(#"\Recent"#)
        flags.remove(#"\Deleted"#)
        return flags.sorted()
    }

    /// The date to keep: the INTERNALDATE from the first location that has one.
    public func internalDate(for entry: MessageEntry) -> IMAPDate? {
        entry.locations.lazy.compactMap(\.internalDate).first
    }

    /// Messages that will go to `Unfiled`.
    public var unfiled: [MessageEntry] {
        messages.values.filter { targets(for: $0) == [MailboxPlan.unfiled] }
    }
}

/// Reads and appends `journal.jsonl`.
final class Journal: @unchecked Sendable {
    private let url: URL
    private var handle: FileHandle?
    private var pending = Data()
    private let encoder = JSONEncoder()

    init(url: URL) {
        self.url = url
        encoder.outputFormatting = [.sortedKeys]
    }

    /// Replays the journal. A torn last line (crash mid-write) is ignored.
    func load() throws -> ExportState {
        var state = ExportState()
        guard FileManager.default.fileExists(atPath: url.path) else { return state }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let event = try? decoder.decode(JournalEvent.self, from: line) else { continue }
            state.apply(event)
        }
        return state
    }

    func append(_ event: JournalEvent) throws {
        pending.append(try encoder.encode(event))
        pending.append(UInt8(ascii: "\n"))
    }

    /// Writes buffered events and syncs them to disk.
    func flush() throws {
        guard !pending.isEmpty else { return }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: url.path) {
                _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            handle = try FileHandle(forWritingTo: url)
            try handle!.seekToEnd()
            // If the last run died mid-line, start on a fresh line.
            if try handle!.offset() > 0 { try handle!.write(contentsOf: Data([UInt8(ascii: "\n")])) }
        }
        try handle!.write(contentsOf: pending)
        try handle!.synchronize()
        pending.removeAll(keepingCapacity: true)
    }

    func close() {
        try? flush()
        try? handle?.close()
        handle = nil
    }
}
