import Foundation
import XCTest
@testable import SlopCore

/// Phase 5 against the fixtures: export from "bridge", upload to "icloud". Each test uploads to
/// its own empty iCloud fixture account (user-N@...), so tests never see each other's uploads.
final class UploadIntegrationTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slop-upload-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func export() async throws -> URL {
        let fx = try FixtureServer.load("bridge")
        let out = dir.appendingPathComponent("export")
        _ = try await Exporter(directory: out, settings: fx.bridgeSettings, password: fx.password).run()
        return out
    }

    private func icloudEndpoint(_ fx: FixtureServer) throws -> ServerEndpoint {
        ServerEndpoint(host: fx.host, port: fx.port, tls: .implicit,
                       trust: .pinned(try PinnedCertificate(contentsOf: URL(fileURLWithPath: fx.cert))))
    }

    private func account(_ n: Int) throws -> String {
        try FixtureServer.load("icloud").user.replacingOccurrences(of: "@", with: "-\(n)@")
    }

    private func uploader(_ exportDir: URL, account n: Int, connections: Int = Uploader.Options().connections,
                          maxLogins: Int = .max, configure: (inout Uploader.Options) -> Void = { _ in },
                          onLogin: @escaping @Sendable (Int, IMAPClient) -> Void = { _, _ in },
                          progress: @escaping @Sendable (UploadProgress) -> Void = { _ in }) throws -> Uploader {
        let fx = try FixtureServer.load("icloud")
        let endpoint = try icloudEndpoint(fx)
        let user = try account(n)
        var options = Uploader.Options()
        options.connections = connections
        configure(&options)
        let logins = Counter()
        return try Uploader(exportDirectory: exportDir, options: options, connect: {
            // Stands in for iCloud turning away connections over its per-account limit.
            let number = logins.increment()
            guard number <= maxLogins else {
                throw IMAPError.commandFailed(command: "LOGIN", status: "NO", text: "[LIMIT] too many connections")
            }
            let client = try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: fx.password)
            onLogin(number, client)
            return client
        }, progress: progress)
    }

    /// Every folder with the (Message-ID, size, date) of what it holds, for comparing two accounts.
    private func contents(account n: Int) async throws -> [String: [String]] {
        try await icloudFolders(account: n).mapValues { records in
            records.map { "\(Uploader.key($0))|\($0.flags.sorted())" }.sorted()
        }
    }

    private func icloudFolders(account n: Int) async throws -> [String: [FetchRecord]] {
        let fx = try FixtureServer.load("icloud")
        let client = try await IMAPClient.connectAndLogin(to: try icloudEndpoint(fx), user: try account(n), password: fx.password)
        var out: [String: [FetchRecord]] = [:]
        for box in try await client.list() where box.isSelectable {
            let selected = try await client.examine(box)
            out[box.displayPath] = selected.exists == 0 ? [] : try await client.fetchAllMetadata(withMessageID: true)
        }
        await client.close()
        return out
    }

    func testDryRunThenUploadThenRerun() async throws {
        let exportDir = try await export()

        let plan = try await uploader(exportDir, account: 1).plan()
        XCTAssertEqual(plan.messagesToUpload, 13)
        XCTAssertEqual(Set(plan.foldersToCreate), ["Unfiled", "Work", "Work/Projects", "Ünïcödé Ordner", "Empty"],
                       "empty folders are created too, so the structure matches")
        XCTAssertNotNil(plan.quotaLimit, "fixture advertises QUOTA like iCloud")
        XCTAssertNil(plan.shortfall)
        // The dry run wrote nothing.
        let before = try await icloudFolders(account: 1)
        XCTAssertEqual(before.values.map(\.count).reduce(0, +), 0)
        XCTAssertNil(before["Unfiled"])

        let summary = try await uploader(exportDir, account: 1).run()
        XCTAssertEqual(summary.uploaded, 13)
        XCTAssertEqual(summary.failed, 0)

        let after = try await icloudFolders(account: 1)
        XCTAssertEqual(after["INBOX"]?.count, 2)
        XCTAssertEqual(after["Empty"]?.count, 0)
        XCTAssertEqual(after["Sent Messages"]?.count, 1)
        XCTAssertEqual(after["Junk"]?.count, 1)
        XCTAssertEqual(after["Deleted Messages"]?.count, 1)
        XCTAssertEqual(after["Work/Projects"]?.count, 1)
        XCTAssertEqual(after["Unfiled"]?.count, 2)

        // Flags and dates survive (acceptance criteria 3 and 4).
        let inbox = try XCTUnwrap(after["INBOX"])
        let starred = try XCTUnwrap(inbox.first { $0.flags.contains(#"\Flagged"#) })
        XCTAssertTrue(starred.flags.contains(#"\Seen"#))
        let date = IMAPDate(try XCTUnwrap(starred.internalDate))
        XCTAssertEqual([date.year, date.month, date.day, date.hour, date.minute], [2020, 7, 14, 16, 30])
        XCTAssertEqual(inbox.filter { !$0.flags.contains(#"\Seen"#) }.count, 1, "unread stays unread")
        XCTAssertTrue(after["Sent Messages"]![0].flags.contains(#"\Answered"#))
        XCTAssertTrue(after["Drafts"]![0].flags.contains(#"\Draft"#))

        // Re-running uploads nothing (acceptance criterion 6).
        let again = try await uploader(exportDir, account: 1).run()
        XCTAssertEqual(again.uploaded, 0)
        XCTAssertEqual(again.alreadyThere, 13)
    }

    func testLostJournalDoesNotDuplicate() async throws {
        let exportDir = try await export()
        _ = try await uploader(exportDir, account: 2).run()
        // Crash between APPEND and journal write, for every message.
        try FileManager.default.removeItem(at: exportDir.appendingPathComponent("upload.jsonl"))
        let again = try await uploader(exportDir, account: 2).run()
        XCTAssertEqual(again.uploaded, 0)
        let after = try await icloudFolders(account: 2)
        XCTAssertEqual(after.values.map(\.count).reduce(0, +), 13)
    }

    func testOneConnectionAndSeveralGiveTheSameResult() async throws {
        let exportDir = try await export()
        let parallel = try await uploader(exportDir, account: 5, connections: 4).run()
        let serialDir = dir.appendingPathComponent("serial")
        try FileManager.default.copyItem(at: exportDir, to: serialDir)
        try FileManager.default.removeItem(at: serialDir.appendingPathComponent("upload.jsonl"))
        // Asks for four, but only the first login works, as if iCloud capped connections: the
        // upload carries on over the one it has.
        let serial = try await uploader(serialDir, account: 7, connections: 4, maxLogins: 1).run()
        XCTAssertEqual(parallel.uploaded, 13)
        XCTAssertEqual(serial.uploaded, 13)
        let a = try await contents(account: 5)
        let b = try await contents(account: 7)
        XCTAssertEqual(a.values.map(\.count).reduce(0, +), 13)
        XCTAssertEqual(a, b, "same folders, messages, sizes, dates and flags either way")
    }

    func testAConnectionLostForGoodHandsItsWorkToTheOthers() async throws {
        let exportDir = try await export()
        // The second connection is cut a moment in, and iCloud refuses to let it back in (only
        // four logins work). Whatever it was doing is finished by the other three.
        let notes = Notes()
        let up = try uploader(exportDir, account: 10, connections: 4, maxLogins: 4, configure: {
            $0.appendInterval = .milliseconds(100)
            $0.retryBaseDelay = .milliseconds(50)
        }, onLogin: { number, client in
            guard number == 2 else { return }
            Task {
                try await Task.sleep(for: .milliseconds(250))
                await client.close()
            }
        }, progress: { if let message = $0.message { notes.add(message) } })
        let summary = try await up.run()
        XCTAssertEqual(summary.uploaded, 13)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertTrue(notes.all.contains { $0.contains("fewer connections") }, notes.all.joined(separator: "\n"))
        let after = try await icloudFolders(account: 10)
        XCTAssertEqual(after.values.map(\.count).reduce(0, +), 13)
        let again = try await uploader(exportDir, account: 10).run()
        XCTAssertEqual(again.alreadyThere, 13)
    }

    func testStoppedPartWayThenResumedHasNoDuplicates() async throws {
        let exportDir = try await export()
        // Stop as soon as a few messages are in, like David pressing Pause mid-run.
        let handle = TaskBox()
        let pausing = try uploader(exportDir, account: 9, connections: 4, progress: { p in
            if p.message == nil, p.done >= 4 { handle.cancel() }
        })
        let task = Task { try await pausing.run() }
        handle.set(task)
        do {
            _ = try await task.value
            XCTFail("expected the run to stop part way")
        } catch is CancellationError {}
        let partial = try await icloudFolders(account: 9).values.map(\.count).reduce(0, +)
        XCTAssertGreaterThan(partial, 0)
        XCTAssertLessThan(partial, 13)
        // Drop the journal too, as if the app was killed before writing it.
        try FileManager.default.removeItem(at: exportDir.appendingPathComponent("upload.jsonl"))
        let resumed = try await uploader(exportDir, account: 9).run()
        XCTAssertEqual(resumed.uploaded, 13 - partial)
        XCTAssertEqual(resumed.alreadyThere, partial)
        let after = try await icloudFolders(account: 9)
        XCTAssertEqual(after.values.map(\.count).reduce(0, +), 13)
    }

    func testBusyAnswersAreNotRefusals() {
        XCTAssertTrue(Uploader.isBusy("[UNAVAILABLE] Server busy, try again later"))
        XCTAssertTrue(Uploader.isBusy("Rate limit exceeded"))
        XCTAssertFalse(Uploader.isBusy("[LIMIT] Message too large"))
        XCTAssertFalse(Uploader.isBusy("[LIMIT] Message too large, try again with a smaller one"))
        XCTAssertFalse(Uploader.isBusy("[OVERQUOTA] Quota exceeded"))
        XCTAssertFalse(Uploader.isBusy("Over quota, try again later"), "waiting does not fix quota")
    }

    func testQuotaShortfall() {
        let plan = UploadPlan(folders: [.init(path: "INBOX", exists: true, toUpload: 1, alreadyThere: 0, bytes: 600)],
                              quotaUsed: 500, quotaLimit: 1000)
        XCTAssertEqual(plan.shortfall, 100)
        let fits = UploadPlan(folders: plan.folders, quotaUsed: 0, quotaLimit: 1000)
        XCTAssertNil(fits.shortfall)
        let unknown = UploadPlan(folders: plan.folders, quotaUsed: nil, quotaLimit: nil)
        XCTAssertNil(unknown.shortfall)
    }
}

/// Lets the progress callback cancel the task running the upload.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<UploadSummary, Error>?
    private var cancelled = false
    func set(_ task: Task<UploadSummary, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.task = task
        if cancelled { task.cancel() }
    }
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
        task?.cancel()
    }
}

/// Collects progress messages from several connections.
private final class Notes: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []
    func add(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        messages.append(message)
    }
    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }
}

/// A thread-safe counter for the connect closure.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
