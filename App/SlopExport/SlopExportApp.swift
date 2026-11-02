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
        .commands {
            // Keyboard access to every step, with a checkmark on the current one.
            CommandMenu("Go") {
                ForEach(Step.allCases) { step in
                    Toggle(step.title, isOn: Binding(get: { model.step == step }, set: { if $0 { model.step = step } }))
                        .keyboardShortcut(step.shortcut)
                }
            }
        }
    }
}
