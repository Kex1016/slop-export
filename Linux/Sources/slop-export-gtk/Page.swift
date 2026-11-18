import CGtk
import SlopLinux

/// One step's page in the window's stack.
@MainActor
protocol Page: AnyObject {
    var step: Step { get }
    var root: Widget { get }
    func refresh()
}
