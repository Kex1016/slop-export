import Foundation
import SlopCore
import SlopLinux
import XCTest

struct FixtureMissing: Error, CustomStringConvertible {
    var description: String { "SLOP_REQUIRE_FIXTURES=1 but SLOP_FIXTURE_DIR is not set" }
}

/// Connection details written by `Fixtures/slopfixture.py up --dir $SLOP_FIXTURE_DIR`.
struct FixtureServer: Decodable {
    var host: String
    var port: Int
    var user: String
    var password: String
    var cert: String

    static func load(_ kind: String) throws -> FixtureServer {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["SLOP_FIXTURE_DIR"], !dir.isEmpty else {
            if env["SLOP_REQUIRE_FIXTURES"] == "1" { throw FixtureMissing() }
            throw XCTSkip("SLOP_FIXTURE_DIR not set; start the fixture servers with Fixtures/slopfixture.py")
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("\(kind).json"))
        return try JSONDecoder().decode(FixtureServer.self, from: data)
    }
}

final class SessionTests: XCTestCase {
    var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("slop-linux-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private var settingsFile: SettingsFile { SettingsFile(url: dir.appendingPathComponent("config/settings.json")) }

    @MainActor
    func testSettingsPersistButPasswordsStayInTheVault() async throws {
        let fx = try? FixtureServer.load("bridge")
        let vault = MemoryVault()
        let session = Session(settingsFile: settingsFile, vault: vault)
        session.host = "127.0.0.2"
        session.port = 2143
        session.user = "  someone@example.test\u{200B}\n"
        session.icloudUser = "me@icloud.example.test"
        XCTAssertTrue(session.savePassword(" bridge-secret-123\n", .bridge))
        XCTAssertTrue(session.savePassword("abcd-efgh-ijkl-mnop", .icloud))
        if let fx { session.importCertificate(at: fx.cert) }

        // Trimmed for the vault account and value (D-015).
        XCTAssertEqual(try vault.password(.bridge, account: "someone@example.test"), "bridge-secret-123")
        XCTAssertTrue(session.hasSavedPassword)
        XCTAssertTrue(session.hasSavedICloudPassword)

        let text = try String(contentsOf: settingsFile.url, encoding: .utf8)
        XCTAssertFalse(text.contains("bridge-secret-123"))
        XCTAssertFalse(text.contains("abcd-efgh"))
        let attributes = try FileManager.default.attributesOfItem(atPath: settingsFile.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let again = Session(settingsFile: settingsFile, vault: vault)
        XCTAssertEqual(again.host, "127.0.0.2")
        XCTAssertEqual(again.port, 2143)
        XCTAssertEqual(again.bridgeAccount, "someone@example.test")
        XCTAssertEqual(again.icloudUser, "me@icloud.example.test")
        XCTAssertTrue(again.hasSavedPassword)
        if fx != nil {
            XCTAssertEqual(again.certificateName, "cert.pem")
            XCTAssertNotNil(again.certificateFingerprint)
        }
    }

    @MainActor
    func testOlderOrDamagedSettingsFallBackToDefaults() async throws {
        try FileManager.default.createDirectory(at: settingsFile.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"user":"old@example.test"}"#.utf8).write(to: settingsFile.url)
        let session = Session(settingsFile: settingsFile, vault: MemoryVault())
        XCTAssertEqual(session.user, "old@example.test")
        XCTAssertEqual(session.host, "127.0.0.1")
        XCTAssertEqual(session.port, 1143)

        try Data("not json".utf8).write(to: settingsFile.url)
        XCTAssertEqual(Session(settingsFile: settingsFile, vault: MemoryVault()).settings, AppSettings())
    }

    @MainActor
    func testAFileThatIsNotACertificateIsRefused() async throws {
        let bogus = dir.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: bogus)
        let session = Session(settingsFile: nil, vault: MemoryVault())
        session.importCertificate(at: bogus.path)
        XCTAssertFalse(session.hasCertificate)
        XCTAssertNotNil(session.errors[.connect])
    }

    @MainActor
    func testEnvironmentPasswordsComeFirstButWritesGoToTheVault() async throws {
        let base = MemoryVault()
        let vault = EnvironmentFirstVault(base, environment: ["SLOP_BRIDGE_PASSWORD": "from-env"])
        try base.setPassword("from-vault", .bridge, account: "a")
        XCTAssertEqual(try vault.password(.bridge, account: "a"), "from-env")
        XCTAssertNil(try vault.password(.icloud, account: "a"))
        try vault.setPassword("new", .icloud, account: "a")
        XCTAssertEqual(try base.password(.icloud, account: "a"), "new")
    }

    @MainActor
    func testConnectWithoutASavedPasswordSaysWhatToDo() async throws {
        let fx = try FixtureServer.load("bridge")
        let session = Session(settingsFile: nil, vault: MemoryVault())
        session.port = fx.port
        session.user = fx.user
        session.importCertificate(at: fx.cert)
        await session.connectAndScan()
        XCTAssertNil(session.report)
        XCTAssertEqual(session.step, .connect)
        XCTAssertTrue(session.errors[.connect]?.contains("Bridge password") ?? false, session.errors[.connect] ?? "")
    }

    /// The whole flow the window drives, against the fixture Bridge and iCloud servers.
    @MainActor
    func testConnectScanExportBuildUploadVerify() async throws {
        let bridge = try FixtureServer.load("bridge")
        let icloud = try FixtureServer.load("icloud")
        let icloudPin = try PinnedCertificate(contentsOf: URL(fileURLWithPath: icloud.cert))
        let icloudUser = icloud.user.replacingOccurrences(of: "@", with: "-6@")

        let session = Session(settingsFile: settingsFile, vault: MemoryVault(), icloudEndpoint: { _ in
            ServerEndpoint(host: icloud.host, port: icloud.port, tls: .implicit, trust: .pinned(icloudPin))
        })
        var changes = 0
        session.onChange = { changes += 1 }

        // Connect and scan.
        session.host = bridge.host
        session.port = bridge.port
        session.user = bridge.user
        session.importCertificate(at: bridge.cert)
        XCTAssertTrue(session.savePassword(bridge.password, .bridge))
        XCTAssertTrue(session.canConnect)
        await session.connectAndScan()
        XCTAssertNil(session.errors[.connect])
        XCTAssertEqual(session.step, .scan)
        let report = try XCTUnwrap(session.report)
        XCTAssertEqual(report.allMailCount, 13)
        XCTAssertTrue(report.mailboxes.contains { $0.path.hasPrefix("Labels/") && $0.role == .skippedLabel })

        // Export into a chosen folder.
        let folder = dir.appendingPathComponent("My Export").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        session.chooseExportFolder(folder)
        XCTAssertFalse(session.hasExistingExport)
        session.startExport()
        XCTAssertTrue(session.isExporting)
        await session.waitForExport()
        XCTAssertNil(session.errors[.export])
        XCTAssertEqual(session.exportSummary?.distinctMessages, 12)
        XCTAssertEqual(session.exportSummary?.unfiled, 2)
        XCTAssertTrue(session.hasExistingExport)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/Proton Export/journal.jsonl"))

        // Apple Mail mailboxes, same folder name as the macOS app.
        session.buildMailboxes()
        await session.waitForMailboxes()
        XCTAssertNil(session.errors[.export])
        XCTAssertEqual(session.mboxResult?.messages, 13)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder + "/Apple Mail Import"))

        // Upload: nothing until a dry run; the dry run writes nothing.
        session.icloudUser = icloudUser
        XCTAssertTrue(session.savePassword(icloud.password, .icloud))
        XCTAssertFalse(session.canUpload)
        session.startUpload()
        XCTAssertFalse(session.isUploading, "upload must not start without a dry run")
        session.planUpload()
        await session.waitForUpload()
        XCTAssertNil(session.errors[.upload])
        XCTAssertEqual(session.uploadPlan?.messagesToUpload, 13)
        XCTAssertTrue(session.canUpload)
        session.startUpload()
        await session.waitForUpload()
        XCTAssertNil(session.errors[.upload])
        XCTAssertEqual(session.uploadSummary?.uploaded, 13)
        XCTAssertNil(session.uploadPlan, "a spent plan cannot start another upload")

        // Verify against Bridge, the mailboxes and iCloud.
        XCTAssertTrue(session.canVerifyBridge)
        XCTAssertTrue(session.canVerifyICloud)
        session.runVerify()
        await session.waitForVerify()
        XCTAssertNil(session.errors[.verify])
        let verify = try XCTUnwrap(session.verifyReport)
        XCTAssertTrue(verify.passed, VerifyFormatter.text(verify))
        XCTAssertEqual(verify.targets.first { $0.folder == "Unfiled" }?.icloud, 2)

        let html = dir.appendingPathComponent("report.html").path
        XCTAssertTrue(session.saveReport(.html, to: html))
        XCTAssertTrue(try String(contentsOfFile: html, encoding: .utf8).contains("Passed"))

        // Settings remember where things are, for the next launch.
        let reopened = Session(settingsFile: settingsFile, vault: MemoryVault())
        XCTAssertEqual(reopened.exportFolder, folder)
        XCTAssertTrue(reopened.hasExistingExport)
        XCTAssertGreaterThan(changes, 10)
    }

    @MainActor
    func testChangingTheAppleIDDropsTheDryRun() async throws {
        let session = Session(settingsFile: nil, vault: MemoryVault())
        session.icloudUser = "a@icloud.example.test"
        XCTAssertNil(session.uploadPlan)
        XCTAssertFalse(session.canUpload)
        XCTAssertFalse(session.canPlanUpload, "no export folder yet")
    }

    /// Round trip through the real Secret Service. Runs only where a keyring is available
    /// (CI starts gnome-keyring in a private D-Bus session and sets SLOP_TEST_KEYRING=1).
    @MainActor
    func testSecretServiceRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["SLOP_TEST_KEYRING"] == "1" else {
            throw XCTSkip("set SLOP_TEST_KEYRING=1 inside a D-Bus session with an unlocked keyring")
        }
        let vault = SecretServiceVault()
        let account = "test-\(UUID().uuidString)@example.test"
        XCTAssertNil(try vault.password(.bridge, account: account))
        try vault.setPassword("first", .bridge, account: account)
        try vault.setPassword("second", .bridge, account: account)
        XCTAssertEqual(try vault.password(.bridge, account: account), "second")
        XCTAssertNil(try vault.password(.icloud, account: account), "kinds are separate items")
        try vault.deletePassword(.bridge, account: account)
        XCTAssertNil(try vault.password(.bridge, account: account))
    }
}
