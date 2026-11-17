import AppKit
import ApplicationServices

struct DiscoveredWindow: Sendable {
    let window: AXWindow
    let bundleId: String?
    let appName: String
    let title: String
    let frame: CGRect?
    let isSizeSettable: Bool

    var pid: pid_t {
        window.pid
    }

    var displayTitle: String {
        title.isEmpty ? "Без названия" : title
    }
}

enum WindowDiscovery {
    static func snapshot() -> [DiscoveredWindow] {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ownPid }
            .flatMap { windows(of: $0) }
    }

    private static func windows(of app: NSRunningApplication) -> [DiscoveredWindow] {
        let pid = app.processIdentifier
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, AXWindow.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement]
        else {
            return []
        }
        let bundleId = app.bundleIdentifier
        let appName = app.localizedName ?? bundleId ?? "pid \(pid)"
        return elements.compactMap { element in
            let window = AXWindow(element: element, pid: pid)
            guard window.role == kAXWindowRole,
                  window.subrole == kAXStandardWindowSubrole,
                  !window.isMinimized,
                  !window.isFullScreen,
                  window.isPositionSettable
            else {
                return nil
            }
            return DiscoveredWindow(
                window: window,
                bundleId: bundleId,
                appName: appName,
                title: window.title ?? "",
                frame: window.frame,
                isSizeSettable: window.isSizeSettable
            )
        }
    }
}
