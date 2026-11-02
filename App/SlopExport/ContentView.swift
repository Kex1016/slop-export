import SlopCore
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(Step.allCases, selection: $model.step) { step in
                Label(step.title, systemImage: step.symbol)
                    .tag(step)
                    .accessibilityIdentifier("step-\(step.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            switch model.step ?? .connect {
            case .connect: ConnectView()
            case .scan: ScanView()
            case .export: ExportView()
            case .verify: PendingStepView(step: .verify, phase: 6)
            case .upload: PendingStepView(step: .upload, phase: 5)
            }
        }
    }
}

struct ConnectView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var choosingCertificate = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Host", text: $model.host)
                TextField("Port", value: $model.port, format: .number.grouping(.never))
                TextField("User name", text: $model.user, prompt: Text("The user name Bridge shows for your account"))
                    .accessibilityIdentifier("bridge-user")
            } header: {
                Text("Proton Mail Bridge")
            } footer: {
                Text("Open Bridge, choose your account, and copy the IMAP details. slop-export only reads from Bridge.")
            }

            Section("Bridge password") {
                SecureField("Bridge password", text: $password, prompt: Text(model.hasSavedPassword ? "Saved in Keychain" : "From Bridge, not your Proton password"))
                    .accessibilityIdentifier("bridge-password")
                    .onSubmit { savePassword() }
            }

            Section {
                HStack {
                    Text(model.certificateName ?? "No certificate chosen")
                        .foregroundStyle(model.certificateDER == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { choosingCertificate = true }
                }
                if let fingerprint = model.certificateFingerprint {
                    Text("SHA-256 \(fingerprint)")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Bridge certificate")
            } footer: {
                Text("In Bridge: Settings › Advanced settings › Export TLS certificates. Only a Bridge presenting this exact certificate is accepted.")
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).accessibilityIdentifier("connect-error")
            }

            HStack {
                if let status = model.status {
                    ProgressView().controlSize(.small)
                    Text(status).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Connect and scan") {
                    guard savePassword() else { return }
                    Task { await model.connectAndScan() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canConnect)
                .accessibilityIdentifier("connect-button")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Connect")
        .fileImporter(isPresented: $choosingCertificate, allowedContentTypes: [.x509Certificate, .data]) { result in
            if case .success(let url) = result { model.importCertificate(from: url) }
        }
    }

    /// Moves the typed password into the Keychain. The field is cleared only if that worked,
    /// so a Keychain failure does not lose what was typed.
    @discardableResult
    private func savePassword() -> Bool {
        guard model.savePassword(password) else { return false }
        password = ""
        return true
    }
}

struct ScanView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let report = model.report {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 24) {
                        LabeledContent("Messages to export", value: report.exportedMessageCount.formatted())
                        if let all = report.allMailCount {
                            LabeledContent("All Mail", value: all.formatted())
                        }
                        if let name = report.server["name"] {
                            LabeledContent("Server", value: [name, report.server["version"]].compactMap { $0 }.joined(separator: " "))
                        }
                    }
                    Table(report.mailboxes) {
                        TableColumn("Mailbox", value: \.path)
                        TableColumn("Messages") { box in Text(box.messages.map { $0.formatted() } ?? "–") }
                            .width(min: 70, ideal: 80)
                        TableColumn("Size") { box in Text(box.size.map(ProbeFormatter.byteString) ?? "–") }
                            .width(min: 70, ideal: 90)
                        TableColumn("Plan") { box in Text(ProbeFormatter.describe(box.role)).foregroundStyle(.secondary) }
                    }
                }
                .padding()
            } else {
                ContentUnavailableView("Not scanned yet", systemImage: "list.bullet.rectangle",
                                       description: Text("Connect to Bridge first."))
            }
        }
        .navigationTitle("Scan")
    }
}

struct ExportView: View {
    @Environment(AppModel.self) private var model
    @State private var choosingFolder = false

    var body: some View {
        Form {
            Section {
                HStack {
                    Text(model.exportFolder?.path ?? "No folder chosen")
                        .foregroundStyle(model.exportFolder == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { choosingFolder = true }.disabled(model.isExporting)
                }
            } header: {
                Text("Export folder")
            } footer: {
                Text("Needs room for all of your mail. The app keeps its progress here, so you can quit and carry on later.")
            }

            Section("Download from Bridge") {
                if let progress = model.exportProgress {
                    ExportProgressView(progress: progress)
                }
                if let summary = model.exportSummary {
                    LabeledContent("Messages exported", value: summary.distinctMessages.formatted())
                    LabeledContent("Only in All Mail (go to Unfiled)", value: summary.unfiled.formatted())
                }
                HStack {
                    Spacer()
                    if model.isExporting {
                        Button("Pause") { model.pauseExport() }
                            .accessibilityIdentifier("pause-export")
                    } else {
                        Button(model.hasExistingExport ? "Resume export" : "Start export") { model.startExport() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.canExport)
                            .accessibilityIdentifier("start-export")
                    }
                }
            }

            Section {
                if let result = model.mboxResult {
                    LabeledContent("Mailboxes written", value: result.mailboxes.count.formatted())
                    LabeledContent("Messages", value: result.messages.formatted())
                }
                HStack {
                    Spacer()
                    if model.isBuildingMailboxes { ProgressView().controlSize(.small) }
                    Button("Build Apple Mail mailboxes") { model.buildMailboxes() }
                        .disabled(model.isExporting || model.isBuildingMailboxes || !model.hasExistingExport)
                }
            } header: {
                Text("Apple Mail (optional)")
            } footer: {
                Text("Writes .mbox mailboxes to \"Apple Mail Import\" in the export folder, for File › Import Mailboxes in Mail. Uploading straight to iCloud (the Upload step) does not need this.")
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Export")
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.chooseExportFolder(url) }
        }
    }
}

struct ExportProgressView: View {
    let progress: ExportProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch progress.phase {
            case .downloading where progress.total > 0:
                ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                    Text(progress.mailbox ?? "")
                } currentValueLabel: {
                    Text("\(progress.done.formatted()) of \(progress.total.formatted())")
                }
            case .done:
                Label("Export complete", systemImage: "checkmark.circle")
            default:
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress.message ?? progress.mailbox.map { "Scanning \($0)" } ?? "Connecting…")
                }
            }
            Text("\(ProbeFormatter.byteString(progress.downloadedBytes)) downloaded this session")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct PendingStepView: View {
    let step: Step
    let phase: Int

    var body: some View {
        ContentUnavailableView(step.title, systemImage: step.symbol,
                               description: Text("Coming in a later build (PLAN.md phase \(phase))."))
            .navigationTitle(step.title)
    }
}
