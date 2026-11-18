import Foundation

/// The shared state of one upload: the work queue, the duplicate-check counts, the summary and
/// the journal. Workers on different connections only meet here, one at a time.
actor UploadRun {
    private let uploader: Uploader
    private let units: [Uploader.WorkUnit]
    private var nextUnit = 0
    /// Per folder: what it held before this run that no export entry has claimed yet, and what
    /// this run has accounted for (claimed copies plus its own APPENDs).
    private var present: [String: Uploader.PresentSet]
    private var accounted: [String: Uploader.PresentSet]
    private var summary: UploadSummary
    private let total: Int
    private var done: Int
    private var bytes = 0
    private let maxRefusals: Int
    /// Refusals not yet recorded: only kept as real refusals once a later message gets
    /// through, so a server refusing everything never marks the whole export as failed.
    private var refusals: [(entry: MessageEntry, target: [String], text: String)] = []
    private let progress: @Sendable (UploadProgress) -> Void

    init(uploader: Uploader, units: [Uploader.WorkUnit], present: [String: Uploader.PresentSet],
         accounted: [String: Uploader.PresentSet], summary: UploadSummary, total: Int, maxRefusals: Int,
         progress: @escaping @Sendable (UploadProgress) -> Void) {
        self.uploader = uploader
        self.units = units
        self.present = present
        self.accounted = accounted
        self.summary = summary
        self.total = total
        self.done = summary.alreadyThere
        self.maxRefusals = maxRefusals
        self.progress = progress
    }

    func next() -> Uploader.WorkUnit? {
        guard nextUnit < units.count else { return nil }
        defer { nextUnit += 1 }
        return units[nextUnit]
    }

    /// How many copies of `key` the folder should hold if nothing this run sent is unaccounted for.
    func expected(_ key: Uploader.PresenceKey, in path: String) -> Int {
        (present[path]?.count(key) ?? 0) + (accounted[path]?.count(key) ?? 0)
    }

    func uploaded(_ entry: MessageEntry, unit: Uploader.WorkUnit, bytes count: Int) throws {
        try uploader.recordUploaded(entry, path: unit.path)
        accounted[unit.path, default: .init()].add(unit.key)
        summary.uploaded += 1
        bytes += count
        try settleRefusals()
        done += 1
        report(folder: unit.path)
    }

    func refused(_ entry: MessageEntry, unit: Uploader.WorkUnit, text: String) throws {
        refusals.append((entry, unit.target, text))
        done += 1
        report(folder: unit.path)
        if refusals.count >= maxRefusals { throw UploadError.stoppedByServer(text) }
    }

    func finish() throws -> UploadSummary {
        try settleRefusals()
        return summary
    }

    /// Progress over the whole upload; `folder` is where the latest message went.
    func report(folder: String?) {
        progress(UploadProgress(folder: folder ?? units.first?.path, done: done, total: total, bytes: bytes))
    }

    private func settleRefusals() throws {
        for refusal in refusals {
            try uploader.recordRefused(refusal.entry, target: refusal.target, text: refusal.text)
            summary.failed += 1
        }
        refusals.removeAll()
    }
}
