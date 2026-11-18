import CGtk
import Foundation
import SlopCore
import SlopLinux

@MainActor
final class ConnectPage: Page {
    let step = Step.connect
    let root: Widget
    private let session: Session
    private let window: Widget
    private let password: Widget
    private let certificateName: Widget
    private let fingerprint: Widget
    private let spinner: Widget
    private let status: Widget
    private let connectButton: Widget

    init(session: Session, window: Widget) {
        self.session = session
        self.window = window
        let form = Form()

        form.heading("Proton Mail Bridge")
        form.row("_Host", makeEntry(text: session.host) { session.host = $0 })
        let port = gtk_spin_button_new_with_range(1, 65535, 1)!
        gtk_spin_button_set_value(cast(port), Double(session.port))
        gtk_widget_set_halign(port, GTK_ALIGN_START)
        on(port, "value-changed") { session.port = Int(gtk_spin_button_get_value_as_int(cast(port))) }
        form.row("_Port", port)
        let user = makeEntry(text: session.user, placeholder: "The user name Bridge shows for your account") { session.user = $0 }
        onEvent(user, "focus-out-event") { _ in session.refreshSavedPasswords(); return false }
        form.row("_User name", user)
        form.hint("Open Bridge, choose your account, and copy the IMAP details. Slop Export only reads from Bridge.")

        form.heading("Bridge password")
        password = makeEntry(secret: true)
        form.row("Pass_word", password)
        form.hint("The password Bridge shows, not your Proton password. It is saved in your keyring, never in a file.")

        form.heading("Bridge certificate")
        certificateName = makeLabel(wrap: false)
        gtk_widget_set_hexpand(certificateName, 1)
        var chooseCert: (() -> Void)?
        let choose = makeButton("_Choose…") { chooseCert?() }
        setAccessibleName(choose, "Choose Bridge certificate")
        form.full(hbox([certificateName, choose]))
        fingerprint = makeLabel(classes: [StyleClass.dim, StyleClass.monospace], selectable: true)
        form.full(fingerprint)
        form.hint("In Bridge: Settings › Advanced settings › Export TLS certificates. "
                  + "Only a Bridge presenting this exact certificate is accepted.")

        spinner = makeSpinner(label: "Connecting")
        status = makeLabel(classes: [StyleClass.dim])
        var connect: (() -> Void)?
        connectButton = makeButton("Connect and _scan", classes: [StyleClass.suggested]) { connect?() }
        let row = buttonRow(leading: [spinner, status], trailing: [connectButton])
        gtk_widget_set_margin_top(row, 12)
        form.full(row)

        root = scrolled(form.grid)

        chooseCert = { [unowned self] in
            if let path = chooseFile(parent: window, title: "Choose the Bridge certificate", accept: "_Choose",
                                     .openFile(filters: [("Certificates", ["*.pem", "*.crt", "*.cer", "*.der"]), ("All files", ["*"])])) {
                session.importCertificate(at: path)
            }
            _ = self
        }
        connect = { [unowned self] in
            guard self.savePassword() else { return }
            Task { await session.connectAndScan() }
        }
        on(password, "activate") { [unowned self] in _ = self.savePassword() }
    }

    /// Moves the typed password into the keyring; the field is cleared only if that worked.
    private func savePassword() -> Bool {
        guard session.savePassword(entryText(password), .bridge) else { return false }
        clearEntry(password)
        return true
    }

    func refresh() {
        setText(certificateName, session.certificateName ?? "No certificate chosen")
        if session.hasCertificate { removeClass(certificateName, StyleClass.dim) } else { addClass(certificateName, StyleClass.dim) }
        setText(fingerprint, session.certificateFingerprint.map { "SHA-256 \($0)" } ?? "")
        setVisible(fingerprint, session.certificateFingerprint != nil)
        setPlaceholder(password, session.hasSavedPassword ? "Saved in your keyring" : "From Bridge, not your Proton password")
        setSpinning(spinner, session.isWorking)
        setText(status, session.status ?? "")
        setSensitive(connectButton, session.canConnect)
    }
}
