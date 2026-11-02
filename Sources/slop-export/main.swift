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
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
            return
        }
        print(ProbeFormatter.table(report))
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
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        let summary = try await exporter.run()
        print("""
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
        let dir = URL(fileURLWithPath: export)
        let state = try ExportState.load(from: dir)
        let result = try MboxWriter(store: MessageStore(root: dir.appendingPathComponent("store"))).write(
            state: state, to: URL(fileURLWithPath: out))
        for (mailbox, count) in result.mailboxes.sorted(by: { $0.key < $1.key }) {
            print("\(mailbox): \(count)")
        }
        print("\(result.messages) messages, \(ProbeFormatter.byteString(result.bytes)) in \(result.mailboxes.count) mailboxes")
    }
}

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Compare Bridge, the export and iCloud (Phase 6).")
    func run() async throws { throw ValidationError("verify is not built yet (PLAN.md Phase 6).") }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload the export to iCloud Mail (Phase 5).")
    func run() async throws { throw ValidationError("upload is not built yet (PLAN.md Phase 5).") }
}
