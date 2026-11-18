import CGtk
import Foundation
import SlopCore
import SlopLinux

/// The Linux app's window: a sidebar with the five steps and one page per step, the same flow
/// and wording as the macOS app. It holds no logic of its own: it draws `Session` and calls it.
@MainActor
final class MainWindow {
    let window: Widget
    private let session: Session
    private let stack: Widget
    private let headerBar: Widget
    private let errorBar: Widget
    private let errorLabel: Widget
    private var refreshScheduled = false
    private var pages: [Step: Page] = [:]

    init(application: UnsafeMutablePointer<GtkApplication>, session: Session) {
        self.session = session
        window = gtk_application_window_new(application)!
        gtk_window_set_default_size(cast(window), 920, 660)
        gtk_window_set_icon_name(cast(window), "mail-send-receive")

        headerBar = gtk_header_bar_new()!
        gtk_header_bar_set_show_close_button(cast(headerBar), 1)
        gtk_header_bar_set_title(cast(headerBar), "Slop Export")
        gtk_window_set_titlebar(cast(window), headerBar)

        stack = gtk_stack_new()!
        gtk_stack_set_transition_type(cast(stack), GTK_STACK_TRANSITION_TYPE_CROSSFADE)
        gtk_widget_set_hexpand(stack, 1)
        gtk_widget_set_vexpand(stack, 1)

        let sidebar = gtk_stack_sidebar_new()!
        gtk_stack_sidebar_set_stack(cast(sidebar), cast(stack))
        gtk_widget_set_size_request(sidebar, 160, -1)
        setAccessibleName(sidebar, "Steps")

        // One bar shows the current step's last error, under whatever that step shows (D-014).
        errorBar = gtk_info_bar_new()!
        gtk_info_bar_set_message_type(cast(errorBar), GTK_MESSAGE_ERROR)
        errorLabel = makeLabel(selectable: true)
        let icon = gtk_image_new_from_icon_name("dialog-warning-symbolic", GTK_ICON_SIZE_BUTTON)!
        setAccessibleName(icon, "Problem")
        let content = gtk_info_bar_get_content_area(cast(errorBar))!
        gtk_container_add(cast(content), hbox([icon, errorLabel]))
        gtk_widget_set_hexpand(errorLabel, 1)
        gtk_widget_set_no_show_all(errorBar, 1)

        let right = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_pack_start(cast(right), stack, 1, 1, 0)
        gtk_box_pack_end(cast(right), errorBar, 0, 0, 0)

        let main = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        gtk_box_pack_start(cast(main), sidebar, 0, 0, 0)
        gtk_box_pack_start(cast(main), gtk_separator_new(GTK_ORIENTATION_VERTICAL), 0, 0, 0)
        gtk_box_pack_start(cast(main), right, 1, 1, 0)
        gtk_container_add(cast(window), main)

        let built: [Page] = [
            ConnectPage(session: session, window: window),
            ScanPage(session: session),
            ExportPage(session: session, window: window),
            VerifyPage(session: session, window: window),
            UploadPage(session: session, window: window),
        ]
        for page in built {
            pages[page.step] = page
            gtk_stack_add_titled(cast(stack), page.root, page.step.rawValue, page.step.title)
        }

        onNotify(stack, "visible-child-name") { [weak self] in self?.stackChanged() }
        onEvent(window, "key-press-event") { [weak self] event in self?.keyPressed(event) ?? false }

        session.onChange = { [weak self] in self?.scheduleRefresh() }
    }

    func show() {
        gtk_widget_show_all(window)
        refresh()
        gtk_window_present(cast(window))
    }

    private func stackChanged() {
        guard let name = gtk_stack_get_visible_child_name(cast(stack)),
              let step = Step(rawValue: String(cString: name)), step != session.step else { return }
        session.step = step
        session.refreshSavedPasswords()
    }

    /// Ctrl+1 to Ctrl+5 jump between steps (Command-1 to Command-5 on the Mac).
    private func keyPressed(_ event: UnsafeMutablePointer<GdkEvent>) -> Bool {
        let key = event.pointee.key
        guard key.state & GDK_CONTROL_MASK.rawValue != 0 else { return false }
        let steps = Step.allCases
        let index = Int(key.keyval) - Int(GDK_KEY_1)
        if steps.indices.contains(index) {
            session.step = steps[index]
            return true
        }
        if key.keyval == UInt32(GDK_KEY_q) {
            gtk_window_close(cast(window))
            return true
        }
        return false
    }

    /// Many changes arrive in a burst (progress, flags); redraw once per main-loop turn.
    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        Task { @MainActor [weak self] in
            self?.refreshScheduled = false
            self?.refresh()
        }
    }

    private func refresh() {
        let step = session.step
        let visible = gtk_stack_get_visible_child_name(cast(stack)).map { String(cString: $0) }
        if visible != step.rawValue { gtk_stack_set_visible_child_name(cast(stack), step.rawValue) }
        gtk_header_bar_set_subtitle(cast(headerBar), step.title)
        if let error = session.errors[step] {
            setText(errorLabel, error)
            gtk_widget_show_all(errorBar)
            setVisible(errorBar, true)
        } else {
            setVisible(errorBar, false)
        }
        for page in pages.values { page.refresh() }
    }
}
