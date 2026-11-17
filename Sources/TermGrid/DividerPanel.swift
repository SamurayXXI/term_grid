import AppKit
import GridCore

final class DividerPanel: NSPanel {
    static let panelLevel: NSWindow.Level = .floating
    private static let idleAlpha: CGFloat = 0.01
    private static let hoverAlpha: CGFloat = 0.3

    let dividerID: DividerID
    private(set) var axis: Axis
    unowned let overlay: DividerOverlay

    init(divider: Divider, frame: CGRect, overlay: DividerOverlay) {
        dividerID = divider.id
        axis = divider.axis
        self.overlay = overlay
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = Self.panelLevel
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        setHighlighted(false)
        contentView = DividerView(frame: NSRect(origin: .zero, size: frame.size))
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    var cursor: NSCursor {
        axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    func place(_ frame: CGRect, axis: Axis) {
        self.axis = axis
        if self.frame != frame {
            setFrame(frame, display: true)
        }
    }

    func setHighlighted(_ highlighted: Bool) {
        backgroundColor = NSColor.controlAccentColor.withAlphaComponent(highlighted ? Self.hoverAlpha : Self.idleAlpha)
    }
}

final class DividerView: NSView {
    private var panel: DividerPanel? {
        window as? DividerPanel
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard let panel else { return }
        panel.cursor.set()
        panel.setHighlighted(true)
    }

    override func mouseMoved(with event: NSEvent) {
        panel?.cursor.set()
    }

    override func cursorUpdate(with event: NSEvent) {
        panel?.cursor.set()
    }

    override func mouseExited(with event: NSEvent) {
        guard let panel, !panel.overlay.isDragging(panel.dividerID) else { return }
        NSCursor.arrow.set()
        panel.setHighlighted(false)
    }

    override func mouseDown(with event: NSEvent) {
        guard let panel else { return }
        if panel.overlay.dragBegan(panel.dividerID, at: Self.location(of: event)) {
            panel.cursor.set()
            panel.setHighlighted(true)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel else { return }
        panel.cursor.set()
        panel.overlay.dragMoved(panel.dividerID, to: Self.location(of: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let panel else { return }
        panel.overlay.dragEnded(panel.dividerID, at: Self.location(of: event))
        panel.setHighlighted(false)
    }

    private static func location(of event: NSEvent) -> CGPoint {
        if let location = event.cgEvent?.location {
            return location
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return ScreenSpace.toAX(CGRect(origin: NSEvent.mouseLocation, size: .zero), primaryHeight: primaryHeight).origin
    }
}
