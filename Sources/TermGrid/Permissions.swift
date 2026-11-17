import AppKit
import ApplicationServices
import os

private let permissionsLogger = Logger(subsystem: "local.termgrid", category: "ui")

@MainActor
final class Permissions: ObservableObject {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Published private(set) var isTrusted: Bool
    private var timer: Timer?
    private var accessibilityObserver: NSObjectProtocol?

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
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated {
                    self?.poll()
                }
            }
        }
    }

    private func poll() {
        guard !isTrusted, AXIsProcessTrusted() else {
            return
        }
        timer?.invalidate()
        timer = nil
        if let accessibilityObserver {
            DistributedNotificationCenter.default().removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
        isTrusted = true
        permissionsLogger.notice("accessibility trusted")
    }
}
