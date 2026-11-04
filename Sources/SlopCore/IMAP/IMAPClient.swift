import Foundation
import NIO
import NIOConcurrencyHelpers
import NIOIMAP
import NIOSSL

/// How to secure the connection.
public enum TLSMode: String, Sendable, Codable {
    /// Plain connect, then STARTTLS before anything else (Proton Mail Bridge).
    case startTLS = "starttls"
    /// TLS from the first byte (iCloud on port 993).
    case implicit = "tls"
}

/// Which certificate the server must present.
public enum TrustPolicy: Sendable {
    /// The operating system's trust store and hostname check (iCloud).
    case system
    /// Exactly this certificate and no other (Bridge's self-signed cert, D-004).
    case pinned(PinnedCertificate)
}

public struct ServerEndpoint: Sendable {
    public var host: String
    public var port: Int
    public var tls: TLSMode
    public var trust: TrustPolicy

    public init(host: String, port: Int, tls: TLSMode, trust: TrustPolicy) {
        self.host = host
        self.port = port
        self.tls = tls
        self.trust = trust
    }
}

public enum IMAPError: Error, CustomStringConvertible, Sendable {
    case connectionClosed
    case timeout
    case noGreeting
    case bye(String)
    case tls(String)
    case commandFailed(command: String, status: String, text: String)
    /// LOGIN was refused: wrong user name or password, as far as the server is concerned.
    case loginRejected(String)
    case unexpected(String)

    public var description: String {
        switch self {
        case .connectionClosed: return "The server closed the connection."
        case .timeout: return "The server stopped sending data and did not answer in time."
        case .noGreeting:
            return "The server did not start an IMAP session. Check the port and the connection security setting "
                + "(Bridge's default is STARTTLS on 1143; SSL needs the tls setting)."
        case .bye(let text): return "The server ended the session: \(text)"
        case .tls(let text): return "Secure connection failed: \(text)"
        case .commandFailed(let command, let status, let text): return "\(command) failed (\(status)): \(text)"
        case .loginRejected(let text):
            return "The server did not accept the user name and password (it said: \(text)). "
                + "For Bridge, use the user name and password Bridge shows for this account (Mailbox details), "
                + "not your Proton login. If Bridge shows a separate entry per address (split mode), use that address's details."
        case .unexpected(let text): return "Unexpected IMAP behaviour: \(text)"
        }
    }
}

/// A mailbox as LIST returns it.
public struct ListedMailbox: Sendable, Hashable {
    /// Raw (modified UTF-7) name, used to talk to the server.
    public var rawName: [UInt8]
    /// Human-readable path components, decoded.
    public var components: [String]
    public var separator: Character?
    public var attributes: [String]

    public var displayPath: String { components.joined(separator: "/") }
    public var isSelectable: Bool {
        !attributes.contains { $0.caseInsensitiveCompare(#"\Noselect"#) == .orderedSame
            || $0.caseInsensitiveCompare(#"\NonExistent"#) == .orderedSame }
    }
    var mailboxName: MailboxName { MailboxName(rawName) }
}

public struct SelectedMailbox: Sendable {
    public var exists: Int
    public var uidValidity: UInt32?
    public var uidNext: UInt32?
}

public struct MailboxCounts: Sendable {
    public var messages: Int?
    public var uidValidity: UInt32?
    public var size: Int?
}

/// A small async IMAP client over swift-nio-imap. One command at a time, no pipelining:
/// Bridge is slow and fragile under load, and simple ordering makes resume logic easy.
public actor IMAPClient {
    private let channel: Channel
    private let group: EventLoopGroup
    private let ownsGroup: Bool
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []
    /// How long the server may stay silent during a command.
    public var commandTimeout: TimeAmount = .seconds(120)

    private init(channel: Channel, group: EventLoopGroup, ownsGroup: Bool) {
        self.channel = channel
        self.group = group
        self.ownsGroup = ownsGroup
    }

    // MARK: Connecting

    public static func connect(to endpoint: ServerEndpoint, connectTimeout: TimeAmount = .seconds(20),
                               greetingTimeout: TimeAmount = .seconds(30)) async throws -> IMAPClient {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        do {
            let sslContext = try makeSSLContext(trust: endpoint.trust)
            let host = endpoint.host
            let trust = endpoint.trust
            let channel: Channel
            switch endpoint.tls {
            case .implicit:
                channel = try await ClientBootstrap(group: group)
                    .connectTimeout(connectTimeout)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            let tls = try makeTLSHandler(context: sslContext, host: host, trust: trust)
                            try channel.pipeline.syncOperations.addHandlers([tls, IMAPClientHandler(), ResponseCollector()])
                        }
                    }
                    .connect(host: endpoint.host, port: endpoint.port)
                    .get()
                try await withDeadline(greetingTimeout, on: channel) {
                    try await awaitGreeting(on: channel)
                }
            case .startTLS:
                let ready = group.next().makePromise(of: Void.self)
                channel = try await ClientBootstrap(group: group)
                    .connectTimeout(connectTimeout)
                    .channelInitializer { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(StartTLSNegotiator(promise: ready), name: "starttls")
                        }
                    }
                    .connect(host: endpoint.host, port: endpoint.port)
                    .get()
                try await withDeadline(greetingTimeout, on: channel) {
                    try await ready.futureResult.get()
                }
                // Swap the plaintext negotiator for TLS and the IMAP codec in one event-loop turn,
                // so no byte can slip in between.
                try await channel.eventLoop.submit {
                    let sync = channel.pipeline.syncOperations
                    let negotiator = try sync.handler(type: StartTLSNegotiator.self)
                    sync.removeHandler(negotiator, promise: nil)
                    let tls = try makeTLSHandler(context: sslContext, host: host, trust: trust)
                    try sync.addHandlers([tls, IMAPClientHandler(), ResponseCollector()])
                }.get()
            }
            let client = IMAPClient(channel: channel, group: group, ownsGroup: true)
            do {
                try await client.refreshCapabilities()
            } catch {
                await client.close()
                throw error
            }
            return client
        } catch {
            try? await group.shutdownGracefully()
            throw Self.explain(error, trust: endpoint.trust)
        }
    }

    private static func awaitGreeting(on channel: Channel) async throws {
        let promise = channel.eventLoop.makePromise(of: UntaggedStatus.self)
        try await channel.writeAndFlush(CollectorRequest.greeting(promise)).get()
        switch try await promise.futureResult.get() {
        case .ok, .preauth: break
        case .bye(let text), .no(let text), .bad(let text): throw IMAPError.bye(text.text)
        }
    }

    /// Closes the channel if `body` has not finished in time, and reports that as `.noGreeting`.
    /// Covers the classic mistake of STARTTLS against an implicit-TLS port (or the reverse),
    /// where both sides wait for the other forever.
    private static func withDeadline<T: Sendable>(_ timeout: TimeAmount, on channel: Channel,
                                                  _ body: () async throws -> T) async throws -> T {
        let fired = NIOLockedValueBox(false)
        let task = channel.eventLoop.scheduleTask(in: timeout) {
            fired.withLockedValue { $0 = true }
            channel.close(promise: nil)
        }
        defer { task.cancel() }
        do {
            return try await body()
        } catch {
            if fired.withLockedValue({ $0 }) { throw IMAPError.noGreeting }
            throw error
        }
    }

    /// Turns TLS errors into something a person can act on. Only a failed certificate check is
    /// blamed on the certificate; anything else is reported as it is.
    static func explain(_ error: Error, trust: TrustPolicy) -> Error {
        guard error is NIOSSLError || error is BoringSSLError else { return error }
        let text = String(describing: error)
        guard text.contains("CERTIFICATE_VERIFY_FAILED") else {
            return IMAPError.tls("the TLS handshake failed (\(text)). Check the port and connection security setting.")
        }
        switch trust {
        case .pinned(let pin):
            return IMAPError.tls("the server did not present the certificate you chose (SHA-256 \(pin.fingerprint)). "
                + "Export the certificate again from Bridge and choose the new file.")
        case .system:
            return IMAPError.tls("the server's certificate is not trusted by macOS (\(text)).")
        }
    }

    /// Connects and logs in, closing the connection again if login fails.
    public static func connectAndLogin(to endpoint: ServerEndpoint, user: String, password: String) async throws -> IMAPClient {
        let client = try await connect(to: endpoint)
        do {
            try await client.login(user: user, password: password)
            return client
        } catch {
            await client.close()
            throw error
        }
    }

    public func close() async {
        _ = try? await channel.close()
        if ownsGroup { try? await group.shutdownGracefully() }
    }

    // MARK: Commands

    private func nextTag() -> String {
        tagCounter += 1
        return String(format: "S%05d", tagCounter)
    }

    @discardableResult
    private func run(_ command: Command, describe: String? = nil) async throws -> CommandResult {
        let tag = nextTag()
        return try await send(tag: tag, parts: [.tagged(TaggedCommand(tag: tag, command: command))],
                              describe: describe ?? String(describing: command).prefix(40).description)
    }

    private func send(tag: String, parts: [CommandStreamPart], describe: String,
                      timeout: TimeAmount? = nil) async throws -> CommandResult {
        let promise = channel.eventLoop.makePromise(of: CommandResult.self)
        channel.writeAndFlush(CollectorRequest.command(tag: tag, parts: parts, timeout: timeout ?? commandTimeout, promise: promise),
                              promise: nil)
        let result = try await promise.futureResult.get()
        switch result.state {
        case .ok: return result
        case .no(let text): throw IMAPError.commandFailed(command: describe, status: "NO", text: text.text)
        case .bad(let text): throw IMAPError.commandFailed(command: describe, status: "BAD", text: text.text)
        }
    }

    public func refreshCapabilities() async throws {
        let result = try await run(.capability, describe: "CAPABILITY")
        for case .capabilityData(let caps) in result.untagged {
            capabilities = Set(caps.map { $0.name.uppercased() + ($0.value.map { "=" + $0.uppercased() } ?? "") })
        }
    }

    public func hasCapability(_ name: String) -> Bool { capabilities.contains(name.uppercased()) }

    /// LOGIN. The password goes over TLS only; this client never connects without it.
    public func login(user: String, password: String) async throws {
        // Copying from Bridge or a password manager can bring a stray space or line break along.
        // Neither Bridge nor iCloud app-specific credentials ever start or end with whitespace.
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = password.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try await run(.login(username: user, password: password), describe: "LOGIN")
        } catch IMAPError.commandFailed(_, "NO", let text) {
            throw IMAPError.loginRejected(text)
        }
        try await refreshCapabilities()
    }

    /// RFC 2971 ID. Bridge answers with its name and version.
    public func serverID() async throws -> [String: String] {
        guard hasCapability("ID") else { return [:] }
        let result = try await run(.id(["name": "slop-export", "version": SlopVersion.current]), describe: "ID")
        var out: [String: String] = [:]
        for case .id(let dict) in result.untagged {
            for (k, v) in dict { out[k] = v ?? "" }
        }
        return out
    }

    public func list() async throws -> [ListedMailbox] {
        let result = try await run(
            .list(nil, reference: MailboxName(Array("".utf8)), .mailbox(ByteBuffer(string: "*"))), describe: "LIST")
        var out: [ListedMailbox] = []
        for case .mailboxData(.list(let info)) in result.untagged {
            out.append(ListedMailbox(
                rawName: info.path.name.bytes,
                components: info.path.displayStringComponents(),
                separator: info.path.pathSeparator,
                attributes: info.attributes.map { String($0) }))
        }
        return out
    }

    public func status(_ mailbox: ListedMailbox, size: Bool) async throws -> MailboxCounts {
        var attrs: [MailboxAttribute] = [.messageCount, .uidValidity]
        if size { attrs.append(.size) }
        let result = try await run(.status(mailbox.mailboxName, attrs), describe: "STATUS \(mailbox.displayPath)")
        for case .mailboxData(.status(_, let st)) in result.untagged {
            return MailboxCounts(messages: st.messageCount, uidValidity: st.uidValidity.map { UInt32($0) }, size: st.size)
        }
        throw IMAPError.unexpected("STATUS returned no data for \(mailbox.displayPath)")
    }

    /// EXAMINE (read-only select), so nothing in the mailbox can change.
    public func examine(_ mailbox: ListedMailbox) async throws -> SelectedMailbox {
        let result = try await run(.examine(mailbox.mailboxName), describe: "EXAMINE \(mailbox.displayPath)")
        var selected = SelectedMailbox(exists: 0)
        for payload in result.untagged {
            switch payload {
            case .mailboxData(.exists(let n)): selected.exists = n
            case .conditionalState(.ok(let text)):
                switch text.code {
                case .uidValidity(let v): selected.uidValidity = UInt32(v)
                case .uidNext(let u): selected.uidNext = u.rawValue
                default: break
                }
            default: break
            }
        }
        return selected
    }

    /// UID, FLAGS, INTERNALDATE and RFC822.SIZE for every message in the selected mailbox, and
    /// optionally the Message-ID header (BODY.PEEK, so nothing is marked read), which lets
    /// messages be matched across mailboxes without downloading them twice.
    public func fetchAllMetadata(withMessageID: Bool = false) async throws -> [FetchRecord] {
        let all = MessageIdentifierSetNonEmpty<UID>(range: MessageIdentifierRange<UID>(UID(rawValue: 1)...))
        var attributes: [FetchAttribute] = [.uid, .flags, .internalDate, .rfc822Size]
        if withMessageID { attributes.append(.bodySection(peek: true, .headerFields(["MESSAGE-ID"]), nil)) }
        let result = try await run(.uidFetch(.set(all), attributes, []), describe: "UID FETCH metadata")
        return result.fetches
    }

    /// Full raw bytes (BODY.PEEK[], so \Seen is never set) for the given UIDs.
    public func fetchBodies(uids: [UInt32]) async throws -> [FetchRecord] {
        guard !uids.isEmpty else { return [] }
        let ranges = uids.map { MessageIdentifierRange<UID>(UID(rawValue: $0)) }
        guard let set = MessageIdentifierSetNonEmpty(set: MessageIdentifierSet(ranges)) else { return [] }
        let result = try await run(
            .uidFetch(.set(set), [.uid, .flags, .internalDate, .rfc822Size, .bodySection(peek: true, .complete, nil)], []),
            describe: "UID FETCH bodies")
        return result.fetches
    }

    public func create(_ path: [String], separator: Character) async throws {
        let name = try Self.mailboxPath(path, separator: separator)
        try await run(.create(name.name, []), describe: "CREATE \(path.joined(separator: "/"))")
    }

    /// APPEND one message, keeping its flags and original date.
    public func append(to path: [String], separator: Character, message: ByteBuffer,
                       flags: [String], date: ServerMessageDate?) async throws {
        let name = try Self.mailboxPath(path, separator: separator).name
        let tag = nextTag()
        let options = AppendOptions(flagList: flags.map { Flag($0) }, internalDate: date, extensions: [:])
        let parts: [CommandStreamPart] = [
            .append(.start(tag: tag, appendingTo: name)),
            .append(.beginMessage(message: AppendMessage(options: options, data: AppendData(byteCount: message.readableBytes)))),
            .append(.messageBytes(message)),
            .append(.endMessage),
            .append(.finish),
        ]
        // The server is silent while the literal streams, and the idle timer only restarts on
        // reads, so allow for a slow uplink (32 KB/s) on top of the usual timeout.
        let upload = TimeAmount.seconds(Int64(message.readableBytes / 32_000))
        _ = try await send(tag: tag, parts: parts, describe: "APPEND \(path.joined(separator: "/"))",
                           timeout: commandTimeout + upload)
    }

    /// STORAGE usage and limit in bytes for the quota root of `mailbox` (RFC 2087), or nil if the
    /// server has no QUOTA support.
    public func storageQuota(for mailbox: [String] = ["INBOX"], separator: Character = "/") async throws -> (used: Int, limit: Int)? {
        guard hasCapability("QUOTA") else { return nil }
        let name = try Self.mailboxPath(mailbox, separator: separator).name
        let result = try await run(.getQuotaRoot(name), describe: "GETQUOTAROOT")
        for case .quota(_, let resources) in result.untagged {
            if let storage = resources.first(where: { $0.resourceName.uppercased() == "STORAGE" }) {
                return (used: storage.usage * 1024, limit: storage.limit * 1024)
            }
        }
        return nil
    }

    public func logout() async {
        _ = try? await run(.logout, describe: "LOGOUT")
    }

    static func mailboxPath(_ components: [String], separator: Character) throws -> MailboxPath {
        guard let first = components.first else { throw IMAPError.unexpected("empty mailbox path") }
        var path = try MailboxPath.makeRootMailbox(displayName: first, pathSeparator: separator)
        for component in components.dropFirst() {
            path = try path.makeSubMailbox(displayName: component)
        }
        return path
    }
}

// MARK: TLS

/// A certificate the user exported from Bridge. Only a server presenting exactly this
/// certificate is accepted (D-004).
public struct PinnedCertificate: Sendable {
    public let der: [UInt8]

    /// Accepts PEM or DER.
    public init(bytes: [UInt8]) throws {
        if let cert = try? NIOSSLCertificate.fromPEMBytes(bytes).first {
            der = try cert.toDERBytes()
        } else {
            der = try NIOSSLCertificate(bytes: bytes, format: .der).toDERBytes()
        }
    }

    public init(contentsOf url: URL) throws {
        try self.init(bytes: Array(try Data(contentsOf: url)))
    }

    /// SHA-256 of the DER bytes, as colon-separated hex, for showing to the user.
    public var fingerprint: String { Hashing.sha256Hex(der).uppercased().chunked(2).joined(separator: ":") }
}

private func makeSSLContext(trust: TrustPolicy) throws -> NIOSSLContext {
    var config = TLSConfiguration.makeClientConfiguration()
    config.minimumTLSVersion = .tlsv12
    switch trust {
    case .system:
        config.certificateVerification = .fullVerification
    case .pinned(let pin):
        // The custom callback below decides; these settings only make the handshake reach it.
        config.trustRoots = .certificates([try NIOSSLCertificate(bytes: pin.der, format: .der)])
        config.certificateVerification = .noHostnameVerification
    }
    return try NIOSSLContext(configuration: config)
}

private func makeTLSHandler(context: NIOSSLContext, host: String, trust: TrustPolicy) throws -> NIOSSLClientHandler {
    switch trust {
    case .system:
        return try NIOSSLClientHandler(context: context, serverHostname: host)
    case .pinned(let pin):
        let expected = pin.der
        return try NIOSSLClientHandler(context: context, serverHostname: nil) { certificates, promise in
            guard let leaf = certificates.first, let der = try? leaf.toDERBytes(), der == expected else {
                promise.succeed(.failed)
                return
            }
            promise.succeed(.certificateVerified)
        }
    }
}

extension String {
    func chunked(_ size: Int) -> [String] {
        var out: [String] = []
        var index = startIndex
        while index < endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(String(self[index..<next]))
            index = next
        }
        return out
    }
}
