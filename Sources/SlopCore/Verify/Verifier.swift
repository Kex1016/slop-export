import Foundation

/// Phase 6: compares Bridge, the export, the Apple Mail output and iCloud, folder by folder, and
/// lists every message that is missing or extra.
public struct VerifyReport: Codable, Sendable {
    /// One Bridge mailbox: what Bridge has now vs what the export recorded.
    public struct SourceRow: Codable, Sendable, Identifiable {
        public var id: String { mailbox }
        public var mailbox: String
        public var role: MailboxRole
        /// Live count from Bridge, if it was reachable.
        public var bridge: Int?
        /// Count when the export last scanned it.
        public var scanned: Int?
        public var exported: Int
        public var skipped: Int
        public var missing: Int { max((bridge ?? scanned ?? 0) - exported - skipped, 0) }
    }

    /// One target folder: how many messages should be there vs what each output has.
    public struct TargetRow: Codable, Sendable, Identifiable {
        public var id: String { folder }
        public var folder: String
        public var expected: Int
        public var mbox: Int?
        public var icloud: Int?
        /// Messages expected in iCloud that are not there (hash, Message-ID).
        public var missingInICloud: [MissingMessage]
        public var extraInICloud: Int
    }

    public struct MissingMessage: Codable, Sendable, Hashable {
        public var hash: String
        public var messageID: String?
    }

    public var generatedAt: Date
    public var sources: [SourceRow]
    public var targets: [TargetRow]
    public var skipped: [SkippedMessage]
    public var distinctMessages: Int
    public var allMailCount: Int?
    public var allMailAccountedFor: Int
    /// All Mail messages Bridge would not hand over (already listed in `skipped`).
    public var allMailSkipped: Int = 0

    /// Every All Mail message is stored or knowingly skipped. More than Bridge has now is fine:
    /// that is mail deleted in Proton after the export.
    public var allMailComplete: Bool {
        allMailCount.map { allMailAccountedFor + allMailSkipped >= $0 } ?? true
    }

    /// Bridge-side completeness: every message Bridge has is stored or knowingly skipped,
    /// and every All Mail entry maps to a stored message (acceptance criterion 2).
    public var exportComplete: Bool {
        sources.allSatisfy { $0.role == .skippedLabel || $0.role == .container || $0.missing == 0 }
            && allMailComplete
    }

    public var mboxComplete: Bool? {
        targets.contains { $0.mbox != nil } ? targets.allSatisfy { ($0.mbox ?? 0) == $0.expected } : nil
    }

    public var icloudComplete: Bool? {
        targets.contains { $0.icloud != nil } ? targets.allSatisfy { $0.missingInICloud.isEmpty } : nil
    }

    public var passed: Bool { exportComplete && mboxComplete != false && icloudComplete != false }
}

public enum Verifier {
    public struct Inputs: Sendable {
        public var exportDirectory: URL
        public var mboxDirectory: URL?
        /// Logged-in client factories; nil skips that side.
        public var bridge: (@Sendable () async throws -> IMAPClient)?
        public var icloud: (@Sendable () async throws -> IMAPClient)?

        public init(exportDirectory: URL, mboxDirectory: URL? = nil,
                    bridge: (@Sendable () async throws -> IMAPClient)? = nil,
                    icloud: (@Sendable () async throws -> IMAPClient)? = nil) {
            self.exportDirectory = exportDirectory
            self.mboxDirectory = mboxDirectory
            self.bridge = bridge
            self.icloud = icloud
        }
    }

    public static func run(_ inputs: Inputs) async throws -> VerifyReport {
        let state = try ExportState.load(from: inputs.exportDirectory)

        // Bridge side.
        var live: [String: Int] = [:]
        if let connect = inputs.bridge {
            live = try await withClient(connect) { client in
                var counts: [String: Int] = [:]
                for box in try await client.list() where box.isSelectable {
                    let role = MailboxPlan.role(for: box)
                    guard role != .skippedLabel, role != .container else { continue }
                    counts[box.displayPath] = try await client.status(box, size: false).messages
                }
                return counts
            }
        }
        var sources: [VerifyReport.SourceRow] = []
        for box in state.mailboxes.values.sorted(by: { $0.path < $1.path }) {
            let validity = box.uidValidity
            let skipped = state.skipped.filter { $0.mailbox == box.path && $0.uidValidity == validity }.count
            let handled = validity.map { state.seenCount(mailbox: box.path, uidValidity: $0) } ?? 0
            sources.append(.init(mailbox: box.path, role: box.role, bridge: live[box.path], scanned: box.count,
                                 exported: handled - skipped, skipped: skipped))
        }
        for path in live.keys where state.mailboxes[path] == nil {
            sources.append(.init(mailbox: path, role: .export(target: []), bridge: live[path], scanned: nil, exported: 0, skipped: 0))
        }
        let allMailPath = state.mailboxes.values.first { $0.role == .allMail }?.path
        let allMailLocations = allMailPath.map { path in
            state.messages.values.reduce(0) { $0 + $1.locations.filter { $0.mailbox == path }.count }
        } ?? 0
        let allMailCount = allMailPath.flatMap { live[$0] ?? state.mailboxes[$0]?.count }

        let allMailSkipped = allMailPath.map { path in state.skipped.filter { $0.mailbox == path }.count } ?? 0

        // Targets.
        let expected = state.messagesByTarget()

        let mboxCounts = inputs.mboxDirectory.map { countMboxes(in: $0, exportDirectory: inputs.exportDirectory) }

        var icloudFolders: [[String]: [FetchRecord]] = [:]
        if let connect = inputs.icloud {
            icloudFolders = try await withClient(connect) { client in
                var folders: [[String]: [FetchRecord]] = [:]
                // Only folders the export fills; other iCloud folders are not read.
                for box in try await client.list() where box.isSelectable
                    && expected.contains(where: { Uploader.same(box.components, $0.target) }) {
                    let selected = try await client.examine(box)
                    folders[box.components] = selected.exists == 0 ? [] : try await client.fetchAllMetadata(withMessageID: true)
                }
                return folders
            }
        }

        var targets: [VerifyReport.TargetRow] = []
        for (target, entries) in expected {
            var row = VerifyReport.TargetRow(folder: target.joined(separator: "/"), expected: entries.count,
                                             mbox: nil, icloud: nil, missingInICloud: [], extraInICloud: 0)
            if let mboxCounts {
                row.mbox = mboxCounts.byTarget.map { $0[row.folder] ?? 0 }
                    ?? mboxCounts.byFolder[row.folder.lowercased()] ?? 0
            }
            if inputs.icloud != nil {
                let records = icloudFolders.first { Uploader.same($0.key, target) }?.value ?? []
                row.icloud = records.count
                var present = Uploader.PresentSet()
                for record in records { present.add(Uploader.key(record)) }
                for entry in entries {
                    if !present.take(Uploader.key(entry, state)) { row.missingInICloud.append(.init(hash: entry.hash, messageID: entry.messageID)) }
                }
                row.extraInICloud = present.counts.values.reduce(0, +)
            }
            targets.append(row)
        }

        return VerifyReport(generatedAt: Date(), sources: sources, targets: targets, skipped: state.skipped,
                            distinctMessages: state.messages.count, allMailCount: allMailCount,
                            allMailAccountedFor: allMailLocations, allMailSkipped: allMailSkipped)
    }

    /// Runs `body` on a fresh connection and always closes it, also when `body` throws.
    private static func withClient<T: Sendable>(_ connect: @Sendable () async throws -> IMAPClient,
                                                _ body: (IMAPClient) async throws -> T) async throws -> T {
        let client = try await connect()
        do {
            let value = try await body(client)
            await client.logout()
            await client.close()
            return value
        } catch {
            await client.close()
            throw error
        }
    }

    struct MboxCounts {
        /// Exact, from the index `mbox` wrote for this output folder.
        var byTarget: [String: Int]?
        /// Fallback when there is no index: by lower-cased bundle path, split parts merged.
        var byFolder: [String: Int] = [:]
    }

    static func countMboxes(in root: URL, exportDirectory: URL) -> MboxCounts {
        let indexURL = exportDirectory.appendingPathComponent(MboxWriter.Index.fileName)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder().decode(MboxWriter.Index.self, from: data),
           index.output == root.standardizedFileURL.path {
            var counts: [String: Int] = [:]
            for (target, files) in index.files {
                counts[target] = files.reduce(0) { $0 + countMessages(in: root.appendingPathComponent($1)) }
            }
            return MboxCounts(byTarget: counts)
        }
        return MboxCounts(byFolder: countMboxes(in: root))
    }

    /// Number of messages in one mbox file written by `MboxWriter`.
    static func countMessages(in file: URL) -> Int {
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped), !data.isEmpty else { return 0 }
        let separator = Data("\nFrom slop-export@localhost ".utf8)
        var count = data.starts(with: Data("From slop-export@localhost ".utf8)) ? 1 : 0
        var index = data.startIndex
        while let range = data.range(of: separator, in: index..<data.endIndex) {
            count += 1
            index = range.upperBound
        }
        return count
    }

    /// Message count per mailbox in an Apple Mail export folder, keyed by lower-cased folder path.
    /// Split parts ("Name (2).mbox") are added to their folder. Used when there is no index.
    static func countMboxes(in root: URL) -> [String: Int] {
        var out: [String: Int] = [:]
        // Resolve symlinks on both sides: on macOS the enumerator reports /private/var/... for /var/....
        let base = root.resolvingSymlinksInPath().pathComponents
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in walker where url.lastPathComponent == "mbox" {
            let relative = url.deletingLastPathComponent().resolvingSymlinksInPath().pathComponents
                .dropFirst(base.count).joined(separator: "/")
            let folder = relative.split(separator: "/").map { component -> String in
                var name = String(component.dropLast(".mbox".count))
                if let range = name.range(of: #" \(\d+\)$"#, options: .regularExpression) { name.removeSubrange(range) }
                return name
            }.joined(separator: "/").lowercased()
            out[folder, default: 0] += countMessages(in: url)
        }
        return out
    }
}
