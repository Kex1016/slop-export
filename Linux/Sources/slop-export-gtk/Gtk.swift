import CGtk
import Foundation

// Small, typed helpers over the GTK 3 C API. Everything here runs on GTK's (main) thread.

typealias Widget = UnsafeMutablePointer<GtkWidget>

/// Reinterprets a GObject pointer as another GTK type (the C casting macros are not imported).
func cast<T, U>(_ pointer: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutablePointer<T>(OpaquePointer(pointer))
}

/// For GTK interface types (GtkTreeModel, GtkFileChooser, ...), which Swift sees as opaque.
func opaque<U>(_ pointer: UnsafeMutablePointer<U>) -> OpaquePointer {
    OpaquePointer(pointer)
}

/// Holds a Swift closure for the lifetime of a signal connection.
private final class Handler: @unchecked Sendable {
    let simple: (@MainActor () -> Void)?
    let event: (@MainActor (UnsafeMutablePointer<GdkEvent>) -> Bool)?
    init(simple: (@MainActor () -> Void)? = nil, event: (@MainActor (UnsafeMutablePointer<GdkEvent>) -> Bool)? = nil) {
        self.simple = simple
        self.event = event
    }
}

private let releaseHandler: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<Handler>.fromOpaque(data).release()
}

/// Signals with the shape (instance, user_data): clicked, changed, toggled, value-changed, activate.
private let twoArgument: @convention(c) (gpointer?, gpointer?) -> Void = { _, data in
    guard let data else { return }
    let handler = Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { handler.simple?() }
}

/// Signals with the shape (instance, argument, user_data): notify::*, GAction activate.
private let threeArgument: @convention(c) (gpointer?, gpointer?, gpointer?) -> Void = { _, _, data in
    guard let data else { return }
    let handler = Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue()
    MainActor.assumeIsolated { handler.simple?() }
}

/// Event signals (instance, GdkEvent*, user_data) -> gboolean: key-press-event, focus-out-event.
private let eventCallback: @convention(c) (gpointer?, UnsafeMutablePointer<GdkEvent>?, gpointer?) -> gboolean = { _, event, data in
    guard let data, let event else { return 0 }
    nonisolated(unsafe) let gdkEvent = event  // GTK delivers events on its own (main) thread
    let handler = Unmanaged<Handler>.fromOpaque(data).takeUnretainedValue()
    return MainActor.assumeIsolated { handler.event?(gdkEvent) ?? false } ? 1 : 0
}

@MainActor
func on<T>(_ instance: UnsafeMutablePointer<T>, _ signal: String, _ body: @escaping @MainActor () -> Void) {
    let data = Unmanaged.passRetained(Handler(simple: body)).toOpaque()
    slop_signal_connect(instance, signal, unsafeBitCast(twoArgument, to: GCallback.self), data, releaseHandler)
}

@MainActor
func onNotify<T>(_ instance: UnsafeMutablePointer<T>, _ property: String, _ body: @escaping @MainActor () -> Void) {
    let data = Unmanaged.passRetained(Handler(simple: body)).toOpaque()
    slop_signal_connect(instance, "notify::\(property)", unsafeBitCast(threeArgument, to: GCallback.self), data, releaseHandler)
}

/// Return true to stop other handlers (the event was handled).
@MainActor
func onEvent<T>(_ instance: UnsafeMutablePointer<T>, _ signal: String,
                _ body: @escaping @MainActor (UnsafeMutablePointer<GdkEvent>) -> Bool) {
    let data = Unmanaged.passRetained(Handler(event: body)).toOpaque()
    slop_signal_connect(instance, signal, unsafeBitCast(eventCallback, to: GCallback.self), data, releaseHandler)
}

/// Runs Swift's main actor on GTK's main loop: libdispatch signals a file descriptor when the
/// main queue has work, the same hook CoreFoundation's run loop uses on Linux. Without this,
/// `Task { @MainActor in }` work would never run while `gtk_main` blocks the main thread.
enum MainQueueBridge {
    static func install() {
        let fd = _dispatch_get_main_queue_handle_4CF()
        _ = g_unix_fd_add(fd, G_IO_IN, { fd, _, _ in
            var counter: UInt64 = 0
            _ = read(fd, &counter, MemoryLayout<UInt64>.size)  // eventfd: reset before draining
            _dispatch_main_queue_callback_4CF(nil)
            return 1  // G_SOURCE_CONTINUE
        }, nil)
    }
}

// MARK: Widgets

enum StyleClass {
    static let dim = "dim-label"
    static let suggested = "suggested-action"
    static let destructive = "destructive-action"
    static let monospace = "monospace"
    static let heading = "slop-heading"
    static let error = "slop-error"
    static let good = "slop-good"
    static let big = "slop-big"
}

@MainActor
func addClass(_ widget: Widget, _ name: String) {
    gtk_style_context_add_class(gtk_widget_get_style_context(widget), name)
}

@MainActor
func removeClass(_ widget: Widget, _ name: String) {
    gtk_style_context_remove_class(gtk_widget_get_style_context(widget), name)
}

@MainActor
func makeLabel(_ text: String = "", classes: [String] = [], wrap: Bool = true, selectable: Bool = false) -> Widget {
    let label = gtk_label_new(text)!
    let l: UnsafeMutablePointer<GtkLabel> = cast(label)
    gtk_label_set_xalign(l, 0)
    gtk_label_set_line_wrap(l, wrap ? 1 : 0)
    if wrap { gtk_label_set_line_wrap_mode(l, PANGO_WRAP_WORD_CHAR) }
    gtk_label_set_selectable(l, selectable ? 1 : 0)
    for name in classes { addClass(label, name) }
    return label
}

@MainActor
func setText(_ label: Widget, _ text: String) {
    let l: UnsafeMutablePointer<GtkLabel> = cast(label)
    if String(cString: gtk_label_get_text(l)) != text { gtk_label_set_text(l, text) }
}

@MainActor
func makeButton(_ title: String, classes: [String] = [], _ action: @escaping @MainActor () -> Void) -> Widget {
    let button = gtk_button_new_with_mnemonic(title)!
    for name in classes { addClass(button, name) }
    on(button, "clicked", action)
    return button
}

@MainActor
func setButtonTitle(_ button: Widget, _ title: String) {
    let b: UnsafeMutablePointer<GtkButton> = cast(button)
    if String(cString: gtk_button_get_label(b)) != title { gtk_button_set_label(b, title) }
}

@MainActor
func makeEntry(text: String = "", placeholder: String = "", secret: Bool = false,
               onChange: (@MainActor (String) -> Void)? = nil) -> Widget {
    let entry = gtk_entry_new()!
    let e: UnsafeMutablePointer<GtkEntry> = cast(entry)
    gtk_entry_set_text(e, text)
    gtk_entry_set_placeholder_text(e, placeholder)
    gtk_widget_set_hexpand(entry, 1)
    if secret {
        gtk_entry_set_visibility(e, 0)
        gtk_entry_set_input_purpose(e, GTK_INPUT_PURPOSE_PASSWORD)
    }
    if let onChange {
        on(entry, "changed") { onChange(entryText(entry)) }
    }
    return entry
}

@MainActor
func entryText(_ entry: Widget) -> String {
    String(cString: gtk_entry_get_text(cast(entry)))
}

@MainActor
func setPlaceholder(_ entry: Widget, _ text: String) {
    gtk_entry_set_placeholder_text(cast(entry), text)
}

@MainActor
func clearEntry(_ entry: Widget) {
    gtk_entry_set_text(cast(entry), "")
}

@MainActor
func setSensitive(_ widget: Widget, _ on: Bool) {
    if (gtk_widget_get_sensitive(widget) != 0) != on { gtk_widget_set_sensitive(widget, on ? 1 : 0) }
}

@MainActor
func setVisible(_ widget: Widget, _ on: Bool) {
    if (gtk_widget_get_visible(widget) != 0) != on { gtk_widget_set_visible(widget, on ? 1 : 0) }
}

@MainActor
func setSpinning(_ spinner: Widget, _ on: Bool) {
    setVisible(spinner, on)
    if on { gtk_spinner_start(cast(spinner)) } else { gtk_spinner_stop(cast(spinner)) }
}

@MainActor
func makeSpinner(label: String) -> Widget {
    let spinner = gtk_spinner_new()!
    setAccessibleName(spinner, label)
    gtk_widget_set_no_show_all(spinner, 1)
    return spinner
}

@MainActor
func setAccessibleName(_ widget: Widget, _ name: String) {
    if let accessible = gtk_widget_get_accessible(widget) { atk_object_set_name(accessible, name) }
}

@MainActor
func hbox(_ children: [Widget], spacing: Int32 = 8) -> Widget {
    let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing)!
    for child in children { gtk_box_pack_start(cast(box), child, gtk_widget_get_hexpand(child), 1, 0) }
    return box
}

/// A row whose last children sit at the right edge, like a dialog's button row.
@MainActor
func buttonRow(leading: [Widget] = [], trailing: [Widget]) -> Widget {
    let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8)!
    for child in leading { gtk_box_pack_start(cast(box), child, 0, 0, 0) }
    for child in trailing.reversed() { gtk_box_pack_end(cast(box), child, 0, 0, 0) }
    return box
}

/// A two-column form: headings and hints span both columns, labelled rows put the label left.
@MainActor
final class Form {
    let grid: Widget
    private var row: Int32 = 0

    init() {
        grid = gtk_grid_new()!
        let g: UnsafeMutablePointer<GtkGrid> = cast(grid)
        gtk_grid_set_column_spacing(g, 12)
        gtk_grid_set_row_spacing(g, 8)
        gtk_widget_set_margin_start(grid, 24)
        gtk_widget_set_margin_end(grid, 24)
        gtk_widget_set_margin_top(grid, 20)
        gtk_widget_set_margin_bottom(grid, 20)
    }

    private var g: UnsafeMutablePointer<GtkGrid> { cast(grid) }

    func heading(_ text: String) {
        let label = makeLabel(text, classes: [StyleClass.heading], wrap: false)
        if row > 0 { gtk_widget_set_margin_top(label, 12) }
        full(label)
    }

    func hint(_ text: String) {
        full(makeLabel(text, classes: [StyleClass.dim]))
    }

    /// `title` may hold a mnemonic (`_Host`); it becomes the widget's accessible label too.
    func row(_ title: String, _ widget: Widget) {
        let label = gtk_label_new_with_mnemonic(title)!
        gtk_label_set_xalign(cast(label), 1)
        gtk_label_set_mnemonic_widget(cast(label), widget)
        gtk_grid_attach(g, label, 0, row, 1, 1)
        gtk_grid_attach(g, widget, 1, row, 1, 1)
        row += 1
    }

    func full(_ widget: Widget) {
        gtk_widget_set_hexpand(widget, 1)
        gtk_grid_attach(g, widget, 0, row, 2, 1)
        row += 1
    }
}

/// A scrollable page for the stack.
@MainActor
func scrolled(_ child: Widget) -> Widget {
    let window = gtk_scrolled_window_new(nil, nil)!
    gtk_scrolled_window_set_policy(cast(window), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
    gtk_container_add(cast(window), child)
    return window
}

// MARK: Tables

/// A read-only table backed by a GtkListStore of strings, with optional progress columns.
@MainActor
final class Table {
    enum Column {
        case text(String, numeric: Bool = false)
        /// Two store columns: an int (0-100) and its caption.
        case progress(String)
    }

    let view: Widget
    let container: Widget
    private let store: UnsafeMutablePointer<GtkListStore>
    private let layout: [Column]
    private var rows: [[String]] = []

    private static let stringType = g_type_from_name("gchararray")
    private static let intType = g_type_from_name("gint")

    init(_ columns: [Column], accessibleName: String) {
        layout = columns
        var types: [GType] = []
        for column in columns {
            switch column {
            case .text: types.append(Self.stringType)
            case .progress: types.append(contentsOf: [Self.intType, Self.stringType])
            }
        }
        store = types.withUnsafeMutableBufferPointer { gtk_list_store_newv(Int32($0.count), $0.baseAddress) }
        view = gtk_tree_view_new_with_model(opaque(store))!
        g_object_unref(store)  // the view holds it
        let tree: UnsafeMutablePointer<GtkTreeView> = cast(view)
        gtk_tree_view_set_enable_search(tree, 1)
        setAccessibleName(view, accessibleName)

        var index: Int32 = 0
        for column in columns {
            let col = gtk_tree_view_column_new()!
            switch column {
            case .text(let title, let numeric):
                gtk_tree_view_column_set_title(col, title)
                let renderer = gtk_cell_renderer_text_new()!
                if numeric { Self.setFloat(renderer, "xalign", 1) }
                gtk_tree_view_column_pack_start(col, renderer, 1)
                gtk_tree_view_column_add_attribute(col, renderer, "text", index)
                gtk_tree_view_column_set_resizable(col, 1)
                if !numeric { gtk_tree_view_column_set_expand(col, 1) }
                index += 1
            case .progress(let title):
                gtk_tree_view_column_set_title(col, title)
                let renderer = gtk_cell_renderer_progress_new()!
                gtk_tree_view_column_pack_start(col, renderer, 1)
                gtk_tree_view_column_add_attribute(col, renderer, "value", index)
                gtk_tree_view_column_add_attribute(col, renderer, "text", index + 1)
                gtk_tree_view_column_set_min_width(col, 140)
                index += 2
            }
            gtk_tree_view_append_column(tree, col)
        }

        container = gtk_scrolled_window_new(nil, nil)!
        gtk_scrolled_window_set_policy(cast(container), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_shadow_type(cast(container), GTK_SHADOW_IN)
        gtk_scrolled_window_set_min_content_height(cast(container), 220)
        gtk_widget_set_vexpand(container, 1)
        gtk_container_add(cast(container), view)
    }

    private static func setFloat(_ object: UnsafeMutablePointer<GtkCellRenderer>, _ name: String, _ value: Float) {
        var v = GValue()
        g_value_init(&v, g_type_from_name("gfloat"))
        g_value_set_float(&v, value)
        g_object_set_property(cast(object), name, &v)
        g_value_unset(&v)
    }

    /// Each row has one string per store column; a progress column takes its percentage as a
    /// decimal string followed by its caption.
    func setRows(_ newRows: [[String]]) {
        guard newRows != rows else { return }
        rows = newRows
        gtk_list_store_clear(store)
        for row in newRows {
            var iter = GtkTreeIter()
            gtk_list_store_append(store, &iter)
            var column: Int32 = 0
            for (offset, cell) in row.enumerated() {
                var v = GValue()
                if isIntColumn(offset) {
                    g_value_init(&v, Self.intType)
                    g_value_set_int(&v, Int32(cell) ?? 0)
                } else {
                    g_value_init(&v, Self.stringType)
                    g_value_set_string(&v, cell)
                }
                gtk_list_store_set_value(store, &iter, column, &v)
                g_value_unset(&v)
                column += 1
            }
        }
    }

    private func isIntColumn(_ storeColumn: Int) -> Bool {
        var index = 0
        for column in layout {
            switch column {
            case .text: index += 1
            case .progress:
                if storeColumn == index { return true }
                index += 2
            }
            if index > storeColumn { return false }
        }
        return false
    }
}

// MARK: Dialogs

enum FileChoice {
    case openFile(filters: [(name: String, patterns: [String])])
    case selectFolder
    case save(suggestedName: String)
}

/// Native file chooser (uses the desktop portal where there is one). Returns the chosen path.
@MainActor
func chooseFile(parent: Widget, title: String, accept: String, _ kind: FileChoice) -> String? {
    let action: GtkFileChooserAction
    switch kind {
    case .openFile: action = GTK_FILE_CHOOSER_ACTION_OPEN
    case .selectFolder: action = GTK_FILE_CHOOSER_ACTION_SELECT_FOLDER
    case .save: action = GTK_FILE_CHOOSER_ACTION_SAVE
    }
    guard let native = gtk_file_chooser_native_new(title, cast(parent), action, accept, "_Cancel") else { return nil }
    defer { g_object_unref(UnsafeMutableRawPointer(native)) }
    let chooser = native
    switch kind {
    case .openFile(let filters):
        for filter in filters {
            let f = gtk_file_filter_new()!
            gtk_file_filter_set_name(f, filter.name)
            for pattern in filter.patterns { gtk_file_filter_add_pattern(f, pattern) }
            gtk_file_chooser_add_filter(chooser, f)
        }
    case .selectFolder:
        gtk_file_chooser_set_create_folders(chooser, 1)
    case .save(let name):
        gtk_file_chooser_set_do_overwrite_confirmation(chooser, 1)
        gtk_file_chooser_set_current_name(chooser, name)
    }
    guard gtk_native_dialog_run(UnsafeMutablePointer(native)) == GTK_RESPONSE_ACCEPT.rawValue,
          let file = gtk_file_chooser_get_filename(chooser) else { return nil }
    defer { g_free(file) }
    return String(cString: file)
}

/// A modal question with a cancel button (the default) and one action button.
@MainActor
func confirm(parent: Widget, title: String, message: String, action: String, destructive: Bool = false) -> Bool {
    let dialog = gtk_dialog_new()!
    let d: UnsafeMutablePointer<GtkDialog> = cast(dialog)
    gtk_window_set_title(cast(dialog), "Slop Export")
    gtk_window_set_transient_for(cast(dialog), cast(parent))
    gtk_window_set_modal(cast(dialog), 1)
    gtk_window_set_resizable(cast(dialog), 0)
    _ = gtk_dialog_add_button(d, "_Cancel", GTK_RESPONSE_CANCEL.rawValue)
    let ok = gtk_dialog_add_button(d, action, GTK_RESPONSE_ACCEPT.rawValue)!
    addClass(ok, destructive ? StyleClass.destructive : StyleClass.suggested)
    gtk_dialog_set_default_response(d, GTK_RESPONSE_CANCEL.rawValue)

    let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 8)!
    gtk_container_set_border_width(cast(box), 16)
    gtk_box_pack_start(cast(box), makeLabel(title, classes: [StyleClass.heading]), 0, 0, 0)
    let body = makeLabel(message)
    gtk_label_set_max_width_chars(cast(body), 60)
    gtk_box_pack_start(cast(box), body, 0, 0, 0)
    gtk_container_add(cast(gtk_dialog_get_content_area(d)), box)
    gtk_widget_show_all(dialog)
    let response = gtk_dialog_run(d)
    gtk_widget_destroy(dialog)
    return response == GTK_RESPONSE_ACCEPT.rawValue
}

/// App-wide CSS for the few custom styles (headings, error and success colours).
@MainActor
func installStyles() {
    let css = """
    .slop-heading { font-weight: bold; font-size: 1.1em; }
    .slop-big { font-size: 1.4em; font-weight: bold; }
    .slop-error { color: #c01c28; }
    .slop-good { color: #26a269; }
    """
    let provider = gtk_css_provider_new()!
    _ = gtk_css_provider_load_from_data(provider, css, -1, nil)
    gtk_style_context_add_provider_for_screen(gdk_screen_get_default(), opaque(provider),
                                              UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    g_object_unref(provider)
}
