import Foundation

/// Bridge connection settings. Everything but the password, which comes from a `SecretStore`.
public struct BridgeSettings: Sendable, Codable, Hashable {
    public var host: String
    public var port: Int
    public var user: String
    public var tls: TLSMode
    /// Path to the certificate exported from Bridge (Settings > Advanced > Export TLS certificates).
    public var certificatePath: String

    public init(host: String = "127.0.0.1", port: Int = 1143, user: String, tls: TLSMode = .startTLS, certificatePath: String) {
        self.host = host
        self.port = port
        self.user = user
        self.tls = tls
        self.certificatePath = certificatePath
    }

    public func endpoint() throws -> ServerEndpoint {
        let pin = try PinnedCertificate(contentsOf: URL(fileURLWithPath: certificatePath))
        return ServerEndpoint(host: host, port: port, tls: tls, trust: .pinned(pin))
    }
}

public struct ProbedMailbox: Sendable, Codable, Hashable, Identifiable {
    public var id: String { path }
    public var path: String
    public var role: MailboxRole
    public var attributes: [String]
    public var messages: Int?
    public var size: Int?
    public var uidValidity: UInt32?
}

public struct ProbeReport: Sendable, Codable {
    public var server: [String: String]
    public var capabilities: [String]
    public var mailboxes: [ProbedMailbox]

    public var exportedMessageCount: Int {
        mailboxes.filter { if case .export = $0.role { return true } else { return false } }.compactMap(\.messages).reduce(0, +)
    }
    public var allMailCount: Int? { mailboxes.first { $0.role == .allMail }?.messages }
}

/// Phase 1: list every mailbox with counts and sizes. Downloads no message content.
public enum Probe {
    public static func run(settings: BridgeSettings, password: String,
                           progress: (@Sendable (String) -> Void)? = nil) async throws -> ProbeReport {
        try await run(endpoint: settings.endpoint(), user: settings.user, password: password, progress: progress)
    }

    public static func run(endpoint: ServerEndpoint, user: String, password: String,
                           progress: (@Sendable (String) -> Void)? = nil) async throws -> ProbeReport {
        let client = try await IMAPClient.connect(to: endpoint)
        do {
            let report = try await run(client: client, user: user, password: password, progress: progress)
            await client.logout()
            await client.close()
            return report
        } catch {
            await client.close()
            throw error
        }
    }

    static func run(client: IMAPClient, user: String, password: String,
                    progress: (@Sendable (String) -> Void)?) async throws -> ProbeReport {
        try await client.login(user: user, password: password)
        let server = try await client.serverID()
        let statusSize = await client.hasCapability("STATUS=SIZE")
        var out: [ProbedMailbox] = []
        let listed = try await client.list().sorted { $0.displayPath < $1.displayPath }
        for mailbox in listed {
            let role = MailboxPlan.role(for: mailbox)
            var probed = ProbedMailbox(path: mailbox.displayPath, role: role, attributes: mailbox.attributes)
            // Labels are listed (acceptance criterion 1) but never opened (D-001).
            if mailbox.isSelectable, role != .skippedLabel, role != .container {
                progress?("Counting \(mailbox.displayPath)")
                let counts = try await client.status(mailbox, size: statusSize)
                probed.messages = counts.messages
                probed.uidValidity = counts.uidValidity
                probed.size = counts.size
                if probed.size == nil, (counts.messages ?? 0) > 0 {
                    // No STATUS=SIZE (Bridge): sum RFC822.SIZE. Metadata only, no bodies.
                    _ = try await client.examine(mailbox)
                    probed.size = try await client.fetchAllMetadata().compactMap(\.size).reduce(0, +)
                } else if probed.size == nil {
                    probed.size = 0
                }
            }
            out.append(probed)
        }
        return ProbeReport(server: server, capabilities: await client.capabilities.sorted(), mailboxes: out)
    }
}
