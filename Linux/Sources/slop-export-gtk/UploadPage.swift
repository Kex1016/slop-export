import CGtk
import Foundation
import SlopCore
import SlopLinux

@MainActor
final class UploadPage: Page {
    let step = Step.upload
    let root: Widget
    private let session: Session
    private let window: Widget
    private let password: Widget
    private let planSpinner: Widget
    private let planSummary: Widget
    private let planButton: Widget
    private let progress: Widget
    private let message: Widget
    private let summary: Widget
    private let uploadButton: Widget

    init(session: Session, window: Widget) {
        self.session = session
        self.window = window
        let form = Form()

        form.heading("iCloud Mail")
        let user = makeEntry(text: session.icloudUser, placeholder: "you@icloud.com") { session.icloudUser = $0 }
        onEvent(user, "focus-out-event") { _ in session.refreshSavedPasswords(); return false }
        form.row("_Apple ID", user)
        password = makeEntry(secret: true)
        form.row("App-specific _password", password)
        form.hint("Create an app-specific password at account.apple.com › Sign-In and Security › App-Specific Passwords. "
                  + "It is saved in your keyring. Your Apple ID password is never needed.")

        form.heading("Check first")
        planSpinner = makeSpinner(label: "Checking iCloud")
        planSummary = makeLabel(selectable: true)
        var plan: (() -> Void)?
        planButton = makeButton("_Check (writes nothing)") { plan?() }
        form.full(planSummary)
        form.full(buttonRow(leading: [planSpinner], trailing: [planButton]))

        form.heading("Upload")
        progress = gtk_progress_bar_new()!
        gtk_progress_bar_set_show_text(cast(progress), 1)
        setAccessibleName(progress, "Upload progress")
        form.full(progress)
        message = makeLabel(classes: [StyleClass.dim])
        form.full(message)
        summary = makeLabel(selectable: true)
        form.full(summary)
        var upload: (() -> Void)?
        uploadButton = makeButton("_Upload to iCloud…", classes: [StyleClass.suggested]) { upload?() }
        form.full(buttonRow(trailing: [uploadButton]))

        root = scrolled(form.grid)

        plan = { [unowned self] in
            guard self.savePassword() else { return }
            session.planUpload()
        }
        upload = { [unowned self] in
            if session.isUploading { session.pauseUpload(); return }
            guard let count = session.uploadPlan?.messagesToUpload else { return }
            let ok = confirm(parent: self.window, title: "Upload \(count.formatted()) messages to iCloud?",
                             message: "This adds mail to \(session.icloudAccount). Nothing is deleted, and messages "
                                 + "already there are skipped. You can pause and resume.",
                             action: "_Upload")
            if ok { session.startUpload() }
        }
        on(password, "activate") { [unowned self] in _ = self.savePassword() }
    }

    private func savePassword() -> Bool {
        guard session.savePassword(entryText(password), .icloud) else { return false }
        clearEntry(password)
        return true
    }

    func refresh() {
        setPlaceholder(password, session.hasSavedICloudPassword ? "Saved in your keyring" : "xxxx-xxxx-xxxx-xxxx")
        setSpinning(planSpinner, session.isPlanning)
        setSensitive(planButton, session.canPlanUpload)
        if let plan = session.uploadPlan {
            var lines = ["Messages to upload: \(plan.messagesToUpload.formatted())",
                         "Size: \(ProbeFormatter.byteString(plan.bytesToUpload))"]
            if let used = plan.quotaUsed, let limit = plan.quotaLimit {
                lines.append("iCloud storage: \(ProbeFormatter.byteString(used)) of \(ProbeFormatter.byteString(limit)) used")
            }
            if !plan.foldersToCreate.isEmpty { lines.append("New folders: \(plan.foldersToCreate.joined(separator: ", "))") }
            if let short = plan.shortfall { lines.append("⚠ Not enough iCloud storage: \(ProbeFormatter.byteString(short)) short.") }
            setText(planSummary, lines.joined(separator: "\n"))
        } else {
            setText(planSummary, session.hasExistingExport ? "" : "Export your mail first (the Export step).")
        }

        if let p = session.uploadProgress, let folder = p.folder, p.total > 0 {
            setVisible(progress, true)
            gtk_progress_bar_set_fraction(cast(progress), Double(p.done) / Double(p.total))
            gtk_progress_bar_set_text(cast(progress), "\(p.done.formatted()) of \(p.total.formatted()) messages (now \(folder))")
        } else {
            setVisible(progress, false)
        }
        setText(message, session.uploadProgress?.message ?? "")
        if let s = session.uploadSummary {
            var lines = ["Uploaded: \(s.uploaded.formatted())", "Already in iCloud: \(s.alreadyThere.formatted())"]
            if s.failed > 0 { lines.append("Refused by iCloud (kept in \"Not uploaded\"): \(s.failed.formatted())") }
            setText(summary, lines.joined(separator: "\n"))
        } else {
            setText(summary, "")
        }

        if session.isUploading {
            setButtonTitle(uploadButton, "_Pause")
            setSensitive(uploadButton, true)
        } else {
            setButtonTitle(uploadButton, "_Upload to iCloud…")
            setSensitive(uploadButton, session.canUpload)
        }
    }
}
