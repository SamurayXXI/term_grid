import CoreGraphics

public struct OuterEdges: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let top = OuterEdges(rawValue: 1)
    public static let bottom = OuterEdges(rawValue: 2)
    public static let left = OuterEdges(rawValue: 4)
    public static let right = OuterEdges(rawValue: 8)
}

public enum FitPolicy {
    public static let minDeficit: CGFloat = 1
    public static let maxDeficit: CGFloat = 40

    public static func adjust(
        _ tree: LayoutNode,
        divider: Divider,
        actualFrames: [CellID: CGRect],
        cellFrames: [CellID: CGRect],
        gap: CGFloat
    ) -> LayoutNode? {
        guard let (axis, children) = Dividers.container(in: tree, id: divider.id.container),
              divider.id.index >= 0, divider.id.index + 1 < children.count
        else { return nil }
        let nearNode = children[divider.id.index].node
        let dividerEdge = axis == .horizontal ? divider.rect.minX : divider.rect.minY
        let deficits: [CGFloat] = nearNode.leafIDs.compactMap { cell in
            guard let cellFrame = cellFrames[cell], let actual = actualFrames[cell] else { return nil }
            let cellEdge = axis == .horizontal ? cellFrame.maxX : cellFrame.maxY
            guard abs(cellEdge - dividerEdge) < 0.5 else { return nil }
            return Dividers.extent(cellFrame, axis) - Dividers.extent(actual, axis)
        }
        guard let deficit = deficits.min(), deficit > minDeficit, deficit < maxDeficit else { return nil }
        let nearSize = Dividers.extent(Dividers.bounds(of: nearNode, frames: cellFrames), axis) - deficit
        guard nearSize > 0 else { return nil }
        return Dividers.resized(tree, id: divider.id, nearSize: nearSize, frames: cellFrames)
    }

    public static func anchoredOrigin(_ cell: CGRect, actualSize: CGSize, outerEdges: OuterEdges) -> CGPoint {
        var origin = cell.origin
        if actualSize.height < cell.height - minDeficit, outerEdges.contains(.top) != outerEdges.contains(.bottom) {
            if outerEdges.contains(.top) {
                origin.y = cell.maxY - actualSize.height
            }
        }
        if actualSize.width < cell.width - minDeficit, outerEdges.contains(.left) != outerEdges.contains(.right) {
            if outerEdges.contains(.left) {
                origin.x = cell.maxX - actualSize.width
            }
        }
        return origin
    }
}
