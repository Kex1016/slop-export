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

    private func uploader(_ exportDir: URL, account n: Int) throws -> Uploader {
        let fx = try FixtureServer.load("icloud")
        let endpoint = try icloudEndpoint(fx)
        let user = try account(n)
        return try Uploader(exportDirectory: exportDir, connect: {
            try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: fx.password)
        })
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
