import Foundation

/// The shared state of one upload: the work queue, the duplicate-check counts, the summary, the
/// pacing and the journal. Connections only meet here, one at a time (D-018).
actor UploadRun {
    private let uploader: Uploader
    private let units: [Uploader.WorkUnit]
    private var nextUnit = 0
    /// Units a dropped connection left part done. Taken before new ones.
    private var requeued: [Uploader.WorkUnit] = []
    /// Connections still taking work.
    private var active = 0
    /// Per folder: what it held when this run read it, and what this run has APPENDed since.
    private let held: [String: Uploader.PresentSet]
    private var added: [String: Uploader.PresentSet] = [:]
    private var summary: UploadSummary
    private let total: Int
    private var done: Int
    private var bytes = 0
    private var lastFolder: String?
    private let maxRefusals: Int
    /// Per connection, refusals not yet recorded: only kept as real refusals once a later
    /// message gets through on the same connection, so a server refusing everything never marks
    /// the whole export as failed, and one connection's success never vouches for another's.
    private var refusals: [Int: [(entry: MessageEntry, target: [String], text: String)]] = [:]
    private let interval: Duration
    private var nextSlot: ContinuousClock.Instant?
    private let progress: @Sendable (UploadProgress) -> Void

    init(uploader: Uploader, units: [Uploader.WorkUnit], held: [String: Uploader.PresentSet], summary: UploadSummary,
         total: Int, maxRefusals: Int, interval: Duration, progress: @escaping @Sendable (UploadProgress) -> Void) {
        self.uploader = uploader
        self.units = units
        self.held = held
        self.summary = summary
        self.total = total
        self.done = summary.alreadyThere
        self.maxRefusals = maxRefusals
        self.interval = interval
        self.progress = progress
    }

    /// A connection is ready to take work.
    func join() { active += 1 }

    /// The next unit, or nil when there is none, which also ends the caller's share of the run.
    func next() -> Uploader.WorkUnit? {
        if let unit = requeued.popLast() { return unit }
        guard nextUnit < units.count else {
            active -= 1
            return nil
        }
        defer { nextUnit += 1 }
        return units[nextUnit]
    }

    /// A connection failed for good. If another one is still taking work, hands it what was
    /// left (checked before resending, as it may have landed) and returns true; otherwise the
    /// caller ends the run with its error.
    func retire(leaving unit: Uploader.WorkUnit?) -> Bool {
        guard active > 1 else { return false }
        active -= 1
        if var unit {
            unit.checkFirst = true
            requeued.append(unit)
        }
        return true
    }

    /// Waits for this APPEND's turn: at most one starts per `interval` across all connections.
    func pace() async throws {
        guard interval > .zero else { return }
        let now = ContinuousClock.now
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot + interval
        if slot > now { try await Task.sleep(until: slot, clock: .continuous) }
    }

    /// How many copies of `key` the folder should hold if nothing this run sent is unaccounted for.
    func expected(_ key: Uploader.PresenceKey, in path: String) -> Int {
        (held[path]?.count(key) ?? 0) + (added[path]?.count(key) ?? 0)
    }

    func uploaded(_ entry: MessageEntry, unit: Uploader.WorkUnit, bytes count: Int, connection: Int) throws {
        try uploader.recordUploaded(entry, path: unit.path)
        added[unit.path, default: .init()].add(unit.key)
        summary.uploaded += 1
        bytes += count
        try settleRefusals(connection)
        done += 1
        lastFolder = unit.path
        report()
    }

    func refused(_ entry: MessageEntry, unit: Uploader.WorkUnit, text: String, connection: Int) throws {
        refusals[connection, default: []].append((entry, unit.target, text))
        done += 1
        lastFolder = unit.path
        report()
        if refusals[connection]!.count >= maxRefusals { throw UploadError.stoppedByServer(text) }
    }

    func finish() throws -> UploadSummary {
        for connection in refusals.keys { try settleRefusals(connection) }
        return summary
    }

    /// Progress over the whole upload; `folder` is where the latest message went. A `message`
    /// (a retry, a dropped connection) rides along with the counts so the bar stays up.
    func report(_ message: String? = nil) {
        progress(UploadProgress(folder: lastFolder ?? units.first?.path, done: done, total: total, bytes: bytes,
                                message: message))
    }

    private func settleRefusals(_ connection: Int) throws {
        for refusal in refusals[connection] ?? [] {
            try uploader.recordRefused(refusal.entry, target: refusal.target, text: refusal.text)
            summary.failed += 1
        }
        refusals[connection] = nil
    }
}
