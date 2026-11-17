import AppKit
import GridCore

@MainActor
final class StageManager: ObservableObject {
    static let shared = StageManager()
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!

    @Published private(set) var isEnabled = false
    private var observer: NSObjectProtocol?

    init() {
        refresh()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func refresh() {
        let value = CFPreferencesCopyAppValue("GloballyEnabled" as CFString, "com.apple.WindowManager" as CFString)
        let enabled = StageManagerSetting.isEnabled(value)
        if enabled != isEnabled {
            isEnabled = enabled
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }
}
