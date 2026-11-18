import CGtk
import Foundation
import SlopCore
import SlopLinux

// Slop Export for Linux (GTK 3), D-016. Same five steps as the macOS app, on the same SlopCore.

let applicationID = "io.github.kex1016.SlopExport"

@MainActor
final class App {
    static var window: MainWindow?

    static func activate(_ application: UnsafeMutablePointer<GtkApplication>) {
        // Single instance: a second launch brings the open window forward instead of starting a
        // second export into the same folder.
        if let window {
            gtk_window_present(cast(window.window))
            return
        }
        installStyles()
        let session = Session(settingsFile: .standard(), vault: EnvironmentFirstVault(SecretServiceVault()),
                              icloudEndpoint: icloudEndpoint())
        let window = MainWindow(application: application, session: session)
        Self.window = window
        window.show()
    }
}

/// iCloud Mail, or for end-to-end tests the iCloud fixture server. The test server is only
/// accepted together with its exact certificate (pinned), so this cannot weaken TLS.
func icloudEndpoint() -> @Sendable (String) -> ServerEndpoint {
    let env = ProcessInfo.processInfo.environment
    if let server = env["SLOP_ICLOUD_TEST_SERVER"], let certPath = env["SLOP_ICLOUD_TEST_CERT"],
       let colon = server.lastIndex(of: ":"), let port = Int(server[server.index(after: colon)...]),
       let pin = try? PinnedCertificate(contentsOf: URL(fileURLWithPath: certPath)) {
        let host = String(server[..<colon])
        return { _ in ServerEndpoint(host: host, port: port, tls: .implicit, trust: .pinned(pin)) }
    }
    return { ICloudSettings(user: $0).endpoint }
}

if CommandLine.arguments.contains("--version") {
    print("slop-export-gtk \(SlopVersion.current)")
    exit(0)
}

g_set_prgname("slop-export-gtk")
g_set_application_name("Slop Export")
MainQueueBridge.install()
let application = gtk_application_new(applicationID, GApplicationFlags(rawValue: 0))!
on(application, "activate") { App.activate(application) }
let status = g_application_run(cast(application), CommandLine.argc, CommandLine.unsafeArgv)
g_object_unref(application)
exit(status)
