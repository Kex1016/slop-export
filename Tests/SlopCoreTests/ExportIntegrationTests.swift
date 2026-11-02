import Foundation
import XCTest
@testable import SlopCore

/// Phase 3 against the Dovecot "Bridge" fixture. See Fixtures/slopfixture.py for the corpus.
final class ExportIntegrationTests: XCTestCase {
    var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slop-export-test-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func exporter(_ fx: FixtureServer, options: Exporter.Options = .init()) throws -> Exporter {
        try Exporter(directory: dir, settings: fx.bridgeSettings, password: fx.password, options: options)
    }

    private func entry(_ state: ExportState, mid: String) -> MessageEntry? {
        state.messages.values.first { $0.messageID == "<\(mid)@fixture.example.test>" }
    }

    func testFullExport() async throws {
        let fx = try FixtureServer.load("bridge")
        let exporter = try exporter(fx)
        let summary = try await exporter.run()
        let state = exporter.state

        // 13 messages in All Mail; m01 and m10 have identical bytes, so 12 distinct.
        XCTAssertEqual(summary.distinctMessages, 12)
        XCTAssertEqual(summary.unfiled, 2)
        XCTAssertEqual(Set(state.unfiled.compactMap(\.messageID)),
                       ["<m11-allmail-only@fixture.example.test>", "<m13-starred-unfiled@fixture.example.test>"])
        XCTAssertEqual(state.targets(for: state.unfiled[0]), [["Unfiled"]])
        // 11 folder messages + m13 (from Starred) + m11 and m07 (no Message-ID) from All Mail.
        // m13 is not fetched again for All Mail (D-009).
        XCTAssertEqual(summary.downloadedThisRun, 14)
        let starredUnfiled = try XCTUnwrap(entry(state, mid: "m13-starred-unfiled"))
        XCTAssertEqual(state.flags(for: starredUnfiled, in: ["Unfiled"]), [#"\Flagged"#, #"\Seen"#])
        XCTAssertEqual(state.mailboxes["INBOX"]?.complete, true)
        XCTAssertTrue(state.skipped.isEmpty)

        // Every hash in the journal has a file in the store.
        for hash in state.messages.keys { XCTAssertTrue(exporter.store.contains(hash), hash) }

        // Labels are never opened.
        XCTAssertNil(state.mailboxes["Labels/Important"]?.uidValidity)
        XCTAssertFalse(state.messages.values.contains { $0.locations.contains { $0.mailbox.hasPrefix("Labels/") } })

        // Duplicate bytes in two folders: one stored file, two targets.
        let dup = try XCTUnwrap(entry(state, mid: "m01-unread"))
        XCTAssertEqual(Set(state.targets(for: dup)), [["INBOX"], ["Ünïcödé Ordner"]])
        XCTAssertEqual(state.flags(for: dup, in: ["INBOX"]), [])
        XCTAssertEqual(state.flags(for: dup, in: ["Ünïcödé Ordner"]), [#"\Seen"#])

        // Flags.
        let starred = try XCTUnwrap(entry(state, mid: "m02-starred-utf8"))
        XCTAssertEqual(state.flags(for: starred, in: ["INBOX"]), [#"\Flagged"#, #"\Seen"#])
        let sent = try XCTUnwrap(entry(state, mid: "m03-sent-answered"))
        XCTAssertEqual(state.flags(for: sent, in: ["Sent Messages"]), [#"\Answered"#, #"\Seen"#])
        let draft = try XCTUnwrap(entry(state, mid: "m04-draft"))
        XCTAssertEqual(state.flags(for: draft, in: ["Drafts"]), [#"\Draft"#, #"\Seen"#])

        // Dates are the INTERNALDATE, not the download time.
        let date = try XCTUnwrap(state.internalDate(for: starred))
        XCTAssertEqual([date.year, date.month, date.day, date.hour, date.minute], [2020, 7, 14, 16, 30])

        // Big attachment arrives intact.
        let big = try XCTUnwrap(entry(state, mid: "m05-attachment"))
        XCTAssertGreaterThan(big.size, 3_000_000)
        XCTAssertEqual(try exporter.store.read(big.hash).count, big.size)

        // Message without Message-ID: stored once, in its folder, not Unfiled.
        let noMID = state.messages.values.filter { $0.messageID == nil }
        XCTAssertEqual(noMID.count, 1)
        XCTAssertEqual(state.targets(for: noMID[0]), [["Work"]])

        // Raw bytes are untouched (Latin-1 header bytes survive).
        let latin1 = try XCTUnwrap(entry(state, mid: "m06-latin1"))
        XCTAssertTrue(try exporter.store.read(latin1.hash).contains(Data([0x4D, 0x65, 0x6E, 0xFC]))) // "Menü" in Latin-1

        // manifest.json is written and readable.
        let manifest = try Manifest.read(from: dir.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest.messages.count, 12)
        XCTAssertTrue(manifest.mailboxes.contains { $0.path == "Labels/Receipts" && $0.role == .skippedLabel })
    }

    func testRerunAddsNothing() async throws {
        let fx = try FixtureServer.load("bridge")
        _ = try await exporter(fx).run()
        let again = try exporter(fx)
        let summary = try await again.run()
        XCTAssertEqual(summary.downloadedThisRun, 0)
        XCTAssertEqual(summary.matchedWithoutDownload, 0)
        XCTAssertEqual(summary.distinctMessages, 12)
    }

    func testResumesAfterCrashWithoutDuplicates() async throws {
        let fx = try FixtureServer.load("bridge")
        let first = try exporter(fx)
        _ = try await first.run()
        let complete = first.state

        // Simulate a crash: keep only the first third of the journal and tear the last line.
        let journal = dir.appendingPathComponent("journal.jsonl")
        let lines = try String(contentsOf: journal, encoding: .utf8).split(separator: "\n")
        let kept = lines.prefix(lines.count / 3).joined(separator: "\n") + "\n" + lines[lines.count / 3].prefix(20)
        try kept.write(to: journal, atomically: true, encoding: .utf8)

        let resumed = try exporter(fx)
        let summary = try await resumed.run()
        XCTAssertGreaterThan(summary.downloadedThisRun + summary.matchedWithoutDownload, 0)
        XCTAssertEqual(Set(resumed.state.messages.keys), Set(complete.messages.keys))
        for (hash, entry) in complete.messages {
            XCTAssertEqual(resumed.state.messages[hash]?.locations.count, entry.locations.count, hash)
        }
    }

    func testSmallBatchesGiveTheSameResult() async throws {
        let fx = try FixtureServer.load("bridge")
        var options = Exporter.Options()
        options.maxBatchMessages = 1
        options.maxBatchBytes = 1
        let summary = try await exporter(fx, options: options).run()
        XCTAssertEqual(summary.distinctMessages, 12)
    }

    func testExportMarksNothingRead() async throws {
        let fx = try FixtureServer.load("bridge")
        _ = try await exporter(fx).run()
        let client = try await IMAPClient.connect(to: fx.bridgeSettings.endpoint())
        try await client.login(user: fx.user, password: fx.password)
        let inbox = try await client.list().first { $0.displayPath == "INBOX" }!
        _ = try await client.examine(inbox)
        let unread = try await client.fetchAllMetadata().filter { !$0.flags.contains(#"\Seen"#) }
        XCTAssertEqual(unread.count, 1)
        await client.close()
    }
}
