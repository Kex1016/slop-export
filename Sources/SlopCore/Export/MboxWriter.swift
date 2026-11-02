import Foundation

/// Phase 4 (Path A): writes Apple Mail mailbox bundles from the store and journal.
///
/// Layout mirrors what Apple Mail itself exports: `Work.mbox/mbox`, and a subfolder lives inside
/// its parent's bundle as `Work.mbox/Projects.mbox/mbox`. Messages are mboxrd-escaped, use LF
/// line endings, are ordered by date, and carry `Status`/`X-Status` headers so read, answered,
/// flagged and draft state survive the import.
public struct MboxWriter: Sendable {
    public struct Options: Sendable {
        /// A mailbox bigger than this is split into "Name.mbox", "Name (2).mbox", ... (D-010).
        public var maxMboxBytes: Int = 1 << 30
        public init() {}
    }

    public struct Result: Sendable {
        public var mailboxes: [String: Int] = [:]
        public var messages = 0
        public var bytes = 0
    }

    public let store: MessageStore
    public let options: Options

    public init(store: MessageStore, options: Options = Options()) {
        self.store = store
        self.options = options
    }

    /// Rebuilds `outputDirectory` from scratch. Re-running gives the same output.
    @discardableResult
    public func write(state: ExportState, to outputDirectory: URL) throws -> Result {
        let fm = FileManager.default
        if fm.fileExists(atPath: outputDirectory.path) { try fm.removeItem(at: outputDirectory) }
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        var byTarget: [[String]: [MessageEntry]] = [:]
        for entry in state.messages.values {
            for target in state.targets(for: entry) { byTarget[target, default: []].append(entry) }
        }

        var result = Result()
        var allocator = BundleAllocator(root: outputDirectory)
        for target in byTarget.keys.sorted(by: { $0.joined(separator: "/") < $1.joined(separator: "/") }) {
            // Sort keys computed once per message, not once per comparison.
            let entries = byTarget[target]!
                .map { (date: state.internalDate(for: $0)?.date ?? .distantPast, entry: $0) }
                .sorted { ($0.date, $0.entry.hash) < ($1.date, $1.entry.hash) }
            var part = 1
            var handle = try openMbox(allocator.bundle(for: target, part: part))
            var written = 0
            for (date, entry) in entries {
                let data = Self.encode(raw: try store.read(entry.hash), flags: state.flags(for: entry, in: target),
                                       date: date == .distantPast ? Date(timeIntervalSince1970: 0) : date)
                if written > 0, written + data.count > options.maxMboxBytes {
                    try handle.close()
                    part += 1
                    handle = try openMbox(allocator.bundle(for: target, part: part))
                    written = 0
                }
                try handle.write(contentsOf: data)
                written += data.count
                result.bytes += data.count
                result.messages += 1
            }
            try handle.close()
            result.mailboxes[target.joined(separator: "/")] = entries.count
        }
        return result
    }

    /// Hands out bundle directories so that no two mailboxes share one. Folder names that differ
    /// only in case (APFS is case-insensitive) or that sanitise to the same name get " (2)", " (3)"...
    struct BundleAllocator {
        let root: URL
        /// Lower-cased relative path of every leaf bundle handed out so far.
        private var used: Set<String> = []
        /// Parent chain already assigned to a target prefix, so children land in their parent's bundle.
        private var assigned: [[String]: URL] = [:]

        init(root: URL) { self.root = root }

        mutating func bundle(for target: [String], part: Int) -> URL {
            let parent = target.count > 1 ? (assigned[Array(target.dropLast())] ?? MboxWriter.bundleURL(
                for: Array(target.dropLast()), part: 1, root: root)) : root
            let base = MboxWriter.safeComponent(target.last ?? "_")
            var suffix = part
            while true {
                let name = suffix > 1 ? "\(base) (\(suffix)).mbox" : "\(base).mbox"
                let url = parent.appendingPathComponent(name, isDirectory: true)
                let key = url.path.lowercased()
                if !used.contains(key) {
                    used.insert(key)
                    if part == 1 { assigned[target] = url }
                    return url
                }
                suffix += 1
            }
        }
    }

    // MARK: Paths

    /// Directory for a target path: every component becomes a `.mbox` bundle nested in its parent.
    static func bundleURL(for target: [String], part: Int, root: URL) -> URL {
        var url = root
        for (i, component) in target.enumerated() {
            var name = safeComponent(component)
            if i == target.count - 1, part > 1 { name += " (\(part))" }
            url.appendPathComponent(name + ".mbox", isDirectory: true)
        }
        return url
    }

    /// Folder names come from the mail server, so they must never escape the output folder.
    static func safeComponent(_ name: String) -> String {
        var cleaned = name.map { ch -> Character in
            switch ch {
            case "/", ":", "\\", "\0": return "_"
            default: return ch.isNewline ? " " : ch
            }
        }.reduce(into: "") { $0.append($1) }
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        if cleaned.isEmpty || cleaned.hasPrefix(".") { cleaned = "_" + cleaned }
        return cleaned
    }

    private func openMbox(_ dir: URL) throws -> FileHandle {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("mbox")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: file.path])
        }
        return try FileHandle(forWritingTo: file)
    }

    // MARK: Message encoding

    static func encode(raw: Data, flags: [String], date: Date) -> Data {
        var out = Data("From slop-export@localhost \(asctime(date))\n".utf8)
        var status = ""
        if flags.contains(#"\Seen"#) { status += "R" }
        status += "O"
        var xStatus = ""
        if flags.contains(#"\Answered"#) { xStatus += "A" }
        if flags.contains(#"\Flagged"#) { xStatus += "F" }
        if flags.contains(#"\Draft"#) { xStatus += "T" }
        out.append(Data("Status: \(status)\n".utf8))
        if !xStatus.isEmpty { out.append(Data("X-Status: \(xStatus)\n".utf8)) }

        var inHeaders = true
        for var line in raw.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            if line.last == UInt8(ascii: "\r") { line = line.dropLast() }
            if inHeaders {
                if line.isEmpty {
                    inHeaders = false
                } else if isHeader(line, named: "Status") || isHeader(line, named: "X-Status") {
                    continue  // ours replace any the message already had
                }
            }
            if isFromLine(line) { out.append(UInt8(ascii: ">")) }
            out.append(contentsOf: line)
            out.append(UInt8(ascii: "\n"))
        }
        // The split leaves one empty element after a trailing newline; mbox wants exactly one
        // blank line between messages.
        if out.suffix(2) != Data("\n\n".utf8) { out.append(UInt8(ascii: "\n")) }
        return out
    }

    /// mboxrd: any line that is `From ` preceded by zero or more `>` gets one more `>`.
    static func isFromLine(_ line: Data.SubSequence) -> Bool {
        var i = line.startIndex
        while i < line.endIndex, line[i] == UInt8(ascii: ">") { i += 1 }
        let rest = line[i...]
        return rest.starts(with: Data("From ".utf8))
    }

    static func isHeader(_ line: Data.SubSequence, named name: String) -> Bool {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return false }
        return String(decoding: line[line.startIndex..<colon], as: UTF8.self).caseInsensitiveCompare(name) == .orderedSame
    }

    /// `Tue Jul 14 16:30:00 2020`, in UTC.
    /// DateFormatter is thread-safe for formatting; one shared instance avoids a new one per message.
    nonisolated(unsafe) private static let asctimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }()

    static func asctime(_ date: Date) -> String {
        var s = asctimeFormatter.string(from: date)
        // asctime pads the day to two characters with a space.
        let parts = s.split(separator: " ", omittingEmptySubsequences: false)
        if parts.count == 5, parts[2].count == 1 { s = "\(parts[0]) \(parts[1])  \(parts[2]) \(parts[3]) \(parts[4])" }
        return s
    }
}
