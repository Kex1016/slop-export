import Foundation

/// `manifest.json`: a readable snapshot of the export, rewritten at the end of each run.
/// The journal is the source of truth; this file is for people, `verify`, and the later phases.
public struct Manifest: Codable, Sendable {
    public struct Mailbox: Codable, Sendable {
        public var path: String
        public var role: MailboxRole
        public var uidValidity: UInt32?
        public var count: Int?
        public var exported: Int
        public var complete: Bool
    }

    public struct Message: Codable, Sendable {
        public var hash: String
        public var size: Int
        public var messageID: String?
        public var internalDate: IMAPDate?
        public var targets: [[String]]
        public var locations: [MessageLocation]
    }

    public var version = 1
    public var generatedAt: Date
    public var mailboxes: [Mailbox]
    public var messages: [Message]
    public var skipped: [SkippedMessage]

    public init(state: ExportState, generatedAt: Date = Date()) {
        self.generatedAt = generatedAt
        mailboxes = state.mailboxes.values.sorted { $0.path < $1.path }.map { box in
            Mailbox(path: box.path, role: box.role, uidValidity: box.uidValidity, count: box.count,
                    exported: box.uidValidity.map { state.seenCount(mailbox: box.path, uidValidity: $0) } ?? 0,
                    complete: box.complete)
        }
        skipped = state.skipped
        messages = state.messages.values.sorted { $0.hash < $1.hash }.map { entry in
            Message(hash: entry.hash, size: entry.size, messageID: entry.messageID,
                    internalDate: state.internalDate(for: entry), targets: state.targets(for: entry),
                    locations: entry.locations.sorted { ($0.mailbox, $0.uid) < ($1.mailbox, $1.uid) })
        }
    }

    static func write(state: ExportState, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(Manifest(state: state)).write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> Manifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Manifest.self, from: Data(contentsOf: url))
    }
}
