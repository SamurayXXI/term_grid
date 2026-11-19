import AppKit
import GridCore

final class SwapHighlightPanel: NSPanel {
    private static let blurAlpha: CGFloat = 0.4
    private static let tintAlpha: CGFloat = 0.12

    private let effect = NSVisualEffectView()
    private let mask = CAShapeLayer()

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        level = DividerPanel.panelLevel
        collectionBehavior = [.ignoresCycle, .fullScreenNone]
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.alphaValue = Self.blurAlpha
        effect.autoresizingMask = [.width, .height]
        effect.wantsLayer = true
        effect.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(Self.tintAlpha).cgColor
        effect.layer?.mask = mask
        contentView = effect
    }

    override var canBecomeKey: Bool { false }

    override var canBecomeMain: Bool { false }

    func show(cell: CGRect, covering dragged: CGRect) {
        if frame != cell {
            setFrame(cell, display: false)
        }
        let local = CGRect(origin: .zero, size: cell.size)
        let path = CGMutablePath()
        path.addRect(local)
        let hole = dragged.offsetBy(dx: -cell.minX, dy: -cell.minY).intersection(local)
        if !hole.isNull, !hole.isEmpty {
            path.addRect(hole)
        }
        mask.frame = local
        mask.path = path
        mask.fillRule = .evenOdd
        orderFrontRegardless()
    }

    func hide() {
        orderOut(nil)
    }
}
