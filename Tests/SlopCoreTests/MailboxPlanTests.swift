import XCTest
@testable import SlopCore

final class MailboxPlanTests: XCTestCase {
    func role(_ path: String, selectable: Bool = true) -> MailboxRole {
        MailboxPlan.role(components: path.split(separator: "/").map(String.init), selectable: selectable)
    }

    func testSystemFoldersMapToICloudNames() {
        XCTAssertEqual(role("INBOX"), .export(target: ["INBOX"]))
        XCTAssertEqual(role("Sent"), .export(target: ["Sent Messages"]))
        XCTAssertEqual(role("Drafts"), .export(target: ["Drafts"]))
        XCTAssertEqual(role("Archive"), .export(target: ["Archive"]))
        XCTAssertEqual(role("Spam"), .export(target: ["Junk"]))
        XCTAssertEqual(role("Trash"), .export(target: ["Deleted Messages"]))
    }

    func testVirtualMailboxes() {
        XCTAssertEqual(role("All Mail"), .allMail)
        XCTAssertEqual(role("Starred"), .starred)
    }

    func testLabelsAreSkipped() {
        XCTAssertEqual(role("Labels", selectable: false), .container)
        XCTAssertEqual(role("Labels/Important"), .skippedLabel)
        XCTAssertEqual(role("Labels/Nested/Deeper"), .skippedLabel)
    }

    func testCustomFoldersKeepNesting() {
        XCTAssertEqual(role("Folders", selectable: false), .container)
        XCTAssertEqual(role("Folders/Work"), .export(target: ["Work"]))
        XCTAssertEqual(role("Folders/Work/Projects"), .export(target: ["Work", "Projects"]))
        XCTAssertEqual(role("Folders/Ünïcödé Ordner"), .export(target: ["Ünïcödé Ordner"]))
    }

    func testCustomFolderNamedLikeSystemFolderDoesNotMerge() {
        XCTAssertEqual(role("Folders/Archive"), .export(target: ["Proton Folders", "Archive"]))
        XCTAssertEqual(role("Folders/Junk/Old"), .export(target: ["Proton Folders", "Junk", "Old"]))
        XCTAssertEqual(role("Folders/inbox"), .export(target: ["Proton Folders", "inbox"]))
        XCTAssertEqual(role("Folders/Unfiled"), .export(target: ["Proton Folders", "Unfiled"]))
        XCTAssertEqual(role("Folders/archive"), .export(target: ["Proton Folders", "archive"]), "case-insensitive")
        XCTAssertEqual(role("Folders/Deleted Messages"), .export(target: ["Proton Folders", "Deleted Messages"]))
    }

    func testClashParentCannotItselfCollide() {
        let moved = role("Folders/Archive")
        let userFolder = role("Folders/Proton Folders/Archive")
        XCTAssertNotEqual(moved, userFolder)
        XCTAssertEqual(userFolder, .export(target: ["Proton Folders", "Proton Folders", "Archive"]))
    }

    func testUnknownTopLevelMailboxGetsClashProtection() {
        XCTAssertEqual(role("Junk"), .export(target: ["Proton Folders", "Junk"]))
    }

    func testUnknownTopLevelMailboxIsKept() {
        XCTAssertEqual(role("Something New"), .export(target: ["Something New"]))
    }
}
