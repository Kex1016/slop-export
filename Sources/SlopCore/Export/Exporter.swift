import Foundation
import NIO
import NIOSSL

/// Progress reported while exporting.
public struct ExportProgress: Sendable {
    public enum Phase: Sendable { case connecting, scanning, downloading, matching, writingManifest, done }
    public var phase: Phase
    public var mailbox: String?
    /// Messages handled in `mailbox` so far, and how many it has.
    public var done: Int
    public var total: Int
    public var downloadedBytes: Int
    public var message: String?
}

public struct ExportSummary: Sendable, Codable {
    public var distinctMessages: Int
    public var downloadedThisRun: Int
    public var matchedWithoutDownload: Int
    public var unfiled: Int
    public var skipped: Int
    public var mailboxes: Int
}

/// Phase 3: downloads every message Bridge has into a content-addressed store, with a journal
/// that makes it resumable. Read-only on Bridge: EXAMINE and BODY.PEEK only.
///
/// Order matters. Real folders are downloaded first. `Starred` and `All Mail` are then matched
/// against what is already stored by Message-ID and size, and only messages that match nothing
/// are downloaded (D-009). Those are the `Unfiled` ones.
public final class Exporter: @unchecked Sendable {
    public struct Options: Sendable {
        public var maxBatchMessages = 50
        public var maxBatchBytes = 25 * 1024 * 1024
        public var maxRetries = 6
        public var retryBaseDelay: Duration = .seconds(2)
        public init() {}
    }

    public let directory: URL
    public let store: MessageStore
    private let journal: Journal
    private let connect: @Sendable () async throws -> IMAPClient
    private let options: Options
    private let progress: @Sendable (ExportProgress) -> Void
    public private(set) var state: ExportState
    private var downloaded = 0
    private var downloadedBytes = 0
    private var matched = 0

    /// - Parameter connect: returns a logged-in client. Called again after a dropped connection.
    public init(directory: URL, options: Options = Options(),
                connect: @escaping @Sendable () async throws -> IMAPClient,
                progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) throws {
        self.directory = directory
        self.store = MessageStore(root: directory.appendingPathComponent("store", isDirectory: true))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.journal = Journal(url: directory.appendingPathComponent("journal.jsonl"))
        self.connect = connect
        self.options = options
        self.progress = progress
        self.state = try journal.load()
    }

    public convenience init(directory: URL, settings: BridgeSettings, password: String, options: Options = Options(),
                            progress: @escaping @Sendable (ExportProgress) -> Void = { _ in }) throws {
        let endpoint = try settings.endpoint()
        let user = settings.user
        try self.init(directory: directory, options: options, connect: {
            try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password)
        }, progress: progress)
    }

    // MARK: Run

    public func run() async throws -> ExportSummary {
        defer { journal.close() }
        report(.connecting)
        var client = try await connect()
        defer { Task { [client] in await client.close() } }

        let listed = try await withRetry(&client) { try await $0.list() }
        let plan = listed
            .map { ($0, MailboxPlan.role(for: $0)) }
            .sorted { Self.order($0.1) < Self.order($1.1) || (Self.order($0.1) == Self.order($1.1) && $0.0.displayPath < $1.0.displayPath) }

        for (mailbox, role) in plan {
            try Task.checkCancellation()
            switch role {
            case .container, .skippedLabel:
                try record(.mailbox(MailboxState(path: mailbox.displayPath, role: role, uidValidity: nil, count: nil, complete: true)))
            case .export, .starred, .allMail:
                guard mailbox.isSelectable else { continue }
                try await exportMailbox(mailbox, role: role, client: &client)
            }
        }
        try journal.flush()
        report(.writingManifest)
        try Manifest.write(state: state, to: directory.appendingPathComponent("manifest.json"))
        let summary = ExportSummary(distinctMessages: state.messages.count, downloadedThisRun: downloaded,
                                    matchedWithoutDownload: matched, unfiled: state.unfiled.count,
                                    skipped: state.skipped.count,
                                    mailboxes: state.mailboxes.count)
        report(.done)
        await client.logout()
        return summary
    }

    /// Real folders first, then Starred, then All Mail.
    private static func order(_ role: MailboxRole) -> Int {
        switch role {
        case .export: return 0
        case .starred: return 1
        case .allMail: return 2
        case .container, .skippedLabel: return 3
        }
    }

    /// Raised when a mailbox's UIDVALIDITY changes while it is being exported.
    struct UIDValidityChanged: Error {}

    private func exportMailbox(_ mailbox: ListedMailbox, role: MailboxRole, client: inout IMAPClient) async throws {
        // A Bridge resync can renumber a mailbox mid-export; start that mailbox over, a few times at most.
        for attempt in 1...3 {
            do {
                try await exportMailboxOnce(mailbox, role: role, client: &client)
                return
            } catch is UIDValidityChanged where attempt < 3 {
                continue
            }
        }
    }

    private func exportMailboxOnce(_ mailbox: ListedMailbox, role: MailboxRole, client: inout IMAPClient) async throws {
        let path = mailbox.displayPath
        report(.scanning, mailbox: path)
        let (selected, metadata) = try await withRetry(&client) { client in
            let selected = try await client.examine(mailbox)
            let metadata = selected.exists == 0 ? [] : try await client.fetchAllMetadata(withMessageID: true)
            return (selected, metadata)
        }
        guard let validity = selected.uidValidity else {
            throw IMAPError.unexpected("\(path) has no UIDVALIDITY; cannot resume safely")
        }
        try record(.mailbox(MailboxState(path: path, role: role, uidValidity: validity, count: metadata.count, complete: false)))
        try journal.flush()

        var pending: [FetchRecord] = []
        for record in metadata {
            guard let uid = record.uid, !state.hasSeen(mailbox: path, uidValidity: validity, uid: uid) else { continue }
            if role == .allMail || role == .starred, let hash = match(record, role: role) {
                try self.record(.location(hash: hash, size: record.size ?? 0,
                                          messageID: messageID(record),
                                          location: location(record, mailbox: path, validity: validity)))
                matched += 1
                continue
            }
            pending.append(record)
        }
        try journal.flush()

        var done = metadata.count - pending.count
        report(.downloading, mailbox: path, done: done, total: metadata.count)
        for batch in batches(pending) {
            try Task.checkCancellation()
            try await download(batch, mailbox: mailbox, validity: validity, client: &client)
            try journal.flush()
            done += batch.count
            report(.downloading, mailbox: path, done: done, total: metadata.count)
        }
        // Complete only if every message is either stored or recorded as skipped. Anything that
        // vanished mid-run is picked up next time.
        let handled = state.seenCount(mailbox: path, uidValidity: validity)
        try record(.mailbox(MailboxState(path: path, role: role, uidValidity: validity, count: metadata.count,
                                         complete: handled >= metadata.count)))
        try journal.flush()
    }

    /// Downloads one batch. If the server refuses the batch (Bridge can fail to build a single
    /// message), it retries one message at a time and records the ones that still fail as skipped,
    /// so one bad message never blocks the export. `verify` lists skipped messages.
    private func download(_ batch: [FetchRecord], mailbox: ListedMailbox, validity: UInt32,
                          client: inout IMAPClient) async throws {
        let path = mailbox.displayPath
        let uids = batch.compactMap(\.uid)
        let bodies: [FetchRecord]
        do {
            bodies = try await withRetry(&client) { client in
                let selected = try await client.examine(mailbox)
                guard selected.uidValidity == validity else { throw UIDValidityChanged() }
                return try await client.fetchBodies(uids: uids)
            }
        } catch let IMAPError.commandFailed(_, _, text) {
            guard batch.count > 1 else {
                if let uid = batch.first?.uid {
                    try record(.skipped(mailbox: path, uidValidity: validity, uid: uid, reason: text))
                }
                return
            }
            for single in batch {
                try await download([single], mailbox: mailbox, validity: validity, client: &client)
            }
            return
        }
        let byUID = Dictionary(bodies.compactMap { r in r.uid.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        for meta in batch {
            guard let uid = meta.uid, let fetched = byUID[uid], let body = fetched.body else {
                continue  // gone since the scan; the mailbox stays incomplete and the next run retries
            }
            let hash = try store.put(body)
            downloaded += 1
            downloadedBytes += body.readableBytes
            var loc = location(meta, mailbox: path, validity: validity)
            if !fetched.flags.isEmpty { loc.flags = fetched.flags }
            try record(.location(hash: hash, size: body.readableBytes,
                                 messageID: messageID(meta) ?? Headers.messageID(in: Array(body.readableBytesView.prefix(64 * 1024))),
                                 location: loc))
        }
    }

    // MARK: Matching (D-009)

    /// Finds an already-stored message with the same Message-ID and size that still has a free
    /// slot. A message stands for as many Starred entries as it has real-folder copies, and as
    /// many All Mail entries as the larger of its real-folder and Starred copies (a starred
    /// message that is in no folder was stored from Starred). Two identical messages in All Mail
    /// therefore never collapse into one.
    private func match(_ record: FetchRecord, role: MailboxRole) -> String? {
        guard let mid = messageID(record), let size = record.size else { return nil }
        for hash in state.hashes(forMessageID: mid) {
            guard let entry = state.messages[hash], entry.size == size else { continue }
            let folderCopies = entry.locations.filter { state.isExportMailbox($0.mailbox) }.count
            let starredCopies = entry.locations.filter { state.mailboxes[$0.mailbox]?.role == .starred }.count
            let slots = role == .allMail ? max(folderCopies, starredCopies) : folderCopies
            let used = entry.locations.filter { state.mailboxes[$0.mailbox]?.role == role }.count
            if used < slots { return hash }
        }
        return nil
    }

    private func messageID(_ record: FetchRecord) -> String? {
        record.headerFields.flatMap { Headers.messageID(in: Array($0.readableBytesView)) }
    }

    private func location(_ record: FetchRecord, mailbox: String, validity: UInt32) -> MessageLocation {
        MessageLocation(mailbox: mailbox, uidValidity: validity, uid: record.uid ?? 0, flags: record.flags,
                        internalDate: record.internalDate.map(IMAPDate.init))
    }

    // MARK: Helpers

    private func batches(_ records: [FetchRecord]) -> [[FetchRecord]] {
        var out: [[FetchRecord]] = []
        var current: [FetchRecord] = []
        var bytes = 0
        for record in records {
            let size = record.size ?? 0
            if !current.isEmpty, current.count >= options.maxBatchMessages || bytes + size > options.maxBatchBytes {
                out.append(current)
                current = []
                bytes = 0
            }
            current.append(record)
            bytes += size
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    private func record(_ event: JournalEvent) throws {
        state.apply(event)
        try journal.append(event)
    }

    private func report(_ phase: ExportProgress.Phase, mailbox: String? = nil, done: Int = 0, total: Int = 0) {
        progress(ExportProgress(phase: phase, mailbox: mailbox, done: done, total: total, downloadedBytes: downloadedBytes))
    }

    /// Runs `body`, reconnecting with exponential backoff if the connection drops. Bridge can
    /// restart or drop idle connections during a long export; the journal makes repeats safe.
    private func withRetry<T>(_ client: inout IMAPClient, _ body: (IMAPClient) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body(client)
            } catch let error where Self.isTransient(error) && attempt < options.maxRetries {
                attempt += 1
                let delay = options.retryBaseDelay * (1 << (attempt - 1))
                progress(ExportProgress(phase: .connecting, mailbox: nil, done: 0, total: 0, downloadedBytes: downloadedBytes,
                                        message: "Connection lost (\(error)); retrying in \(delay)"))
                await client.close()
                try await Task.sleep(for: delay)
                if let fresh = try? await connect() { client = fresh }
            }
        }
    }

    static func isTransient(_ error: Error) -> Bool {
        switch error {
        case IMAPError.connectionClosed, IMAPError.timeout, IMAPError.bye, IMAPError.noGreeting: return true
        case is ChannelError: return true
        case is IOError: return true
        case is NIOSSLError: return true  // e.g. uncleanShutdown when Bridge restarts
        default: return false
        }
    }
}
