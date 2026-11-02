import Foundation
import XCTest
@testable import SlopCore

final class MboxWriterTests: XCTestCase {
    func testEncodeEscapesFromLinesAndAddsStatus() {
        let raw = Data("Subject: x\r\nStatus: U\r\n\r\nFrom here\r\n>From quoted\r\nFromage\r\n".utf8)
        let out = String(decoding: MboxWriter.encode(raw: raw, flags: [#"\Seen"#, #"\Flagged"#, #"\Answered"#],
                                                     date: Date(timeIntervalSince1970: 1_594_744_200)), as: UTF8.self)
        XCTAssertEqual(out, """
            From slop-export@localhost Tue Jul 14 16:30:00 2020
            Status: RO
            X-Status: AF
            Subject: x

            >From here
            >>From quoted
            Fromage


            """)
    }

    func testDroppedStatusHeaderTakesItsFoldedLinesWithIt() {
        let raw = Data("Subject: a\r\nStatus: RO\r\n folded\r\n\tmore\r\nX-Other: b\r\n\r\nbody\r\n".utf8)
        let out = String(decoding: MboxWriter.encode(raw: raw, flags: [], date: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        XCTAssertFalse(out.contains("folded"))
        XCTAssertFalse(out.contains("more"))
        XCTAssertTrue(out.contains("Subject: a\nX-Other: b\n\nbody\n"))
    }

    func testAsctimePadsSingleDigitDay() {
        XCTAssertEqual(MboxWriter.asctime(Date(timeIntervalSince1970: 1_551_693_600)), "Mon Mar  4 10:00:00 2019")
    }

    func testCaseOnlyAndSanitisedCollisionsGetDistinctBundles() {
        var allocator = MboxWriter.BundleAllocator(root: URL(fileURLWithPath: "/out"))
        let a = allocator.bundle(for: ["Work"], part: 1)
        let b = allocator.bundle(for: ["work"], part: 1)
        let c = allocator.bundle(for: ["a/b"], part: 1)
        let d = allocator.bundle(for: ["a_b"], part: 1)
        let e = allocator.bundle(for: ["Work"], part: 2)
        let f = allocator.bundle(for: ["Work (2)"], part: 1)
        let child = allocator.bundle(for: ["work", "Sub"], part: 1)
        let paths = [a, b, c, d, e, f].map { $0.path.lowercased() }
        XCTAssertEqual(Set(paths).count, 6, "\(paths)")
        XCTAssertEqual(child.deletingLastPathComponent(), b, "children land in their own parent's bundle")
    }

    func testFolderNamesCannotEscape() {
        XCTAssertEqual(MboxWriter.safeComponent(".."), "_..")
        XCTAssertEqual(MboxWriter.safeComponent("a/b"), "a_b")
        XCTAssertEqual(MboxWriter.safeComponent(".hidden"), "_.hidden")
        XCTAssertEqual(MboxWriter.safeComponent(""), "_")
        let url = MboxWriter.bundleURL(for: ["..", "..", "etc"], part: 1, root: URL(fileURLWithPath: "/out"))
        XCTAssertTrue(url.standardizedFileURL.path.hasPrefix("/out/"), url.path)
    }
}

/// Phase 4 against the fixture: export, then build mbox bundles and read them back.
final class MboxIntegrationTests: XCTestCase {
    func testMboxBundlesFromFixtureExport() async throws {
        let fx = try FixtureServer.load("bridge")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slop-mbox-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let exporter = try Exporter(directory: dir.appendingPathComponent("export"), settings: fx.bridgeSettings, password: fx.password)
        _ = try await exporter.run()

        let out = dir.appendingPathComponent("mbox")
        let result = try MboxWriter(store: exporter.store).write(state: exporter.state, to: out)
        XCTAssertEqual(result.mailboxes["INBOX"], 1 + 1)
        XCTAssertEqual(result.mailboxes["Unfiled"], 2)
        XCTAssertEqual(result.mailboxes["Work/Projects"], 1)
        XCTAssertNil(result.mailboxes.keys.first { $0.hasPrefix("Labels") })
        // m01's bytes are in INBOX and in the Ünïcödé folder: one copy each.
        XCTAssertEqual(result.messages, 13)

        func mbox(_ path: String) throws -> String {
            String(decoding: try Data(contentsOf: out.appendingPathComponent(path).appendingPathComponent("mbox")), as: UTF8.self)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("Work.mbox/Projects.mbox/mbox").path))
        let sent = try mbox("Sent Messages.mbox")
        XCTAssertTrue(sent.contains("X-Status: A\n"))
        XCTAssertTrue(sent.hasPrefix("From slop-export@localhost Sat Jan  2 14:15:00 2021\n"), "INTERNALDATE in UTC")
        let unicode = try mbox("Ünïcödé Ordner.mbox")
        XCTAssertTrue(unicode.contains("\n>From the start of a line\n"))
        XCTAssertTrue(unicode.contains("\n>>From already quoted\n"))
        let inbox = try mbox("INBOX.mbox")
        XCTAssertEqual(inbox.components(separatedBy: "\nFrom slop-export@localhost ").count + (inbox.hasPrefix("From ") ? 0 : -1), 2)
        XCTAssertTrue(inbox.contains("X-Status: F\n"), "starred survives as flagged")
        XCTAssertFalse(inbox.contains("\r"), "LF line endings")

        // Splitting.
        var options = MboxWriter.Options()
        options.maxMboxBytes = 1
        let split = try MboxWriter(store: exporter.store, options: options).write(state: exporter.state, to: out)
        XCTAssertEqual(split.messages, 13)
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.appendingPathComponent("INBOX (2).mbox/mbox").path))
    }
}
