import CoreGraphics

public struct DividerDrag: Sendable {
    public let divider: Divider
    public let origin: CGPoint
    public let tree: LayoutNode
    public let frames: [CellID: CGRect]
    public let cells: [CellID]

    public init?(tree: LayoutNode, divider id: DividerID, frames: [CellID: CGRect], gap: CGFloat, origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite,
              let divider = Dividers.compute(tree, frames: frames, gap: gap).first(where: { $0.id == id }),
              let (_, children) = Dividers.container(in: tree, id: id.container)
        else { return nil }
        self.divider = divider
        self.origin = origin
        self.tree = tree
        self.frames = frames
        cells = children[id.index].node.leafIDs + children[id.index + 1].node.leafIDs
    }

    public func delta(to point: CGPoint) -> CGFloat {
        divider.axis == .horizontal ? point.x - origin.x : point.y - origin.y
    }

    public func tree(to point: CGPoint, minSizes: [CellID: CGSize], minCell: CGSize) -> LayoutNode {
        Dividers.moveDivider(
            tree,
            id: divider.id,
            delta: delta(to: point),
            frames: frames,
            minSizes: minSizes,
            minCell: minCell
        )
    }
}

extension Divider {
    public static let minThickness: CGFloat = 6
    public static let minLength: CGFloat = 1

    public var isGrabbable: Bool {
        (axis == .horizontal ? rect.height : rect.width) >= Self.minLength
    }

    public var hitRect: CGRect {
        let thickness = axis == .horizontal ? rect.width : rect.height
        let grow = max(0, Self.minThickness - thickness) / 2
        return axis == .horizontal ? rect.insetBy(dx: -grow, dy: 0) : rect.insetBy(dx: 0, dy: -grow)
    }

    public func panelFrame(primaryHeight: CGFloat) -> CGRect {
        ScreenSpace.fromAX(hitRect, primaryHeight: primaryHeight)
    }

    public func point(along fraction: CGFloat) -> CGPoint {
        axis == .horizontal
            ? CGPoint(x: rect.midX, y: rect.minY + rect.height * fraction)
            : CGPoint(x: rect.minX + rect.width * fraction, y: rect.midY)
    }
}
