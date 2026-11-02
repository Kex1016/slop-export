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
            Group {
                switch model.step ?? .connect {
                case .connect: ConnectView()
                case .scan: ScanView()
                case .export: ExportView()
                case .verify: VerifyView()
                case .upload: UploadView()
                }
            }
            .safeAreaInset(edge: .bottom) {
                // One place shows each step's error, under whatever that step is showing.
                if let error = model.errors[model.step ?? .connect] {
                    ErrorText(error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(.bar)
                        .accessibilityIdentifier("step-error")
                }
            }
        }
        .onChange(of: model.errors) { old, new in
            // Errors appear away from the button that caused them, so read new ones out.
            for (step, message) in new where old[step] != message {
                AccessibilityNotification.Announcement("\(step.title) error: \(message)").post()
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
                        .accessibilityLabel("Choose Bridge certificate")
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

            HStack {
                if let status = model.status {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
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
                    Button("Choose…") { choosingFolder = true }
                        .disabled(model.isExporting)
                        .accessibilityLabel("Choose export folder")
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
                    if model.isBuildingMailboxes {
                        ProgressView().controlSize(.small).accessibilityLabel("Building Apple Mail mailboxes")
                    }
                    Button("Build Apple Mail mailboxes") { model.buildMailboxes() }
                        .disabled(model.isExporting || model.isBuildingMailboxes || !model.hasExistingExport)
                }
            } header: {
                Text("Apple Mail (optional)")
            } footer: {
                Text("Writes .mbox mailboxes to \"Apple Mail Import\" in the export folder, for File › Import Mailboxes in Mail. Uploading straight to iCloud (the Upload step) does not need this.")
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
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text(progress.message ?? progress.mailbox.map { "Scanning \($0)" } ?? "Connecting…")
                }
            }
            Text("\(ProbeFormatter.byteString(progress.downloadedBytes)) downloaded this session")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct UploadView: View {
    @Environment(AppModel.self) private var model
    @State private var password = ""
    @State private var confirming = false

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                TextField("Apple ID", text: $model.icloudUser, prompt: Text("you@icloud.com"))
                SecureField("App-specific password", text: $password,
                            prompt: Text(model.hasSavedICloudPassword ? "Saved in Keychain" : "xxxx-xxxx-xxxx-xxxx"))
                    .onSubmit { savePassword() }
            } header: {
                Text("iCloud Mail")
            } footer: {
                Text("Create an app-specific password at account.apple.com › Sign-In and Security › App-Specific Passwords. It is saved in your Keychain. Your Apple ID password is never needed.")
            }

            Section("Check first") {
                if let plan = model.uploadPlan {
                    LabeledContent("Messages to upload", value: plan.messagesToUpload.formatted())
                    LabeledContent("Size", value: ProbeFormatter.byteString(plan.bytesToUpload))
                    if let used = plan.quotaUsed, let limit = plan.quotaLimit {
                        LabeledContent("iCloud storage", value: "\(ProbeFormatter.byteString(used)) of \(ProbeFormatter.byteString(limit)) used")
                    }
                    if !plan.foldersToCreate.isEmpty {
                        LabeledContent("New folders", value: plan.foldersToCreate.joined(separator: ", "))
                    }
                    if let missing = plan.shortfall {
                        ErrorText("Not enough iCloud storage: \(ProbeFormatter.byteString(missing)) short.")
                    }
                }
                HStack {
                    if model.isPlanning { ProgressView().controlSize(.small).accessibilityLabel("Checking iCloud") }
                    Spacer()
                    Button("Check (writes nothing)") {
                        guard savePassword() else { return }
                        model.planUpload()
                    }
                    .disabled(!model.canPlanUpload)
                }
            }

            Section("Upload") {
                if let progress = model.uploadProgress, let folder = progress.folder, progress.total > 0 {
                    ProgressView(value: Double(progress.done), total: Double(progress.total)) {
                        Text(folder)
                    } currentValueLabel: {
                        Text("\(progress.done.formatted()) of \(progress.total.formatted())")
                    }
                } else if let message = model.uploadProgress?.message {
                    Text(message).foregroundStyle(.secondary)
                }
                if let summary = model.uploadSummary {
                    LabeledContent("Uploaded", value: summary.uploaded.formatted())
                    LabeledContent("Already in iCloud", value: summary.alreadyThere.formatted())
                    if summary.failed > 0 {
                        LabeledContent("Refused by iCloud (kept in \"Not uploaded\")", value: summary.failed.formatted())
                    }
                }
                HStack {
                    Spacer()
                    if model.isUploading {
                        Button("Pause") { model.pauseUpload() }
                    } else {
                        Button("Upload to iCloud…") { confirming = true }
                            .disabled(model.uploadPlan == nil || model.uploadPlan?.shortfall != nil || !model.canPlanUpload)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Upload")
        .confirmationDialog("Upload \(model.uploadPlan?.messagesToUpload ?? 0) messages to iCloud?",
                            isPresented: $confirming) {
            Button("Upload") { model.startUpload() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds mail to \(model.icloudUser). Nothing is deleted, and messages already there are skipped. You can pause and resume.")
        }
    }

    @discardableResult
    private func savePassword() -> Bool {
        guard model.saveICloudPassword(password) else { return false }
        password = ""
        return true
    }
}

/// Errors carry an icon and an "Error" label for VoiceOver, so red is never the only signal.
struct ErrorText: View {
    let message: String
    init(_ message: String) { self.message = message }

    var body: some View {
        Label {
            Text(message).textSelection(.enabled)
        } icon: {
            ErrorIcon()
        }
        .foregroundStyle(Palette.critical)
    }
}

/// The warning icon used for errors and for counts that are off, labelled for VoiceOver.
struct ErrorIcon: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(Palette.critical)
            .accessibilityLabel("Problem")
    }
}
