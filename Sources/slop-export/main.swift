import ArgumentParser
import Foundation
import SlopCore

@main
struct SlopExport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "slop-export",
        abstract: "Export Proton Mail (through Proton Mail Bridge) to iCloud Mail.",
        version: SlopVersion.current,
        subcommands: [ProbeCommand.self, ExportCommand.self, VerifyCommand.self, UploadCommand.self]
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
    static let configuration = CommandConfiguration(commandName: "export", abstract: "Download every message into a local store (Phase 3).")
    func run() async throws { throw ValidationError("export is not built yet (PLAN.md Phase 3).") }
}

struct VerifyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "verify", abstract: "Compare Bridge, the export and iCloud (Phase 6).")
    func run() async throws { throw ValidationError("verify is not built yet (PLAN.md Phase 6).") }
}

struct UploadCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "upload", abstract: "Upload the export to iCloud Mail (Phase 5).")
    func run() async throws { throw ValidationError("upload is not built yet (PLAN.md Phase 5).") }
}
