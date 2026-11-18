import Foundation
import NIO
import NIOSSL

/// iCloud Mail connection settings. The password is an app-specific password David creates at
/// account.apple.com; it comes from a `SecretStore`, never from here.
public struct ICloudSettings: Sendable, Codable, Hashable {
    public var host: String
    public var port: Int
    public var user: String

    public init(host: String = "imap.mail.me.com", port: Int = 993, user: String) {
        self.host = host
        self.port = port
        self.user = user
    }

    public var endpoint: ServerEndpoint {
        ServerEndpoint(host: host, port: port, tls: .implicit, trust: .system)
    }
}

/// What an upload will do (dry run) or did.
public struct UploadPlan: Sendable, Codable {
    public struct Folder: Sendable, Codable {
        public var path: String
        public var exists: Bool
        public var toUpload: Int
        public var alreadyThere: Int
        public var bytes: Int
    }

    public var folders: [Folder]
    public var quotaUsed: Int?
    public var quotaLimit: Int?

    public var messagesToUpload: Int { folders.map(\.toUpload).reduce(0, +) }
    public var bytesToUpload: Int { folders.map(\.bytes).reduce(0, +) }
    public var foldersToCreate: [String] { folders.filter { !$0.exists }.map(\.path) }

    /// Nil if it fits (or the server reports no quota), else how many bytes are missing.
    public var shortfall: Int? {
        guard let used = quotaUsed, let limit = quotaLimit, limit > 0 else { return nil }
        let missing = used + bytesToUpload - limit
        return missing > 0 ? missing : nil
    }
}

public struct UploadSummary: Sendable, Codable {
    public var uploaded: Int
    public var alreadyThere: Int
    public var failed: Int
    public var foldersCreated: [String]
}

public enum UploadError: Error, CustomStringConvertible {
    case notEnoughSpace(needed: Int, missing: Int)
    case noExport
    /// iCloud refused several messages in a row, or said it is out of space. Nothing was marked
    /// as failed; re-running retries them.
    case stoppedByServer(String)

    public var description: String {
        switch self {
        case .notEnoughSpace(let needed, let missing):
            return "iCloud does not have room: the upload needs \(ProbeFormatter.byteString(needed)) and "
                + "\(ProbeFormatter.byteString(missing)) more than is free. Free up space or upgrade iCloud storage, then try again."
        case .noExport:
            return "There is no export to upload yet. Run the Export step first."
        case .stoppedByServer(let text):
            return "iCloud stopped accepting messages (\(text)). Nothing was lost: wait a while, check your iCloud storage, then run the upload again and it carries on."
        }
    }
}

public struct UploadProgress: Sendable {
    public var folder: String?
    public var done: Int
    public var total: Int
    public var bytes: Int
    public var message: String?
}

/// Phase 5 (Path B): APPENDs the exported messages to iCloud, keeping flags and INTERNALDATE.
///
/// Resumable and duplicate-free: every APPEND is journalled in `upload.jsonl`, and before
/// uploading into a folder it also reads what that folder already holds (Message-ID, size and
/// date) so a crash between an APPEND and its journal line never causes a second copy (D-011).
public final class Uploader: @unchecked Sendable {
    public struct Options: Sendable {
        /// How many connections upload at once. Each waits for iCloud to confirm one APPEND
        /// before sending the next, so this is what hides the round trip (D-018).
        public var connections = 4
        /// Pause after each APPEND on a connection. iCloud's "busy" answers are handled by
        /// waiting and retrying instead, so none by default.
        public var delayBetweenMessages: Duration = .zero
        /// This many refusals in a row means the server is refusing everything (throttling,
        /// quota), not that these particular messages are bad, so the upload stops.
        public var maxConsecutiveRefusals = 3
        public var maxRetries = 6
        public var retryBaseDelay: Duration = .seconds(2)
        public init() {}
    }

    private let exportDirectory: URL
    private let store: MessageStore
    private let state: ExportState
    private let connect: @Sendable () async throws -> IMAPClient
    private let options: Options
    private let progress: @Sendable (UploadProgress) -> Void
    private let journalURL: URL
    private var uploaded: Set<UploadKey> = []

    struct UploadKey: Hashable, Codable {
        var target: String
        var hash: String
    }

    private enum Event: Codable {
        case uploaded(target: String, hash: String)
        case failed(target: String, hash: String, reason: String)
    }

    public init(exportDirectory: URL, options: Options = Options(),
                connect: @escaping @Sendable () async throws -> IMAPClient,
                progress: @escaping @Sendable (UploadProgress) -> Void = { _ in }) throws {
        self.exportDirectory = exportDirectory
        self.store = MessageStore(root: exportDirectory.appendingPathComponent("store", isDirectory: true))
        self.state = try ExportState.load(from: exportDirectory)
        guard !state.messages.isEmpty else { throw UploadError.noExport }
        self.connect = connect
        self.options = options
        self.progress = progress
        self.journalURL = exportDirectory.appendingPathComponent("upload.jsonl")
        self.uploaded = Self.loadJournal(journalURL)
    }

    public convenience init(exportDirectory: URL, settings: ICloudSettings, password: String, options: Options = Options(),
                            progress: @escaping @Sendable (UploadProgress) -> Void = { _ in }) throws {
        let endpoint = settings.endpoint
        let user = settings.user
        try self.init(exportDirectory: exportDirectory, options: options, connect: {
            try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password)
        }, progress: progress)
    }

    // MARK: Plan

    /// Dry run: reads iCloud (folder list, quota, what each folder already holds) and writes nothing.
    public func plan() async throws -> UploadPlan {
        var client = try await connect()
        defer { Task { [client] in await client.close() } }
        return try await withRetry(&client) { client in try await self.plan(client: client).plan }
    }

    /// The plan, plus what each existing folder held when it was read (keyed by target path).
    private func plan(client: IMAPClient) async throws -> (plan: UploadPlan, present: [String: PresentSet]) {
        let listed = try await client.list()
        let separator = listed.compactMap(\.separator).first ?? "/"
        var folders: [UploadPlan.Folder] = []
        var held: [String: PresentSet] = [:]
        for (target, entries) in state.messagesByTarget() {
            let path = target.joined(separator: "/")
            let existing = listed.first { Self.same($0.components, target) }
            var present = PresentSet()
            if let existing {
                present = try await presentMessages(in: existing, client: client)
                held[path] = present
            }
            var toUpload = 0
            var already = 0
            var bytes = 0
            for entry in entries {
                if uploaded.contains(UploadKey(target: path, hash: entry.hash)) || present.take(Self.key(entry, state)) {
                    already += 1
                } else {
                    toUpload += 1
                    bytes += entry.size
                }
            }
            folders.append(.init(path: path, exists: existing != nil, toUpload: toUpload, alreadyThere: already, bytes: bytes))
        }
        let quota = try await client.storageQuota(separator: separator)
        return (UploadPlan(folders: folders, quotaUsed: quota?.used, quotaLimit: quota?.limit), held)
    }

    // MARK: Upload

    /// Uploads everything not already in iCloud. Checks the quota first and stops before
    /// writing anything if the upload will not fit. Uses up to `Options.connections` connections
    /// at once (D-018).
    public func run() async throws -> UploadSummary {
        var client = try await connect()
        defer { Task { [client] in await client.close() } }

        // One read of every folder serves both the quota check and the duplicate check below.
        let (plan, held) = try await withRetry(&client) { client in try await self.plan(client: client) }
        if let missing = plan.shortfall {
            throw UploadError.notEnoughSpace(needed: plan.bytesToUpload, missing: missing)
        }
        let (run, units) = try await prepare(held: held, client: &client)
        await run.report(folder: nil)
        let workers = min(max(1, options.connections), units)
        if workers > 0 {
            try await upload(run, workers: workers, first: client)
        } else {
            await client.logout()
        }
        return try await run.finish()
    }

    /// Finds the iCloud folder for `target`, creating it and any missing parents.
    private func ensureFolder(_ target: [String], client: IMAPClient) async throws -> (ListedMailbox, Character, [String]) {
        var listed = try await client.list()
        let separator = listed.compactMap(\.separator).first ?? "/"
        if let existing = listed.first(where: { Self.same($0.components, target) }) { return (existing, separator, []) }
        var created: [String] = []
        for depth in 1...target.count {
            let prefix = Array(target.prefix(depth))
            if listed.contains(where: { Self.same($0.components, prefix) }) { continue }
            try await client.create(prefix, separator: separator)
            created.append(prefix.joined(separator: "/"))
        }
        listed = try await client.list()
        guard let mailbox = listed.first(where: { Self.same($0.components, target) }) else {
            throw IMAPError.unexpected("created \(target.joined(separator: "/")) but iCloud does not list it")
        }
        return (mailbox, separator, created)
    }

    /// INBOX matches case-insensitively, everything else exactly.
    static func same(_ a: [String], _ b: [String]) -> Bool {
        guard a.count == b.count else { return false }
        if a.count == 1, a[0].caseInsensitiveCompare("INBOX") == .orderedSame { return b[0].caseInsensitiveCompare("INBOX") == .orderedSame }
        return a == b
    }

    // MARK: Duplicate detection (D-011)

    struct PresenceKey: Hashable, Sendable {
        var messageID: String
        var size: Int
        var date: Int
    }

    /// A multiset of what a folder already holds, so N identical messages need N copies.
    struct PresentSet: Sendable {
        var counts: [PresenceKey: Int] = [:]
        mutating func add(_ key: PresenceKey) { counts[key, default: 0] += 1 }
        func count(_ key: PresenceKey) -> Int { counts[key] ?? 0 }
        mutating func take(_ key: PresenceKey) -> Bool {
            guard let n = counts[key], n > 0 else { return false }
            counts[key] = n - 1
            return true
        }
    }

    /// The key an exported message should have once it is in iCloud.
    static func key(_ entry: MessageEntry, _ state: ExportState) -> PresenceKey {
        PresenceKey(messageID: entry.messageID ?? "", size: entry.size,
                    date: Int(state.internalDate(for: entry)?.date.timeIntervalSince1970 ?? 0))
    }

    /// The key of a message as iCloud reports it (headers only).
    static func key(_ record: FetchRecord) -> PresenceKey {
        let mid = record.headerFields.flatMap { Headers.messageID(in: Array($0.readableBytesView)) } ?? ""
        let date = record.internalDate.map { Int(IMAPDate($0).date.timeIntervalSince1970) } ?? 0
        return PresenceKey(messageID: mid, size: record.size ?? -1, date: date)
    }

    private func presentMessages(in mailbox: ListedMailbox, client: IMAPClient) async throws -> PresentSet {
        let selected = try await client.examine(mailbox)
        var present = PresentSet()
        guard selected.exists > 0 else { return present }
        for record in try await client.fetchAllMetadata(withMessageID: true) { present.add(Self.key(record)) }
        return present
    }

    // MARK: Files

    private func keepLocally(_ entry: MessageEntry, target: [String]) throws {
        var dir = exportDirectory.appendingPathComponent("Not uploaded", isDirectory: true)
        for component in target { dir.appendPathComponent(MboxWriter.safeComponent(component), isDirectory: true) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(entry.hash).eml")
        if !FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.copyItem(at: store.url(for: entry.hash), to: file)
        }
    }

    private func journal(_ event: Event) throws {
        var line = try JSONEncoder().encode(event)
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            _ = FileManager.default.createFile(atPath: journalURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()
    }

    private static func loadJournal(_ url: URL) -> Set<UploadKey> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var out: Set<UploadKey> = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            if case .uploaded(let target, let hash)? = try? JSONDecoder().decode(Event.self, from: line) {
                out.insert(UploadKey(target: target, hash: hash))
            }
        }
        return out
    }

    // MARK: Retry

    private func withRetry<T>(_ client: inout IMAPClient, _ body: (IMAPClient) async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do {
                return try await body(client)
            } catch let error where Exporter.isTransient(error) && attempt < options.maxRetries {
                attempt += 1
                let delay = options.retryBaseDelay * (1 << (attempt - 1))
                progress(UploadProgress(folder: nil, done: 0, total: 0, bytes: 0,
                                        message: "Connection lost (\(error)); retrying in \(delay)"))
                await client.close()
                try await Task.sleep(for: delay)
                // A reconnect that fails for a transient reason leaves the closed client in place, so
                // the next attempt fails fast and backs off again. Anything else (a refused login,
                // a changed certificate) will not fix itself, so it ends the run with its own message.
                do { client = try await connect() } catch let reconnectError where Exporter.isTransient(reconnectError) {}
            }
        }
    }
}

// MARK: Parallel upload (D-018)

extension Uploader {
    /// Messages for one folder that share a presence key, uploaded in order by one connection.
    /// Keeping same-key messages on one connection means a retry after a dropped APPEND can tell
    /// from the folder's count whether its own copy landed, with no other connection adding the
    /// same key at the same time.
    struct WorkUnit: Sendable {
        var target: [String]
        var path: String
        var mailbox: ListedMailbox
        var separator: Character
        var key: PresenceKey
        var entries: [MessageEntry]
    }

    /// Creates every folder and decides what is already there before uploading anything, so the
    /// connections afterwards only ever APPEND. Returns the shared run and how many units it holds.
    private func prepare(held: [String: PresentSet], client: inout IMAPClient) async throws -> (UploadRun, Int) {
        var summary = UploadSummary(uploaded: 0, alreadyThere: 0, failed: 0, foldersCreated: [])
        var units: [WorkUnit] = []
        var present: [String: PresentSet] = [:]
        var accounted: [String: PresentSet] = [:]
        var total = 0
        for (target, entries) in state.messagesByTarget() {
            try Task.checkCancellation()
            let path = target.joined(separator: "/")
            let (mailbox, separator, created) = try await withRetry(&client) { client in
                try await self.ensureFolder(target, client: client)
            }
            summary.foldersCreated += created
            total += entries.count
            // What the folder held before this run, and what this run has accounted for since.
            var left = held[path] ?? PresentSet()
            var taken = PresentSet()
            var unitIndex: [PresenceKey: Int] = [:]
            for entry in entries {
                let key = Self.key(entry, state)
                if uploaded.contains(UploadKey(target: path, hash: entry.hash)) {
                    summary.alreadyThere += 1
                } else if left.take(key) {
                    taken.add(key)
                    summary.alreadyThere += 1
                } else if let i = unitIndex[key] {
                    units[i].entries.append(entry)
                } else {
                    unitIndex[key] = units.count
                    units.append(WorkUnit(target: target, path: path, mailbox: mailbox, separator: separator,
                                          key: key, entries: [entry]))
                }
            }
            present[path] = left
            accounted[path] = taken
        }

        let run = UploadRun(uploader: self, units: units, present: present, accounted: accounted,
                            summary: summary, total: total, maxRefusals: options.maxConsecutiveRefusals,
                            progress: progress)
        return (run, units.count)
    }

    /// Runs `workers` connections until the queue is empty. The first reuses `first`; one that
    /// cannot connect is dropped and the others carry on.
    private func upload(_ run: UploadRun, workers: Int, first: IMAPClient) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<workers {
                group.addTask {
                    var worker: IMAPClient
                    if index == 0 {
                        worker = first
                    } else {
                        do {
                            worker = try await self.connect()
                        } catch is CancellationError {
                            return
                        } catch {
                            // iCloud may cap connections per account. The others carry on.
                            self.progress(UploadProgress(folder: nil, done: 0, total: 0, bytes: 0,
                                                         message: "Using fewer connections: \(error)"))
                            return
                        }
                    }
                    do {
                        try await self.work(run, client: &worker)
                    } catch {
                        await worker.close()
                        throw error
                    }
                    await worker.logout()
                    await worker.close()
                }
            }
            try await group.waitForAll()
        }
    }

    /// One connection's loop: takes units until none are left.
    private func work(_ run: UploadRun, client: inout IMAPClient) async throws {
        while let unit = await run.next() {
            for entry in unit.entries {
                try Task.checkCancellation()
                let raw = try store.read(entry.hash)
                let flags = state.flags(for: entry, in: unit.target)
                let date = state.internalDate(for: entry)?.serverMessageDate
                do {
                    var retried = false
                    try await withRetry(&client) { client in
                        if retried {
                            // The connection dropped mid-APPEND: it may have landed. It did if the
                            // folder now holds more copies than this run has accounted for.
                            let now = try await self.presentMessages(in: unit.mailbox, client: client)
                            if now.count(unit.key) > (await run.expected(unit.key, in: unit.path)) { return }
                        }
                        retried = true
                        try await self.appendPacing {
                            try await client.append(to: unit.target, separator: unit.separator,
                                                    message: ByteBuffer(bytes: raw), flags: flags, date: date)
                        }
                    }
                    try await run.uploaded(entry, unit: unit, bytes: raw.count)
                } catch let IMAPError.commandFailed(command, _, text) where command.hasPrefix("APPEND") {
                    if text.localizedCaseInsensitiveContains("quota") {
                        throw UploadError.stoppedByServer(text)
                    }
                    // Probably iCloud refusing this one message (for example, too large). Kept in
                    // "Not uploaded" once a later message gets through.
                    try await run.refused(entry, unit: unit, text: text)
                }
                if options.delayBetweenMessages > .zero { try await Task.sleep(for: options.delayBetweenMessages) }
            }
        }
    }

    /// Runs one APPEND, waiting and trying again while iCloud says it is busy. That is
    /// throttling, not a refusal of this message, so it must not end up in "Not uploaded".
    /// After `maxRetries` waits it gives up and stops the run.
    private func appendPacing(_ append: () async throws -> Void) async throws {
        var attempt = 0
        while true {
            do {
                return try await append()
            } catch let IMAPError.commandFailed(command, _, text) where command.hasPrefix("APPEND") && Self.isBusy(text) {
                guard attempt < options.maxRetries else { throw UploadError.stoppedByServer(text) }
                attempt += 1
                let delay = options.retryBaseDelay * (1 << (attempt - 1))
                progress(UploadProgress(folder: nil, done: 0, total: 0, bytes: 0,
                                        message: "iCloud is busy (\(text)); waiting \(delay)"))
                try await Task.sleep(for: delay)
            }
        }
    }

    /// Whether a NO to APPEND means "slow down" rather than "not this message": "[UNAVAILABLE]",
    /// "try again later" and the like. Not "[LIMIT]", which can also mean the message is too big,
    /// and not anything about quota, which waiting will not fix.
    static func isBusy(_ text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.contains("quota") else { return false }
        return ["[unavailable]", "[inuse]", "try again", "throttl", "rate limit"].contains { lower.contains($0) }
    }

    /// Only called from `UploadRun`, which serialises them: the journal and `uploaded` have one writer.
    func recordUploaded(_ entry: MessageEntry, path: String) throws {
        try journal(.uploaded(target: path, hash: entry.hash))
        uploaded.insert(UploadKey(target: path, hash: entry.hash))
    }

    func recordRefused(_ entry: MessageEntry, target: [String], text: String) throws {
        try keepLocally(entry, target: target)
        try journal(.failed(target: target.joined(separator: "/"), hash: entry.hash, reason: text))
    }
}
