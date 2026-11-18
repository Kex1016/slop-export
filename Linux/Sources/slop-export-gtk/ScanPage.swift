import CGtk
import Foundation
import SlopCore
import SlopLinux

@MainActor
final class ScanPage: Page {
    let step = Step.scan
    let root: Widget
    private let session: Session
    private let summary: Widget
    private let empty: Widget
    private let table = Table([.text("Mailbox"), .text("Messages", numeric: true), .text("Size", numeric: true), .text("Plan")],
                              accessibleName: "Bridge mailboxes")

    init(session: Session) {
        self.session = session
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 12)!
        gtk_container_set_border_width(cast(box), 20)
        empty = makeLabel("Not scanned yet. Connect to Bridge first.", classes: [StyleClass.dim])
        summary = makeLabel(selectable: true)
        gtk_box_pack_start(cast(box), empty, 0, 0, 0)
        gtk_box_pack_start(cast(box), summary, 0, 0, 0)
        gtk_box_pack_start(cast(box), table.container, 1, 1, 0)
        gtk_box_pack_start(cast(box), makeLabel("Mailboxes under Labels/ are skipped on purpose; only folders are copied.",
                                                classes: [StyleClass.dim]), 0, 0, 0)
        root = box
    }

    func refresh() {
        guard let report = session.report else {
            setVisible(empty, true)
            setVisible(summary, false)
            setVisible(table.container, false)
            return
        }
        setVisible(empty, false)
        setVisible(summary, true)
        setVisible(table.container, true)
        var parts = ["Messages to export: \(report.exportedMessageCount.formatted())"]
        if let all = report.allMailCount { parts.append("All Mail: \(all.formatted())") }
        if let name = report.server["name"] {
            parts.append("Server: " + [name, report.server["version"]].compactMap { $0 }.joined(separator: " "))
        }
        setText(summary, parts.joined(separator: "     "))
        table.setRows(report.mailboxes.map { box in
            [box.path, box.messages.map { $0.formatted() } ?? "–", box.size.map(ProbeFormatter.byteString) ?? "–",
             ProbeFormatter.describe(box.role)]
        })
    }
}
