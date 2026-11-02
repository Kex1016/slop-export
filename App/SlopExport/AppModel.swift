import Foundation
import Observation
import SlopCore

/// The five steps of the export, in order (PLAN.md, "App flow").
enum Step: String, CaseIterable, Identifiable {
    case connect, scan, export, verify, upload
    var id: String { rawValue }

    var title: String {
        switch self {
        case .connect: "Connect"
        case .scan: "Scan"
        case .export: "Export"
        case .verify: "Verify"
        case .upload: "Upload"
        }
    }

    var symbol: String {
        switch self {
        case .connect: "cable.connector"
        case .scan: "list.bullet.rectangle"
        case .export: "square.and.arrow.down.on.square"
        case .verify: "checkmark.seal"
        case .upload: "icloud.and.arrow.up"
        }
    }
}

@MainActor
@Observable
final class AppModel {
    /// Optional only because `List(selection:)` wants it; nil shows Connect.
    var step: Step? = .connect

    // Connect step. Saved in UserDefaults so the app picks up where it left off.
    var host: String { didSet { save() } }
    var port: Int { didSet { save() } }
    var user: String { didSet { save(); refreshSavedPassword() } }
    /// DER bytes of the certificate exported from Bridge. Certificates are public; keeping the
    /// bytes avoids holding a security-scoped bookmark to the file.
    var certificateDER: [UInt8]? { didSet { save(); certificateFingerprint = Self.fingerprint(certificateDER) } }
    var certificateName: String? { didSet { save() } }

    var isWorking = false
    var status: String?
    var errorMessage: String?
    var report: ProbeReport?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: "bridge.host") ?? "127.0.0.1"
        port = defaults.object(forKey: "bridge.port") as? Int ?? 1143
        user = defaults.string(forKey: "bridge.user") ?? ""
        certificateDER = (defaults.data(forKey: "bridge.certificate")).map { Array($0) }
        certificateName = defaults.string(forKey: "bridge.certificateName")
        certificateFingerprint = Self.fingerprint(certificateDER)
        refreshSavedPassword()
    }

    private func save() {
        defaults.set(host, forKey: "bridge.host")
        defaults.set(port, forKey: "bridge.port")
        defaults.set(user, forKey: "bridge.user")
        defaults.set(certificateDER.map { Data($0) }, forKey: "bridge.certificate")
        defaults.set(certificateName, forKey: "bridge.certificateName")
    }

    /// Cached so SwiftUI body evaluations never parse certificates or query the Keychain.
    private(set) var certificateFingerprint: String?
    private(set) var hasSavedPassword = false

    private static func fingerprint(_ der: [UInt8]?) -> String? {
        der.flatMap { try? PinnedCertificate(bytes: $0).fingerprint }
    }

    private func refreshSavedPassword() {
        hasSavedPassword = !user.isEmpty && (try? KeychainSecrets().password(.bridge, account: user)) != nil
    }

    var canConnect: Bool { !host.isEmpty && !user.isEmpty && certificateDER != nil && !isWorking }

    func importCertificate(from url: URL) {
        errorMessage = nil
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let pin = try PinnedCertificate(contentsOf: url)
            certificateDER = pin.der
            certificateName = url.lastPathComponent
        } catch {
            errorMessage = "That file is not a certificate Bridge exported: \(error.localizedDescription)"
        }
    }

    /// Saves a newly typed password to the Keychain. The text field is cleared by the caller;
    /// the password is never stored anywhere else.
    /// Returns false (and shows why) if the Keychain refused it.
    @discardableResult
    func savePassword(_ password: String) -> Bool {
        guard !password.isEmpty, !user.isEmpty else { return true }
        do {
            try KeychainSecrets().setPassword(password, .bridge, account: user)
            refreshSavedPassword()
            return true
        } catch {
            errorMessage = "Could not save the password to the Keychain: \(error)"
            return false
        }
    }

    func connectAndScan() async {
        guard let der = certificateDER else { return }
        isWorking = true
        errorMessage = nil
        status = "Connecting to Bridge…"
        defer { isWorking = false }
        do {
            guard let password = try KeychainSecrets().password(.bridge, account: user) else {
                throw SecretError.missing(.bridge, account: user)
            }
            let endpoint = ServerEndpoint(host: host, port: port, tls: .startTLS,
                                          trust: .pinned(try PinnedCertificate(bytes: der)))
            let report = try await Probe.run(endpoint: endpoint, user: user, password: password) { line in
                // Progress hops arrive out of band; drop any that land after the scan ended.
                Task { @MainActor in if self.isWorking { self.status = line } }
            }
            self.report = report
            status = nil
            step = .scan
        } catch {
            status = nil
            errorMessage = String(describing: error)
        }
    }
}
