import AppKit
import ApplicationServices
import os

private let permissionsLogger = Logger(subsystem: "local.termgrid", category: "ui")

@MainActor
final class Permissions: ObservableObject {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Published private(set) var isTrusted: Bool
    private var timer: Timer?

    init() {
        #if DEBUG
        let arguments = CommandLine.arguments
        let launcherPrompts = arguments.contains("--probe") || arguments.contains { $0.hasPrefix("--selftest-") }
        #else
        let launcherPrompts = false
        #endif
        if launcherPrompts {
            isTrusted = AXIsProcessTrusted()
        } else {
            let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            isTrusted = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        }
        if isTrusted {
            permissionsLogger.notice("accessibility trusted")
        } else {
            permissionsLogger.notice("accessibility not trusted")
            startPolling()
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func startPolling() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
    }

    private func poll() {
        guard AXIsProcessTrusted() else {
            return
        }
        timer?.invalidate()
        timer = nil
        isTrusted = true
        permissionsLogger.notice("accessibility trusted")
    }
}
