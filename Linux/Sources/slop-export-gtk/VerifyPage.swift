import CGtk
import Foundation
import SlopCore
import SlopLinux

@MainActor
final class VerifyPage: Page {
    let step = Step.verify
    let root: Widget
    private let session: Session
    private let bridgeCheck: Widget
    private let icloudCheck: Widget
    private let spinner: Widget
    private let verifyButton: Widget
    private let empty: Widget
    private let result: Widget
    private let headline: Widget
    private let problems: Widget
    private let stats: Widget
    private let details: Widget
    private let saveRow: Widget
    private let table = Table([.text("Folder"), .text("Expected", numeric: true), .text("Apple Mail", numeric: true),
                               .progress("In iCloud"), .text("Missing", numeric: true)],
                              accessibleName: "Messages per folder")

    init(session: Session, window: Widget) {
        self.session = session
        let form = Form()

        bridgeCheck = gtk_check_button_new_with_mnemonic("Compare with _Bridge's live counts")!
        icloudCheck = gtk_check_button_new_with_mnemonic("Compare with _iCloud Mail")!
        gtk_toggle_button_set_active(cast(bridgeCheck), session.verifyBridge ? 1 : 0)
        gtk_toggle_button_set_active(cast(icloudCheck), session.verifyICloud ? 1 : 0)
        let bridge = bridgeCheck, icloud = icloudCheck
        on(bridge, "toggled") { session.verifyBridge = gtk_toggle_button_get_active(cast(bridge)) != 0 }
        on(icloud, "toggled") { session.verifyICloud = gtk_toggle_button_get_active(cast(icloud)) != 0 }
        form.full(bridgeCheck)
        form.full(icloudCheck)
        form.hint("Only reads. Without Bridge, the counts from the last export scan are used. "
                  + "The Apple Mail folders are checked when they have been built.")
        spinner = makeSpinner(label: "Verifying")
        verifyButton = makeButton("_Verify", classes: [StyleClass.suggested]) { session.runVerify() }
        form.full(buttonRow(leading: [spinner], trailing: [verifyButton]))

        empty = makeLabel("No export yet. Run the Export step first.", classes: [StyleClass.dim])
        form.full(empty)

        result = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10)!
        headline = makeLabel(classes: [StyleClass.big])
        problems = makeLabel(selectable: true)
        stats = makeLabel(selectable: true)
        details = makeLabel(classes: [StyleClass.monospace], selectable: true)
        for child in [headline, problems, stats, table.container, details] {
            gtk_box_pack_start(cast(result), child, child == table.container ? 1 : 0, 1, 0)
        }
        let saveHTML = makeButton("Save as _HTML…") {
            if let path = chooseFile(parent: window, title: "Save the verify report", accept: "_Save",
                                     .save(suggestedName: "slop-export verify report.html")) {
                session.saveReport(.html, to: path)
            }
        }
        let saveText = makeButton("Save as _Text…") {
            if let path = chooseFile(parent: window, title: "Save the verify report", accept: "_Save",
                                     .save(suggestedName: "slop-export verify report.txt")) {
                session.saveReport(.text, to: path)
            }
        }
        saveRow = buttonRow(trailing: [saveHTML, saveText])
        gtk_box_pack_start(cast(result), saveRow, 0, 0, 0)
        form.full(result)

        root = scrolled(form.grid)
    }

    func refresh() {
        setSensitive(bridgeCheck, session.canVerifyBridge)
        setSensitive(icloudCheck, session.canVerifyICloud)
        setSpinning(spinner, session.isVerifying)
        setSensitive(verifyButton, session.canVerify)
        setVisible(empty, !session.hasExistingExport && session.verifyReport == nil)

        guard let report = session.verifyReport else {
            setVisible(result, false)
            return
        }
        setVisible(result, true)
        // Pass/fail in words with a symbol, never colour alone.
        setText(headline, report.passed ? "✔ Everything is accounted for" : "✖ Something is missing")
        removeClass(headline, report.passed ? StyleClass.error : StyleClass.good)
        addClass(headline, report.passed ? StyleClass.good : StyleClass.error)
        let problemLines = VerifyFormatter.problems(report)
        setText(problems, problemLines.joined(separator: "\n"))
        setVisible(problems, !problemLines.isEmpty)

        var tiles = ["All Mail on Bridge: \(report.allMailCount.map { $0.formatted() } ?? "–")",
                     "All Mail in the store: \(report.allMailAccountedFor.formatted())",
                     "Distinct messages: \(report.distinctMessages.formatted())"]
        if report.icloudComplete != nil {
            tiles.append("Missing in iCloud: \(report.targets.reduce(0) { $0 + $1.missingInICloud.count }.formatted())")
        }
        setText(stats, tiles.joined(separator: "     "))

        table.setRows(report.targets.map { row in
            let found = row.expected - row.missingInICloud.count
            let percent = row.icloud == nil || row.expected == 0 ? (row.icloud == nil ? 0 : 100) : found * 100 / row.expected
            let warn = "⚠ "
            return [row.folder, row.expected.formatted(),
                    row.mbox.map { ($0 != row.expected ? warn : "") + $0.formatted() } ?? "–",
                    String(percent), row.icloud == nil ? "not checked" : "\(found.formatted()) of \(row.expected.formatted())",
                    row.icloud == nil ? "–" : (row.missingInICloud.isEmpty ? "0" : warn + row.missingInICloud.count.formatted())]
        })

        var lines: [String] = []
        let missing = report.targets.flatMap { row in row.missingInICloud.map { (row.folder, $0) } }
        if !missing.isEmpty {
            lines.append("Missing in iCloud")
            lines += missing.map { "  \($0.0): \($0.1.messageID ?? "(no Message-ID)")" }
        }
        if !report.skipped.isEmpty {
            lines.append("Skipped on Bridge")
            lines += report.skipped.map { "  \($0.mailbox) UID \($0.uid): \($0.reason)" }
        }
        setText(details, lines.joined(separator: "\n"))
        setVisible(details, !lines.isEmpty)
    }
}
