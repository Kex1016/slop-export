import SwiftUI

@main
struct SlopExportApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("Slop Export") {
            ContentView()
                .environment(model)
                .frame(minWidth: 820, minHeight: 520)
        }
        .windowResizability(.contentMinSize)
    }
}
