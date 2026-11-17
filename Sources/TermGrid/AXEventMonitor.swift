import ApplicationServices
import Foundation
import os

let eventLogger = Logger(subsystem: "local.termgrid", category: "events")

func logEvent(_ message: String) {
    eventLogger.notice("\(message, privacy: .public)")
}

enum AXEventKind: String {
    case moved
    case resized
    case destroyed
    case miniaturized
}

struct AXEvent {
    let kind: AXEventKind
    let pid: pid_t
    let element: AXUIElement
    let bindingID: Int?
}

private let observerCallback: AXObserverCallback = { _, element, notification, refcon in
    let bindingID = refcon.map { Int(bitPattern: $0) }
    let name = notification as String
    MainActor.assumeIsolated {
        AXEventMonitor.active?.receive(element: element, notification: name, bindingID: bindingID)
    }
}

@MainActor
final class AXEventMonitor {
    static weak var active: AXEventMonitor?

    private nonisolated static let applicationNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification]
    private nonisolated static let windowNotifications = [kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification]

    private final class ProcessObserver: @unchecked Sendable {
        let pid: pid_t
        let observer: AXObserver
        let application: AXUIElement
        var windows: [Int: AXWindow] = [:]
        var applicationIncomplete = false

        init(pid: pid_t, observer: AXObserver) {
            self.pid = pid
            self.observer = observer
            application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, AXWindow.messagingTimeout)
        }
    }

    private let mover: WindowMover
    private let handler: (AXEvent) -> Void
    private var processes: [pid_t: ProcessObserver] = [:]
    private var incomplete = Set<Int>()

    init(mover: WindowMover, handler: @escaping (AXEvent) -> Void) {
        self.mover = mover
        self.handler = handler
        Self.active = self
    }

    func observe(_ window: AXWindow, bindingID: Int) {
        guard let process = process(for: window.pid) else { return }
        process.windows[bindingID] = window
        register(window, bindingID: bindingID, in: process)
    }

    func unobserve(_ window: AXWindow, bindingID: Int) {
        incomplete.remove(bindingID)
        guard let process = processes[window.pid],
              let registered = process.windows.removeValue(forKey: bindingID)
        else { return }
        let queue = mover.queue(for: process.pid)
        queue.async {
            dispatchPrecondition(condition: .onQueue(queue))
            for notification in Self.windowNotifications {
                _ = AXObserverRemoveNotification(process.observer, registered.element, notification as CFString)
            }
        }
        if process.windows.isEmpty {
            close(process)
        }
    }

    func prepareWrite(_ window: AXWindow, bindingID: Int) {
        guard let process = processes[window.pid] else { return }
        if process.applicationIncomplete {
            process.applicationIncomplete = false
            registerApplication(process)
        }
        if incomplete.remove(bindingID) != nil, let registered = process.windows[bindingID] {
            register(registered, bindingID: bindingID, in: process)
        }
    }

    fileprivate func receive(element: AXUIElement, notification: String, bindingID: Int?) {
        let kind: AXEventKind
        switch notification {
        case kAXWindowMovedNotification: kind = .moved
        case kAXWindowResizedNotification: kind = .resized
        case kAXUIElementDestroyedNotification: kind = .destroyed
        case kAXWindowMiniaturizedNotification: kind = .miniaturized
        default: return
        }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        handler(AXEvent(kind: kind, pid: pid, element: element, bindingID: bindingID))
    }

    private func process(for pid: pid_t) -> ProcessObserver? {
        if let process = processes[pid] {
            return process
        }
        var created: AXObserver?
        let error = AXObserverCreate(pid, observerCallback, &created)
        guard error == .success, let observer = created else {
            logEvent("observe failed pid=\(pid) call=create error=\(error.rawValue)")
            return nil
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        let process = ProcessObserver(pid: pid, observer: observer)
        processes[pid] = process
        registerApplication(process)
        return process
    }

    private func close(_ process: ProcessObserver) {
        processes[process.pid] = nil
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(process.observer), .defaultMode)
        let queue = mover.queue(for: process.pid)
        queue.async {
            dispatchPrecondition(condition: .onQueue(queue))
            for notification in Self.applicationNotifications {
                _ = AXObserverRemoveNotification(process.observer, process.application, notification as CFString)
            }
        }
    }

    private func registerApplication(_ process: ProcessObserver) {
        let queue = mover.queue(for: process.pid)
        queue.async {
            dispatchPrecondition(condition: .onQueue(queue))
            let errors = Self.applicationNotifications.map {
                AXObserverAddNotification(process.observer, process.application, $0 as CFString, nil)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.applicationRegistered(process, errors: errors)
                }
            }
        }
    }

    private func register(_ window: AXWindow, bindingID: Int, in process: ProcessObserver) {
        let queue = mover.queue(for: process.pid)
        queue.async {
            dispatchPrecondition(condition: .onQueue(queue))
            let refcon = UnsafeMutableRawPointer(bitPattern: bindingID)
            let errors = Self.windowNotifications.map {
                AXObserverAddNotification(process.observer, window.element, $0 as CFString, refcon)
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.windowRegistered(bindingID, in: process, errors: errors)
                }
            }
        }
    }

    private func applicationRegistered(_ process: ProcessObserver, errors: [AXError]) {
        guard processes[process.pid] === process else { return }
        if errors.contains(.cannotComplete) {
            process.applicationIncomplete = true
            logEvent("observe incomplete pid=\(process.pid)")
        } else if let failure = errors.first(where: { !Self.isRegistered($0) }) {
            logEvent("observe failed pid=\(process.pid) error=\(failure.rawValue)")
        }
    }

    private func windowRegistered(_ bindingID: Int, in process: ProcessObserver, errors: [AXError]) {
        guard processes[process.pid] === process, process.windows[bindingID] != nil else { return }
        if errors.contains(.cannotComplete) {
            incomplete.insert(bindingID)
            logEvent("observe incomplete window=\(process.pid):\(bindingID)")
        } else if let failure = errors.first(where: { !Self.isRegistered($0) }) {
            logEvent("observe failed window=\(process.pid):\(bindingID) error=\(failure.rawValue)")
        }
    }

    private nonisolated static func isRegistered(_ error: AXError) -> Bool {
        error == .success || error == .notificationAlreadyRegistered
    }
}
