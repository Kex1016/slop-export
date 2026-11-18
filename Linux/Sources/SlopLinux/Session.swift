import Foundation
import SlopCore

/// The five steps of the export, in the same order as the macOS app (PLAN.md, "App flow").
public enum Step: String, CaseIterable, Sendable {
    case connect, scan, export, verify, upload

    public var title: String {
        switch self {
        case .connect: "Connect"
        case .scan: "Scan"
        case .export: "Export"
        case .verify: "Verify"
        case .upload: "Upload"
        }
    }
}

/// The Linux app's state and actions, with no GTK in it so it can be tested headless against
/// the fixture servers. The GTK window draws from it and calls into it; `onChange` tells the
/// window to redraw. It drives the same SlopCore types as the macOS `AppModel` (Probe, Exporter,
/// MboxWriter, Uploader, Verifier) and keeps the same folder layout, so an export folder made on
/// one system can be resumed on the other.
@MainActor
public final class Session {
    /// Called after any state change. The window coalesces these into one redraw.
    public var onChange: (() -> Void)?

    public var step: Step = .connect { didSet { changed() } }

    private let settingsFile: SettingsFile?
    public private(set) var settings: AppSettings
    private let vault: PasswordVault
    private let icloudEndpoint: @Sendable (String) -> ServerEndpoint

    /// - Parameters:
    ///   - settingsFile: where settings persist; nil keeps them in memory (tests).
    ///   - icloudEndpoint: the iCloud server for an Apple ID. Tests point it at the fixture.
    public init(settingsFile: SettingsFile?, vault: PasswordVault,
                icloudEndpoint: @escaping @Sendable (String) -> ServerEndpoint = { ICloudSettings(user: $0).endpoint }) {
        self.settingsFile = settingsFile
        self.settings = settingsFile?.load() ?? AppSettings()
        self.vault = vault
        self.icloudEndpoint = icloudEndpoint
        certificateFingerprint = Self.fingerprint(settings.certificateDER)
        refreshSavedPasswords()
        refreshExistingExport()
    }

    private func changed() { onChange?() }

    private func update(_ body: (inout AppSettings) -> Void) {
        var next = settings
        body(&next)
        guard next != settings else { return }
        settings = next
        do {
            try settingsFile?.save(settings)
        } catch {
            errors[step] = "Could not save settings to \(settingsFile?.url.path ?? "?"): \(error.localizedDescription)"
        }
        changed()
    }

    // MARK: State shared by every step

    public private(set) var isWorking = false { didSet { changed() } }
    public private(set) var status: String? { didSet { changed() } }
    /// The last error of each step, shown under that step only (as in the macOS app, D-014).
    public var errors: [Step: String] = [:] { didSet { changed() } }

    // MARK: Connect

    public var host: String {
        get { settings.host }
        set { update { $0.host = newValue } }
    }
    public var port: Int {
        get { settings.port }
        set { update { $0.port = newValue } }
    }
    /// As typed. Changing it does not query the keyring on every keystroke; the window calls
    /// `refreshSavedPasswords()` when the field loses focus.
    public var user: String {
        get { settings.user }
        set { update { $0.user = newValue } }
    }
    public var certificateName: String? { settings.certificateName }
    public var hasCertificate: Bool { settings.certificateDER != nil }
    public private(set) var certificateFingerprint: String?
    public private(set) var hasSavedPassword = false { didSet { changed() } }
    public private(set) var report: ProbeReport? { didSet { changed() } }

    /// The user name minus pasted whitespace or invisible characters, used for LOGIN and as the
    /// keyring account (D-015).
    public var bridgeAccount: String { Credentials.clean(settings.user) }
    public var icloudAccount: String { Credentials.clean(settings.icloudUser) }

    private static func fingerprint(_ der: Data?) -> String? {
        der.flatMap { try? PinnedCertificate(bytes: Array($0)).fingerprint }
    }

    public func refreshSavedPasswords() {
        hasSavedPassword = !bridgeAccount.isEmpty && (try? vault.password(.bridge, account: bridgeAccount)) != nil
        hasSavedICloudPassword = !icloudAccount.isEmpty && (try? vault.password(.icloud, account: icloudAccount)) != nil
    }

    public var canConnect: Bool { !host.isEmpty && !bridgeAccount.isEmpty && hasCertificate && !isWorking }

    public func importCertificate(at path: String) {
        errors[.connect] = nil
        do {
            let pin = try PinnedCertificate(contentsOf: URL(fileURLWithPath: path))
            update {
                $0.certificateDER = Data(pin.der)
                $0.certificateName = (path as NSString).lastPathComponent
            }
            certificateFingerprint = pin.fingerprint
            changed()
        } catch {
            errors[.connect] = "That file is not a certificate Bridge exported: \(error)"
        }
    }

    /// Moves a newly typed password into the keyring. Returns false (and shows why) if the
    /// keyring refused it, so the window keeps what was typed.
    @discardableResult
    public func savePassword(_ password: String, _ kind: SecretKind) -> Bool {
        let account = kind == .bridge ? bridgeAccount : icloudAccount
        let clean = Credentials.clean(password)
        guard !clean.isEmpty, !account.isEmpty else { return true }
        do {
            try vault.setPassword(clean, kind, account: account)
            refreshSavedPasswords()
            return true
        } catch {
            errors[kind == .bridge ? .connect : .upload] = "Could not save the password to the keyring: \(error)"
            return false
        }
    }

    private func bridgeEndpoint() throws -> ServerEndpoint {
        guard let der = settings.certificateDER else { throw SessionError.noCertificate }
        return ServerEndpoint(host: settings.host, port: settings.port, tls: .startTLS,
                              trust: .pinned(try PinnedCertificate(bytes: Array(der))))
    }

    private func requirePassword(_ kind: SecretKind, account: String) throws -> String {
        guard let password = try vault.password(kind, account: account) else {
            throw SessionError.missingPassword(kind)
        }
        return password
    }

    public func connectAndScan() async {
        guard canConnect else { return }
        isWorking = true
        errors[.connect] = nil
        status = "Connecting to Bridge…"
        defer { isWorking = false }
        do {
            let user = bridgeAccount
            let password = try requirePassword(.bridge, account: user)
            let report = try await Probe.run(endpoint: try bridgeEndpoint(), user: user, password: password) { line in
                // Progress lines arrive out of band; drop any that land after the scan ended.
                Task { @MainActor in if self.isWorking { self.status = line } }
            }
            self.report = report
            status = nil
            step = .scan
        } catch {
            status = nil
            errors[.connect] = String(describing: error)
        }
    }

    // MARK: Export

    public var exportFolder: String? { settings.exportFolder }
    public private(set) var exportProgress: ExportProgress? { didSet { changed() } }
    public private(set) var exportSummary: ExportSummary? { didSet { changed() } }
    public private(set) var mboxResult: MboxWriter.Result? { didSet { changed() } }
    public private(set) var isExporting = false { didSet { changed() } }
    public private(set) var hasExistingExport = false { didSet { changed() } }
    public private(set) var isBuildingMailboxes = false { didSet { changed() } }
    private var exportTask: Task<Void, Never>?

    /// Same names as the macOS app, so one export folder works on both.
    public nonisolated static func exportDirectory(in folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("Proton Export", isDirectory: true)
    }

    public nonisolated static func mboxDirectory(in folder: String) -> URL {
        URL(fileURLWithPath: folder, isDirectory: true).appendingPathComponent("Apple Mail Import", isDirectory: true)
    }

    public func chooseExportFolder(_ path: String) {
        guard !isExporting else { return }
        errors[.export] = nil
        update { $0.exportFolder = path }
        exportSummary = nil
        exportProgress = nil
        mboxResult = nil
        uploadPlan = nil
        refreshExistingExport()
    }

    public func refreshExistingExport() {
        guard let folder = settings.exportFolder else { hasExistingExport = false; return }
        hasExistingExport = FileManager.default.fileExists(
            atPath: Self.exportDirectory(in: folder).appendingPathComponent("journal.jsonl").path)
    }

    public var canExport: Bool { exportFolder != nil && hasCertificate && !bridgeAccount.isEmpty && !isExporting }

    /// Starts or resumes. Stopping and starting again is always safe: the journal in the export
    /// folder records what is done.
    public func startExport() {
        guard canExport, let folder = settings.exportFolder else { return }
        let user = bridgeAccount
        errors[.export] = nil
        exportSummary = nil
        isExporting = true
        exportTask = Task {
            defer {
                isExporting = false
                exportTask = nil
            }
            do {
                let password = try requirePassword(.bridge, account: user)
                let endpoint = try bridgeEndpoint()
                let directory = Self.exportDirectory(in: folder)
                let exporter = try await Task.detached(priority: .userInitiated) {
                    try Exporter(directory: directory, connect: {
                        try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password)
                    }, progress: { progress in
                        Task { @MainActor in self.exportProgress = progress }
                    })
                }.value
                exportSummary = try await exporter.run()
                hasExistingExport = true
            } catch is CancellationError {
                exportProgress = nil
                refreshExistingExport()
            } catch {
                errors[.export] = String(describing: error)
                refreshExistingExport()
            }
        }
    }

    public func pauseExport() {
        exportTask?.cancel()
    }

    /// Waits for a running export (tests).
    public func waitForExport() async {
        await exportTask?.value
    }

    /// Path A: Apple Mail mailboxes next to the export, off the main thread.
    public func buildMailboxes() {
        guard let folder = settings.exportFolder, hasExistingExport, !isBuildingMailboxes, !isExporting else { return }
        isBuildingMailboxes = true
        errors[.export] = nil
        mailboxTask = Task {
            defer { isBuildingMailboxes = false }
            do {
                mboxResult = try await Task.detached(priority: .userInitiated) {
                    try MboxWriter.build(exportDirectory: Session.exportDirectory(in: folder),
                                         to: Session.mboxDirectory(in: folder))
                }.value
            } catch {
                errors[.export] = String(describing: error)
            }
        }
    }

    private var mailboxTask: Task<Void, Never>?

    public func waitForMailboxes() async {
        await mailboxTask?.value
    }

    // MARK: Verify

    public var verifyBridge = true { didSet { changed() } }
    public var verifyICloud = true { didSet { changed() } }
    public private(set) var verifyReport: VerifyReport? { didSet { changed() } }
    public private(set) var isVerifying = false { didSet { changed() } }
    private var verifyTask: Task<Void, Never>?

    public var canVerify: Bool { exportFolder != nil && hasExistingExport && !isVerifying && !isUploading && !isExporting }
    public var canVerifyBridge: Bool { hasCertificate && !bridgeAccount.isEmpty && hasSavedPassword }
    public var canVerifyICloud: Bool { !icloudAccount.isEmpty && hasSavedICloudPassword }

    /// Only reads: Bridge and iCloud are opened read-only (STATUS, EXAMINE, BODY.PEEK).
    public func runVerify() {
        guard canVerify, let folder = settings.exportFolder else { return }
        isVerifying = true
        errors[.verify] = nil
        var bridge: (@Sendable () async throws -> IMAPClient)?
        var icloud: (@Sendable () async throws -> IMAPClient)?
        do {
            if verifyBridge, canVerifyBridge {
                let endpoint = try bridgeEndpoint()
                let user = bridgeAccount
                let password = try requirePassword(.bridge, account: user)
                bridge = { try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password) }
            }
            if verifyICloud, canVerifyICloud {
                let user = icloudAccount
                let endpoint = icloudEndpoint(user)
                let password = try requirePassword(.icloud, account: user)
                icloud = { try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password) }
            }
        } catch {
            errors[.verify] = String(describing: error)
            isVerifying = false
            return
        }
        verifyTask = Task { [bridge, icloud] in
            defer { isVerifying = false }
            do {
                let mbox = Self.mboxDirectory(in: folder)
                let inputs = Verifier.Inputs(exportDirectory: Self.exportDirectory(in: folder),
                                             mboxDirectory: FileManager.default.fileExists(atPath: mbox.path) ? mbox : nil,
                                             bridge: bridge, icloud: icloud)
                verifyReport = try await Task.detached(priority: .userInitiated) { try await Verifier.run(inputs) }.value
            } catch {
                errors[.verify] = String(describing: error)
            }
        }
    }

    public func waitForVerify() async {
        await verifyTask?.value
    }

    public enum ReportFormat: Sendable { case html, text }

    /// Saves the last verify report. Returns false (and shows why) if it could not be written.
    @discardableResult
    public func saveReport(_ format: ReportFormat, to path: String) -> Bool {
        guard let report = verifyReport else { return false }
        let body = format == .html ? VerifyFormatter.html(report) : VerifyFormatter.text(report)
        do {
            try Data(body.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            return true
        } catch {
            errors[.verify] = "Could not save the report: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Upload

    public var icloudUser: String {
        get { settings.icloudUser }
        set {
            let before = icloudAccount
            update { $0.icloudUser = newValue }
            if icloudAccount != before { uploadPlan = nil }  // a plan is only good for its account
        }
    }
    public private(set) var hasSavedICloudPassword = false { didSet { changed() } }
    public private(set) var uploadPlan: UploadPlan? { didSet { changed() } }
    public private(set) var uploadProgress: UploadProgress? { didSet { changed() } }
    public private(set) var uploadSummary: UploadSummary? { didSet { changed() } }
    public private(set) var isPlanning = false { didSet { changed() } }
    public private(set) var isUploading = false { didSet { changed() } }
    private var uploadTask: Task<Void, Never>?

    public var canPlanUpload: Bool {
        exportFolder != nil && hasExistingExport && !icloudAccount.isEmpty && !isPlanning && !isUploading && !isExporting
    }

    /// The upload button needs a fresh dry run for this account that fits in iCloud.
    public var canUpload: Bool {
        canPlanUpload && uploadPlan != nil && uploadPlan?.shortfall == nil
    }

    private func makeUploader(folder: String) async throws -> Uploader {
        let user = icloudAccount
        let password = try requirePassword(.icloud, account: user)
        let endpoint = icloudEndpoint(user)
        let directory = Self.exportDirectory(in: folder)
        // Replaying the journal can take a while on a big export, so it happens off the main actor.
        return try await Task.detached(priority: .userInitiated) {
            try Uploader(exportDirectory: directory, connect: {
                try await IMAPClient.connectAndLogin(to: endpoint, user: user, password: password)
            }, progress: { progress in
                Task { @MainActor in self.uploadProgress = progress }
            })
        }.value
    }

    /// Dry run: reads iCloud and reports what the upload would do. Writes nothing.
    public func planUpload() {
        guard canPlanUpload, let folder = settings.exportFolder else { return }
        isPlanning = true
        errors[.upload] = nil
        uploadTask = Task {
            defer { isPlanning = false }
            do {
                uploadPlan = try await makeUploader(folder: folder).plan()
            } catch {
                errors[.upload] = String(describing: error)
            }
        }
    }

    /// The real upload. The window asks for confirmation first.
    public func startUpload() {
        guard canUpload, let folder = settings.exportFolder else { return }
        isUploading = true
        errors[.upload] = nil
        uploadSummary = nil
        uploadTask = Task {
            defer {
                isUploading = false
                uploadTask = nil
            }
            do {
                uploadSummary = try await makeUploader(folder: folder).run()
                uploadPlan = nil  // spent; check again before another upload
            } catch is CancellationError {
                uploadProgress = nil
            } catch {
                errors[.upload] = String(describing: error)
            }
        }
    }

    public func pauseUpload() {
        guard isUploading else { return }
        uploadTask?.cancel()
    }

    public func waitForUpload() async {
        await uploadTask?.value
    }
}

public enum SessionError: Error, CustomStringConvertible {
    case noCertificate
    case missingPassword(SecretKind)

    public var description: String {
        switch self {
        case .noCertificate:
            "Choose the certificate exported from Bridge first."
        case .missingPassword(.bridge):
            "No Bridge password saved for this user name. Type it in the Connect step."
        case .missingPassword(.icloud):
            "No app-specific password saved for this Apple ID. Type it in the Upload step."
        }
    }
}
