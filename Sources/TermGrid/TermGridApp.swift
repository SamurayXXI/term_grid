import SwiftUI
import AppKit

@main
struct TermGridApp: App {
    var body: some Scene {
        MenuBarExtra("TermGrid", systemImage: "square.grid.2x2") {
            Button("Выход") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
