import CoreGraphics

public enum CellEdge: String, Sendable {
    case left
    case right
    case top
    case bottom

    var axis: Axis {
        self == .left || self == .right ? .horizontal : .vertical
    }

    var isFar: Bool {
        self == .right || self == .bottom
    }

    func position(of rect: CGRect) -> CGFloat {
        switch self {
        case .left: rect.minX
        case .right: rect.maxX
        case .top: rect.minY
        case .bottom: rect.maxY
        }
    }
}

public struct EdgeMove: Equatable, Sendable {
    public let edge: CellEdge
    public let divider: DividerID?
    public let delta: CGFloat
}

public enum EdgeResize {
    public static let edgeTolerance: CGFloat = 2

    public static func moves(
        of cell: CellID,
        tree: LayoutNode,
        cellFrames: [CellID: CGRect],
        gap: CGFloat,
        reference: CGRect,
        current: CGRect
    ) -> [EdgeMove] {
        guard let frame = cellFrames[cell] else { return [] }
        let dividers = Dividers.compute(tree, frames: cellFrames, gap: gap)
        var result: [EdgeMove] = []
        for axis in [Axis.horizontal, .vertical] {
            let sizeChange = axis == .horizontal ? current.width - reference.width : current.height - reference.height
            guard abs(sizeChange) > ExternalChange.threshold else { continue }
            let edges: [CellEdge] = axis == .horizontal ? [.left, .right] : [.top, .bottom]
            for edge in edges where abs(edge.position(of: current) - edge.position(of: reference)) > edgeTolerance {
                result.append(EdgeMove(
                    edge: edge,
                    divider: divider(on: edge, of: cell, dividers: dividers, tree: tree, cellFrames: cellFrames),
                    delta: edge.position(of: current) - edge.position(of: frame)
                ))
            }
        }
        return result
    }

    public static func tree(
        applying moves: [EdgeMove],
        to tree: LayoutNode,
        cellFrames: [CellID: CGRect],
        minSizes: [CellID: CGSize],
        minCell: CGSize,
        solve: (LayoutNode) -> [CellID: CGRect]
    ) -> LayoutNode {
        var current = tree
        var frames = cellFrames
        for move in moves {
            guard let id = move.divider else { continue }
            let next = Dividers.moveDivider(
                current,
                id: id,
                delta: move.delta,
                frames: frames,
                minSizes: minSizes,
                minCell: minCell
            )
            guard next != current else { continue }
            current = next
            frames = solve(next)
        }
        return current
    }

    static func divider(
        on edge: CellEdge,
        of cell: CellID,
        dividers: [Divider],
        tree: LayoutNode,
        cellFrames: [CellID: CGRect]
    ) -> DividerID? {
        for divider in dividers where divider.axis == edge.axis {
            let (near, far) = GridFit.adjacentCells(of: divider, in: tree, cellFrames: cellFrames)
            if edge.isFar ? near.contains(cell) : far.contains(cell) {
                return divider.id
            }
        }
        return nil
    }
}
