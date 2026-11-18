import CGtk
import Foundation
import SlopCore
import SlopLinux

@MainActor
final class ExportPage: Page {
    let step = Step.export
    let root: Widget
    private let session: Session
    private let folder: Widget
    private let chooseButton: Widget
    private let progress: Widget
    private let detail: Widget
    private let summary: Widget
    private let exportButton: Widget
    private let mboxSpinner: Widget
    private let mboxSummary: Widget
    private let mboxButton: Widget

    init(session: Session, window: Widget) {
        self.session = session
        let form = Form()

        form.heading("Export folder")
        folder = makeLabel(wrap: false, selectable: true)
        gtk_label_set_ellipsize(cast(folder), PANGO_ELLIPSIZE_MIDDLE)
        gtk_widget_set_hexpand(folder, 1)
        chooseButton = makeButton("_Choose…") {
            if let path = chooseFile(parent: window, title: "Choose the export folder", accept: "_Choose", .selectFolder) {
                session.chooseExportFolder(path)
            }
        }
        setAccessibleName(chooseButton, "Choose export folder")
        form.full(hbox([folder, chooseButton]))
        form.hint("Needs room for all of your mail. The app keeps its progress here, so you can quit and carry on later.")

        form.heading("Download from Bridge")
        progress = gtk_progress_bar_new()!
        gtk_progress_bar_set_show_text(cast(progress), 1)
        setAccessibleName(progress, "Export progress")
        form.full(progress)
        detail = makeLabel(classes: [StyleClass.dim])
        form.full(detail)
        summary = makeLabel(selectable: true)
        form.full(summary)
        exportButton = makeButton("_Start export", classes: [StyleClass.suggested]) {
            if session.isExporting { session.pauseExport() } else { session.startExport() }
        }
        form.full(buttonRow(trailing: [exportButton]))

        form.heading("Apple Mail mailboxes (optional)")
        form.hint("Writes .mbox mailboxes to \"Apple Mail Import\" in the export folder, for File › Import Mailboxes "
                  + "in Mail on a Mac. Uploading straight to iCloud (the Upload step) does not need this.")
        mboxSpinner = makeSpinner(label: "Building Apple Mail mailboxes")
        mboxSummary = makeLabel()
        mboxButton = makeButton("_Build Apple Mail mailboxes") { session.buildMailboxes() }
        form.full(buttonRow(leading: [mboxSpinner, mboxSummary], trailing: [mboxButton]))

        root = scrolled(form.grid)
    }

    func refresh() {
        setText(folder, session.exportFolder ?? "No folder chosen")
        setSensitive(chooseButton, session.canChooseExportFolder)

        let p = session.exportProgress
        setVisible(progress, p != nil)
        if let p {
            switch p.phase {
            case .downloading where p.total > 0:
                gtk_progress_bar_set_fraction(cast(progress), Double(p.done) / Double(p.total))
                gtk_progress_bar_set_text(cast(progress), "\(p.mailbox ?? ""): \(p.done.formatted()) of \(p.total.formatted())")
            case .done:
                gtk_progress_bar_set_fraction(cast(progress), 1)
                gtk_progress_bar_set_text(cast(progress), "Export complete")
            default:
                gtk_progress_bar_pulse(cast(progress))
                gtk_progress_bar_set_text(cast(progress), p.message ?? p.mailbox.map { "Scanning \($0)" } ?? "Connecting…")
            }
            setText(detail, "\(ProbeFormatter.byteString(p.downloadedBytes)) downloaded this session")
        } else {
            setText(detail, "")
        }
        if let s = session.exportSummary {
            setText(summary, "Messages exported: \(s.distinctMessages.formatted())\n"
                    + "Only in All Mail (go to Unfiled): \(s.unfiled.formatted())")
        } else {
            setText(summary, "")
        }
        setVisible(summary, session.exportSummary != nil)

        if session.isExporting {
            setButtonTitle(exportButton, "_Pause")
            setSensitive(exportButton, true)
        } else {
            setButtonTitle(exportButton, session.hasExistingExport ? "_Resume export" : "_Start export")
            setSensitive(exportButton, session.canExport)
        }

        setSpinning(mboxSpinner, session.isBuildingMailboxes)
        if let r = session.mboxResult {
            setText(mboxSummary, "\(r.mailboxes.count.formatted()) mailboxes, \(r.messages.formatted()) messages written")
        } else {
            setText(mboxSummary, "")
        }
        setSensitive(mboxButton, !session.isExporting && !session.isBuildingMailboxes && session.hasExistingExport)
    }
}
