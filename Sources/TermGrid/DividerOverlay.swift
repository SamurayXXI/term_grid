import AppKit
import GridCore
import os

private let overlayLogger = Logger(subsystem: "local.termgrid", category: "ui")

@MainActor
final class DividerOverlay {
    struct Handlers {
        let begin: (DividerID, CGPoint) -> Bool
        let move: (CGPoint) -> Void
        let end: (CGPoint) -> Void
        let cancel: () -> Void
        let managesWindows: (pid_t) -> Bool
    }

    private let handlers: Handlers
    private var panels: [DividerID: DividerPanel] = [:]
    private var dragging: DividerID?
    private var activationObserver: NSObjectProtocol?

    init(handlers: Handlers) {
        self.handlers = handlers
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = application?.processIdentifier
            MainActor.assumeIsolated {
                self?.applicationActivated(pid)
            }
        }
    }

    func show(_ dividers: [Divider], primaryHeight: CGFloat) {
        var changed = false
        var membershipChanged = false
        let wanted = Set(dividers.map(\.id))
        for (id, panel) in panels where !wanted.contains(id) {
            panel.orderOut(nil)
            panels[id] = nil
            membershipChanged = true
            if dragging == id {
                dragging = nil
                handlers.cancel()
            }
        }
        for divider in dividers {
            let frame = divider.panelFrame(primaryHeight: primaryHeight)
            if let panel = panels[divider.id] {
                if panel.frame != frame || panel.axis != divider.axis {
                    panel.place(frame, axis: divider.axis)
                    changed = true
                }
            } else {
                panels[divider.id] = DividerPanel(divider: divider, frame: frame, overlay: self)
                membershipChanged = true
            }
        }
        if changed || membershipChanged {
            orderFront()
        }
        if membershipChanged {
            overlayLogger.notice("dividers shown count=\(self.panels.count)")
        }
    }

    func isDragging(_ id: DividerID) -> Bool {
        dragging == id
    }

    func dragBegan(_ id: DividerID, at point: CGPoint) -> Bool {
        guard dragging == nil, panels[id] != nil, handlers.begin(id, point) else { return false }
        dragging = id
        return true
    }

    func dragMoved(_ id: DividerID, to point: CGPoint) {
        guard dragging == id else { return }
        handlers.move(point)
    }

    func dragEnded(_ id: DividerID, at point: CGPoint) {
        guard dragging == id else { return }
        dragging = nil
        handlers.end(point)
    }

    func dragCancelled() {
        dragging = nil
    }

    private func orderFront() {
        for panel in panels.values {
            panel.orderFrontRegardless()
        }
    }

    private func applicationActivated(_ pid: pid_t?) {
        guard let pid, !panels.isEmpty, handlers.managesWindows(pid) else { return }
        orderFront()
    }
}
