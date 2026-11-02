import Foundation
import XCTest
@testable import SlopCore

/// Phase 6 against the fixtures: export, Apple Mail output and upload, then verify all of them.
final class VerifyIntegrationTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slop-verify-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    private func connectors(icloudAccount n: Int) throws -> (bridge: @Sendable () async throws -> IMAPClient,
                                                            icloud: @Sendable () async throws -> IMAPClient) {
        let bridgeFx = try FixtureServer.load("bridge")
        let bridgeEndpoint = try bridgeFx.bridgeSettings.endpoint()
        let icloudFx = try FixtureServer.load("icloud")
        let icloudEndpoint = ServerEndpoint(host: icloudFx.host, port: icloudFx.port, tls: .implicit,
                                            trust: .pinned(try PinnedCertificate(contentsOf: URL(fileURLWithPath: icloudFx.cert))))
        let icloudUser = icloudFx.user.replacingOccurrences(of: "@", with: "-\(n)@")
        return ({ try await IMAPClient.connectAndLogin(to: bridgeEndpoint, user: bridgeFx.user, password: bridgeFx.password) },
                { try await IMAPClient.connectAndLogin(to: icloudEndpoint, user: icloudUser, password: icloudFx.password) })
    }

    private func exportAndMbox() async throws -> (export: URL, mbox: URL) {
        let fx = try FixtureServer.load("bridge")
        let exportDir = dir.appendingPathComponent("export")
        _ = try await Exporter(directory: exportDir, settings: fx.bridgeSettings, password: fx.password).run()
        let mboxDir = dir.appendingPathComponent("mbox")
        try MboxWriter.build(exportDirectory: exportDir, to: mboxDir)
        return (exportDir, mboxDir)
    }

    func testEverythingPassesAfterUpload() async throws {
        let (exportDir, mboxDir) = try await exportAndMbox()
        let connect = try connectors(icloudAccount: 3)
        _ = try await Uploader(exportDirectory: exportDir, connect: connect.icloud).run()

        let report = try await Verifier.run(.init(exportDirectory: exportDir, mboxDirectory: mboxDir,
                                                  bridge: connect.bridge, icloud: connect.icloud))
        XCTAssertTrue(report.exportComplete, VerifyFormatter.text(report))
        XCTAssertEqual(report.mboxComplete, true, VerifyFormatter.text(report))
        XCTAssertEqual(report.icloudComplete, true, VerifyFormatter.text(report))
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.allMailCount, 13)
        XCTAssertEqual(report.allMailAccountedFor, 13)
        XCTAssertEqual(report.distinctMessages, 12)
        let unfiled = report.targets.first { $0.folder == "Unfiled" }
        XCTAssertEqual(unfiled?.expected, 2)
        XCTAssertEqual(unfiled?.mbox, 2)
        XCTAssertEqual(unfiled?.icloud, 2)
        XCTAssertEqual(report.targets.first { $0.folder == "Empty" }?.expected, 0)
        XCTAssertTrue(report.targets.allSatisfy { $0.extraInICloud == 0 })
        XCTAssertFalse(report.sources.contains { $0.mailbox.hasPrefix("Labels/") && VerifyFormatter.countsSource($0) })
        XCTAssertTrue(VerifyFormatter.text(report).contains("Result: PASSED"))
    }

    func testMissingUploadsAndBrokenMboxAreReported() async throws {
        let (exportDir, mboxDir) = try await exportAndMbox()
        // Remove one Apple Mail folder; leave the iCloud account empty.
        let work = mboxDir.appendingPathComponent("Work.mbox/mbox")
        try Data().write(to: work)
        let connect = try connectors(icloudAccount: 4)

        let report = try await Verifier.run(.init(exportDirectory: exportDir, mboxDirectory: mboxDir, icloud: connect.icloud))
        XCTAssertTrue(report.exportComplete, "no Bridge connection: uses the scan counts")
        XCTAssertEqual(report.mboxComplete, false)
        XCTAssertEqual(report.icloudComplete, false)
        XCTAssertFalse(report.passed)
        XCTAssertEqual(report.targets.reduce(0) { $0 + $1.missingInICloud.count }, 13)
        let text = VerifyFormatter.text(report)
        XCTAssertTrue(text.contains("Result: FAILED"))
        XCTAssertTrue(text.contains("13 message(s) are not in iCloud"))
    }

    func testExportOnlyNeedsNoConnection() async throws {
        let (exportDir, _) = try await exportAndMbox()
        let report = try await Verifier.run(.init(exportDirectory: exportDir))
        XCTAssertTrue(report.passed)
        XCTAssertNil(report.mboxComplete)
        XCTAssertNil(report.icloudComplete)
    }
}

final class VerifyFormatterTests: XCTestCase {
    func testHTMLEscapesServerStrings() {
        let report = VerifyReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            sources: [.init(mailbox: "Folders/<script>alert(1)</script>", role: .export(target: ["x"]),
                            bridge: 2, scanned: 2, exported: 1, skipped: 0)],
            targets: [.init(folder: "a&b", expected: 1, mbox: nil, icloud: 0,
                            missingInICloud: [.init(hash: "ab", messageID: "<\"x\"@y>")], extraInICloud: 0)],
            skipped: [], distinctMessages: 1, allMailCount: nil, allMailAccountedFor: 0)
        let html = VerifyFormatter.html(report)
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("a&amp;b"))
        XCTAssertTrue(html.contains("&lt;&quot;x&quot;@y&gt;"))
        XCTAssertFalse(report.passed)
        XCTAssertEqual(VerifyFormatter.problems(report).count, 2)
    }

    func testTerminalTextDropsControlCharactersButKeepsLayout() {
        XCTAssertEqual(TerminalText.safe("a\u{1B}]0;pwned\u{07}b\u{9B}c\td\ne"), "a]0;pwnedbc\td\ne")
    }

    func testSkippedAndDeletedAllMailStillPass() {
        func report(bridge: Int, stored: Int, skipped: Int) -> VerifyReport {
            VerifyReport(generatedAt: Date(), sources: [], targets: [], skipped: [], distinctMessages: stored,
                         allMailCount: bridge, allMailAccountedFor: stored, allMailSkipped: skipped)
        }
        XCTAssertTrue(report(bridge: 13, stored: 12, skipped: 1).passed, "a message Bridge refuses is reported, not missing")
        XCTAssertTrue(report(bridge: 12, stored: 13, skipped: 0).passed, "mail deleted in Proton after the export")
        XCTAssertFalse(report(bridge: 13, stored: 12, skipped: 0).passed)
    }

    func testMboxCountsMergeSplitParts() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("slop-count-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        func write(_ path: String, _ n: Int) throws {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let one = "From slop-export@localhost Thu Jan  1 00:00:00 1970\nSubject: x\n\n>From body\n\n"
            try Data(String(repeating: one, count: n).utf8).write(to: url)
        }
        try write("Work.mbox/mbox", 2)
        try write("Work (2).mbox/mbox", 3)
        try write("Work.mbox/Projects.mbox/mbox", 1)
        let counts = Verifier.countMboxes(in: root)
        XCTAssertEqual(counts["work"], 5)
        XCTAssertEqual(counts["work/projects"], 1)
    }
}
