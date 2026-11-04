import XCTest
@testable import SlopCore

/// Runs against the Dovecot "Bridge" fixture. Skipped when it is not running.
final class ProbeIntegrationTests: XCTestCase {
    func testProbeListsEveryMailboxWithCounts() async throws {
        let fx = try FixtureServer.load("bridge")
        let report = try await Probe.run(settings: fx.bridgeSettings, password: fx.password)
        let byPath = Dictionary(uniqueKeysWithValues: report.mailboxes.map { ($0.path, $0) })

        XCTAssertEqual(byPath["All Mail"]?.messages, 13)
        XCTAssertEqual(byPath["INBOX"]?.messages, 2)
        XCTAssertEqual(byPath["Folders/Ünïcödé Ordner"]?.messages, 2, "non-ASCII folder names decode")
        XCTAssertEqual(byPath["Folders/Work/Projects"]?.role, .export(target: ["Work", "Projects"]))
        XCTAssertEqual(byPath["Labels/Important"]?.role, .skippedLabel)
        XCTAssertNil(byPath["Labels/Important"]?.messages, "labels are listed but never opened (D-001)")
        XCTAssertEqual(byPath["Starred"]?.role, .starred)
        XCTAssertEqual(byPath["Folders"]?.role, .container)
        XCTAssertEqual(report.exportedMessageCount, 11)
        // Bridge has no STATUS=SIZE, so sizes come from RFC822.SIZE and must still be filled in.
        XCTAssertFalse(report.capabilities.contains("STATUS=SIZE"))
        XCTAssertGreaterThan(byPath["Archive"]?.size ?? 0, 3_000_000)
    }

    func testProbeDoesNotMarkAnythingRead() async throws {
        let fx = try FixtureServer.load("bridge")
        _ = try await Probe.run(settings: fx.bridgeSettings, password: fx.password)
        let client = try await IMAPClient.connect(to: fx.bridgeSettings.endpoint())
        try await client.login(user: fx.user, password: fx.password)
        let inbox = try await client.list().first { $0.displayPath == "INBOX" }!
        _ = try await client.examine(inbox)
        let unread = try await client.fetchAllMetadata().filter { !$0.flags.contains("\\Seen") }
        XCTAssertEqual(unread.count, 1)
        await client.close()
    }

    func testWrongCertificateIsRejected() async throws {
        let bridge = try FixtureServer.load("bridge")
        let icloud = try FixtureServer.load("icloud")
        var settings = bridge.bridgeSettings
        settings.certificatePath = icloud.cert
        do {
            _ = try await Probe.run(settings: settings, password: bridge.password)
            XCTFail("connected with a certificate that was not pinned")
        } catch let error as IMAPError {
            guard case .tls = error else { return XCTFail("expected a TLS error, got \(error)") }
        }
    }

    func testStartTLSAgainstImplicitTLSPortFailsWithAClearError() async throws {
        let icloud = try FixtureServer.load("icloud")
        let pin = try PinnedCertificate(contentsOf: URL(fileURLWithPath: icloud.cert))
        let endpoint = ServerEndpoint(host: icloud.host, port: icloud.port, tls: .startTLS, trust: .pinned(pin))
        do {
            _ = try await IMAPClient.connect(to: endpoint, greetingTimeout: .seconds(2))
            XCTFail("connected with the wrong security mode")
        } catch let error as IMAPError {
            guard case .noGreeting = error else { return XCTFail("expected noGreeting, got \(error)") }
        }
    }

    func testImplicitTLSConnects() async throws {
        let icloud = try FixtureServer.load("icloud")
        let pin = try PinnedCertificate(contentsOf: URL(fileURLWithPath: icloud.cert))
        let client = try await IMAPClient.connect(to: ServerEndpoint(host: icloud.host, port: icloud.port, tls: .implicit,
                                                                     trust: .pinned(pin)))
        try await client.login(user: icloud.user, password: icloud.password)
        let names = try await client.list().map(\.displayPath)
        XCTAssertTrue(names.contains("Sent Messages"))
        await client.close()
    }

    func testWrongPasswordFailsCleanly() async throws {
        let fx = try FixtureServer.load("bridge")
        do {
            _ = try await Probe.run(settings: fx.bridgeSettings, password: "not-the-password")
            XCTFail("logged in with a wrong password")
        } catch let error as IMAPError {
            guard case .loginRejected = error else { return XCTFail("\(error)") }
            XCTAssertTrue(error.description.contains("Mailbox details"))
        }
    }

    func testPastedWhitespaceAroundCredentialsIsIgnored() async throws {
        let fx = try FixtureServer.load("bridge")
        var settings = fx.bridgeSettings
        settings.user = " \(fx.user)\n"
        let report = try await Probe.run(settings: settings, password: fx.password + " \r\n")
        XCTAssertEqual(report.allMailCount, 13)
    }

    func testInvisibleCharactersAroundCredentialsAreIgnored() async throws {
        let fx = try FixtureServer.load("bridge")
        var settings = fx.bridgeSettings
        settings.user = "\u{FEFF}\(fx.user)\u{200B}"
        let report = try await Probe.run(settings: settings, password: "\u{2060}" + fx.password + "\u{200B}")
        XCTAssertEqual(report.allMailCount, 13)
    }

    /// Dovecot answers a wrong password with NO [AUTHENTICATIONFAILED], as iCloud does.
    func testWrongICloudPasswordFailsCleanly() async throws {
        let fx = try FixtureServer.load("icloud")
        let endpoint = ServerEndpoint(host: fx.host, port: fx.port, tls: .implicit,
                                      trust: .pinned(try PinnedCertificate(contentsOf: URL(fileURLWithPath: fx.cert))))
        do {
            let client = try await IMAPClient.connectAndLogin(to: endpoint, user: fx.user, password: "not-the-password")
            await client.close()
            XCTFail("logged in with a wrong password")
        } catch let error as IMAPError {
            guard case .loginRejected(let text) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(text.contains("AUTHENTICATIONFAILED"), text)
            XCTAssertTrue(error.description.contains("app-specific password"))
        }
    }
}
