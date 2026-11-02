import ArgumentParser
import Foundation
import SlopCore

@main
struct SlopExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slop-export",
        abstract: "Export Proton Mail (through Proton Mail Bridge) to iCloud Mail.",
        version: SlopVersion.current,
        subcommands: [ProbeCommand.self, ExportCommand.self, MboxCommand.self, VerifyCommand.self, UploadCommand.self]
    )
}

struct BridgeOptions: ParsableArguments {
    @Option(help: "Bridge IMAP host.") var host = "127.0.0.1"
    @Option(help: "Bridge IMAP port.") var port = 1143
    @Option(help: "Bridge IMAP user name (shown in Bridge's mailbox details).") var user: String
    @Option(help: "Certificate exported from Bridge. Only a server presenting exactly this certificate is accepted.")
    var cert: String
    @Option(help: "starttls (Bridge default) or tls.") var tls: TLSMode = .startTLS

    var settings: BridgeSettings {
        BridgeSettings(host: host, port: port, user: user, tls: tls, certificatePath: cert)
    }
}

extension TLSMode: ExpressibleByArgument {}

struct ProbeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "probe",
        abstract: "List every Bridge mailbox with message counts and sizes. Downloads no mail.")

    @OptionGroup var bridge: BridgeOptions
    @Flag(help: "Print JSON instead of a table.") var json = false

    func run() async throws {
        let password = try DefaultSecrets().require(.bridge, account: bridge.user)
        let report = try await Probe.run(settings: bridge.settings, password: password) { line in
            err(line)
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            say(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        say(ProbeFormatter.table(report))
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Download every message into a local store. Safe to stop and re-run; it resumes.")

    @OptionGroup var bridge: BridgeOptions
    @Option(help: "Export folder (store/, journal.jsonl, manifest.json).") var out: String

    func run() async throws {
        let password = try DefaultSecrets().require(.bridge, account: bridge.user)
        let exporter = try Exporter(directory: URL(fileURLWithPath: out), settings: bridge.settings, password: password) { p in
            let line: String
            switch p.phase {
            case .downloading: line = "\(p.mailbox ?? ""): \(p.done)/\(p.total)"
            case .scanning: line = "Scanning \(p.mailbox ?? "")"
            case .connecting: line = p.message ?? "Connecting"
            case .matching: line = "Matching \(p.mailbox ?? "")"
            case .writingManifest: line = "Writing manifest"
            case .done: line = "Done"
            }
            err(line)
        }
        let summary = try await exporter.run()
        say("""
            Distinct messages: \(summary.distinctMessages)
            Downloaded this run: \(summary.downloadedThisRun)
            Matched without download: \(summary.matchedWithoutDownload)
            Unfiled (only in All Mail): \(summary.unfiled)
            Skipped (server refused them): \(summary.skipped)
            """)
    }
}

struct MboxCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mbox",
        abstract: "Build Apple Mail .mbox bundles from an export (Path A). Needs no connection.")

    @Option(help: "Export folder written by `export`.") var export: String
    @Option(help: "Where to write the .mbox bundles. Replaced if it exists.") var out: String

    func run() async throws {
        let result = try MboxWriter.build(exportDirectory: URL(fileURLWithPath: export), to: URL(fileURLWithPath: out))
        for (mailbox, count) in result.mailboxes.sorted(by: { $0.key < $1.key }) {
            say("\(mailbox): \(count)")
        }
        say("\(result.messages) messages, \(ProbeFormatter.byteString(result.bytes)) in \(result.mailboxes.count) mailboxes")
    }
}

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Compare Bridge, the export, the Apple Mail folders and iCloud, and list anything missing.",
        discussion: "Only reads. Each side is optional: leave out --bridge-user, --mbox or --icloud-user to skip it. Exits 1 if the check fails.")

    @Option(help: "Export folder written by `export`.") var export: String
    @Option(help: "Apple Mail folders written by `mbox`.") var mbox: String?

    @Option(help: "Bridge IMAP user name. Leave out to use the counts from the last export scan.") var bridgeUser: String?
    @Option(help: "Certificate exported from Bridge (needed with --bridge-user).") var bridgeCert: String?
    @Option(help: "Bridge IMAP host.") var bridgeHost = "127.0.0.1"
    @Option(help: "Bridge IMAP port.") var bridgePort = 1143
    @Option(help: "starttls (Bridge default) or tls.") var bridgeTls: TLSMode = .startTLS

    @Option(help: "Apple ID email for iCloud Mail. Leave out to skip the iCloud check.") var icloudUser: String?
    @Option(help: "iCloud IMAP host.") var icloudHost = "imap.mail.me.com"
    @Option(help: "iCloud IMAP port (implicit TLS).") var icloudPort = 993
    @Option(help: "For tests: trust exactly this certificate for iCloud instead of the system trust store.") var icloudPinCert: String?

    @Flag(help: "Print JSON instead of text.") var json = false
    @Option(help: "Also save the report as HTML to this file.") var html: String?
    @Option(help: "Also save the report as plain text to this file.") var text: String?

    func validate() throws {
        if bridgeUser != nil, bridgeCert == nil { throw ValidationError("--bridge-user needs --bridge-cert.") }
    }

    func run() async throws {
        var bridge: (@Sendable () async throws -> IMAPClient)?
        if let bridgeUser, let bridgeCert {
            let settings = BridgeSettings(host: bridgeHost, port: bridgePort, user: bridgeUser, tls: bridgeTls, certificatePath: bridgeCert)
            let endpoint = try settings.endpoint()
            let password = try DefaultSecrets().require(.bridge, account: bridgeUser)
            bridge = { try await IMAPClient.connectAndLogin(to: endpoint, user: bridgeUser, password: password) }
        }
        var icloud: (@Sendable () async throws -> IMAPClient)?
        if let icloudUser {
            var endpoint = ICloudSettings(host: icloudHost, port: icloudPort, user: icloudUser).endpoint
            if let icloudPinCert { endpoint.trust = .pinned(try PinnedCertificate(contentsOf: URL(fileURLWithPath: icloudPinCert))) }
            let password = try DefaultSecrets().require(.icloud, account: icloudUser)
            icloud = { [endpoint] in try await IMAPClient.connectAndLogin(to: endpoint, user: icloudUser, password: password) }
        }
        let report = try await Verifier.run(.init(exportDirectory: URL(fileURLWithPath: export),
                                                  mboxDirectory: mbox.map { URL(fileURLWithPath: $0) },
                                                  bridge: bridge, icloud: icloud))
        let plain = VerifyFormatter.text(report)
        if let html { try Data(VerifyFormatter.html(report).utf8).write(to: URL(fileURLWithPath: html), options: .atomic) }
        if let text { try Data(plain.utf8).write(to: URL(fileURLWithPath: text), options: .atomic) }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            say(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            say(plain, terminator: "")
        }
        if !report.passed { throw ExitCode(1) }
    }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload",
        abstract: "Upload an export to iCloud Mail. Dry run unless --write is given.",
        discussion: """
            Uses an app-specific password (account.apple.com > Sign-In and Security > App-Specific Passwords) \
            from the Keychain item slop-export.icloud or SLOP_ICLOUD_PASSWORD. Safe to re-run: messages \
            already in iCloud are skipped.
            """)

    @Option(help: "Export folder written by `export`.") var export: String
    @Option(help: "Apple ID email for iCloud Mail.") var user: String
    @Option(help: "iCloud IMAP host.") var host = "imap.mail.me.com"
    @Option(help: "iCloud IMAP port (implicit TLS).") var port = 993
    @Option(help: "For tests: trust exactly this certificate instead of the system trust store.") var pinCert: String?
    @Flag(help: "Actually write to iCloud. Without it, only reports what would happen.") var write = false

    func run() async throws {
        let password = try DefaultSecrets().require(.icloud, account: user)
        var endpoint = ICloudSettings(host: host, port: port, user: user).endpoint
        if let pinCert { endpoint.trust = .pinned(try PinnedCertificate(contentsOf: URL(fileURLWithPath: pinCert))) }
        let user = self.user
        let uploader = try Uploader(exportDirectory: URL(fileURLWithPath: export), connect: { [endpoint] in
            try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password)
        }, progress: { p in
            if let message = p.message {
                err(message)
            } else if let folder = p.folder, p.total > 0, p.done == p.total || p.done % 100 == 0 {
                err("\(folder): \(p.done)/\(p.total)")
            }
        })
        let plan = try await uploader.plan()
        for folder in plan.folders {
            say("\(folder.path)\(folder.exists ? "" : " (new)"): \(folder.toUpload) to upload, \(folder.alreadyThere) already there")
        }
        say("Total: \(plan.messagesToUpload) messages, \(ProbeFormatter.byteString(plan.bytesToUpload))")
        if let used = plan.quotaUsed, let limit = plan.quotaLimit {
            say("iCloud storage: \(ProbeFormatter.byteString(used)) of \(ProbeFormatter.byteString(limit)) used")
        }
        if let missing = plan.shortfall {
            throw UploadError.notEnoughSpace(needed: plan.bytesToUpload, missing: missing)
        }
        guard write else {
            say("Dry run: nothing was written. Re-run with --write to upload.")
            return
        }
        let summary = try await uploader.run()
        say("Uploaded \(summary.uploaded), already there \(summary.alreadyThere), failed \(summary.failed)"
            + (summary.failed > 0 ? " (copies in \"Not uploaded\" in the export folder)" : ""))
    }
}

/// Everything the CLI prints goes through these, so server-supplied text cannot drive the terminal.
func say(_ text: String, terminator: String = "\n") {
    print(TerminalText.safe(text), terminator: terminator)
}

func err(_ text: String) {
    FileHandle.standardError.write(Data((TerminalText.safe(text) + "\n").utf8))
}
