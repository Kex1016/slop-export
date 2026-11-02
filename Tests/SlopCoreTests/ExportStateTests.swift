import XCTest
@testable import SlopCore

final class ExportStateTests: XCTestCase {
    private func loc(_ mailbox: String, _ validity: UInt32, _ uid: UInt32, flags: [String] = []) -> MessageLocation {
        MessageLocation(mailbox: mailbox, uidValidity: validity, uid: uid, flags: flags, internalDate: nil)
    }

    func testUIDValidityChangeForgetsOldLocations() {
        var state = ExportState()
        state.apply(.mailbox(MailboxState(path: "INBOX", role: .export(target: ["INBOX"]), uidValidity: 1, count: 1, complete: true)))
        state.apply(.location(hash: "a", size: 1, messageID: "<a>", location: loc("INBOX", 1, 7)))
        XCTAssertTrue(state.hasSeen(mailbox: "INBOX", uidValidity: 1, uid: 7))

        state.apply(.mailbox(MailboxState(path: "INBOX", role: .export(target: ["INBOX"]), uidValidity: 2, count: 1, complete: false)))
        XCTAssertFalse(state.hasSeen(mailbox: "INBOX", uidValidity: 1, uid: 7))
        XCTAssertNil(state.messages["a"])
        XCTAssertEqual(state.hashes(forMessageID: "<a>"), [])
    }

    func testSkippedCountsAsHandledAndIsForgottenOnUIDValidityChange() {
        var state = ExportState()
        state.apply(.mailbox(MailboxState(path: "INBOX", role: .export(target: ["INBOX"]), uidValidity: 1, count: 1, complete: false)))
        state.apply(.skipped(mailbox: "INBOX", uidValidity: 1, uid: 3, reason: "failed to build message"))
        XCTAssertTrue(state.hasSeen(mailbox: "INBOX", uidValidity: 1, uid: 3))
        XCTAssertEqual(state.seenCount(mailbox: "INBOX", uidValidity: 1), 1)
        XCTAssertEqual(state.skipped.count, 1)
        state.apply(.mailbox(MailboxState(path: "INBOX", role: .export(target: ["INBOX"]), uidValidity: 2, count: 1, complete: false)))
        XCTAssertTrue(state.skipped.isEmpty)
    }

    func testSameUIDTwiceIsRecordedOnce() {
        var state = ExportState()
        state.apply(.location(hash: "a", size: 1, messageID: nil, location: loc("INBOX", 1, 7)))
        state.apply(.location(hash: "a", size: 1, messageID: nil, location: loc("INBOX", 1, 7)))
        XCTAssertEqual(state.messages["a"]?.locations.count, 1)
    }

    func testStarredAddsFlaggedAndUnfiledFallsBackToAllMailFlags() {
        var state = ExportState()
        state.apply(.mailbox(MailboxState(path: "Archive", role: .export(target: ["Archive"]), uidValidity: 1, count: 1, complete: true)))
        state.apply(.mailbox(MailboxState(path: "Starred", role: .starred, uidValidity: 1, count: 1, complete: true)))
        state.apply(.mailbox(MailboxState(path: "All Mail", role: .allMail, uidValidity: 1, count: 2, complete: true)))
        state.apply(.location(hash: "a", size: 1, messageID: "<a>", location: loc("Archive", 1, 1, flags: [#"\Seen"#])))
        state.apply(.location(hash: "a", size: 1, messageID: "<a>", location: loc("Starred", 1, 1, flags: [#"\Seen"#])))
        state.apply(.location(hash: "b", size: 1, messageID: "<b>", location: loc("All Mail", 1, 2, flags: [#"\Answered"#, #"\Recent"#])))

        let a = state.messages["a"]!
        XCTAssertEqual(state.targets(for: a), [["Archive"]])
        XCTAssertEqual(state.flags(for: a, in: ["Archive"]), [#"\Flagged"#, #"\Seen"#])

        let b = state.messages["b"]!
        XCTAssertEqual(state.targets(for: b), [["Unfiled"]])
        XCTAssertEqual(state.flags(for: b, in: ["Unfiled"]), [#"\Answered"#], "\\Recent is never carried over")
    }

    func testMessageIDParsing() {
        let header = Array("Subject: x\r\nMessage-Id:\r\n  <folded@example.test>\r\nTo: y\r\n\r\nbody".utf8)
        XCTAssertEqual(Headers.messageID(in: header), "<folded@example.test>")
        XCTAssertNil(Headers.messageID(in: Array("Subject: none\r\n\r\n".utf8)))
    }
}
