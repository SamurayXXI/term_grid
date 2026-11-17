import CoreGraphics

public struct FitAdjustment: Equatable, Sendable {
    public let divider: DividerID
    public let delta: CGFloat
}

public struct FitPlan: Sendable {
    public let tree: LayoutNode
    public let adjustments: [FitAdjustment]
    public let skipped: [DividerID]
}

public enum GridFit {
    public static func outerEdges(of cell: CGRect, in grid: CGRect, tolerance: CGFloat = 0.5) -> OuterEdges {
        var edges: OuterEdges = []
        if abs(cell.minY - grid.minY) <= tolerance { edges.insert(.top) }
        if abs(cell.maxY - grid.maxY) <= tolerance { edges.insert(.bottom) }
        if abs(cell.minX - grid.minX) <= tolerance { edges.insert(.left) }
        if abs(cell.maxX - grid.maxX) <= tolerance { edges.insert(.right) }
        return edges
    }

    public static func adjacentCells(
        of divider: Divider,
        in tree: LayoutNode,
        cellFrames: [CellID: CGRect]
    ) -> (near: [CellID], far: [CellID]) {
        guard let (axis, children) = Dividers.container(in: tree, id: divider.id.container),
              divider.id.index >= 0, divider.id.index + 1 < children.count
        else { return ([], []) }
        let nearEdge = axis == .horizontal ? divider.rect.minX : divider.rect.minY
        let farEdge = axis == .horizontal ? divider.rect.maxX : divider.rect.maxY
        let near = children[divider.id.index].node.leafIDs.filter { cell in
            guard let frame = cellFrames[cell] else { return false }
            return abs((axis == .horizontal ? frame.maxX : frame.maxY) - nearEdge) < 0.5
        }
        let far = children[divider.id.index + 1].node.leafIDs.filter { cell in
            guard let frame = cellFrames[cell] else { return false }
            return abs((axis == .horizontal ? frame.minX : frame.minY) - farEdge) < 0.5
        }
        return (near, far)
    }

    public static func plan(
        tree: LayoutNode,
        cellFrames: [CellID: CGRect],
        actualFrames: [CellID: CGRect],
        gap: CGFloat,
        isTerminalCell: (CellID) -> Bool,
        solve: (LayoutNode) -> [CellID: CGRect]
    ) -> FitPlan? {
        var current = tree
        var frames = cellFrames
        var actuals = actualFrames
        var adjustments: [FitAdjustment] = []
        var skipped: [DividerID] = []
        for id in Dividers.compute(tree, frames: cellFrames, gap: gap).map(\.id) {
            guard let divider = Dividers.compute(current, frames: frames, gap: gap).first(where: { $0.id == id }) else {
                continue
            }
            let (near, far) = adjacentCells(of: divider, in: current, cellFrames: frames)
            guard !near.isEmpty, !far.isEmpty, (near + far).allSatisfy(isTerminalCell) else { continue }
            guard let next = FitPolicy.adjust(
                current,
                divider: divider,
                actualFrames: actuals,
                cellFrames: frames,
                gap: gap
            ) else {
                skipped.append(id)
                continue
            }
            let nextFrames = solve(next)
            if let (axis, children) = Dividers.container(in: current, id: id.container) {
                let nearNode = children[id.index].node
                let before = Dividers.extent(Dividers.bounds(of: nearNode, frames: frames), axis)
                let after = Dividers.extent(Dividers.bounds(of: nearNode, frames: nextFrames), axis)
                adjustments.append(FitAdjustment(divider: id, delta: before - after))
            }
            actuals = carry(actuals, from: frames, to: nextFrames)
            current = next
            frames = nextFrames
        }
        guard !adjustments.isEmpty || !skipped.isEmpty else { return nil }
        return FitPlan(tree: current, adjustments: adjustments, skipped: skipped)
    }

    private static func carry(
        _ actuals: [CellID: CGRect],
        from old: [CellID: CGRect],
        to new: [CellID: CGRect]
    ) -> [CellID: CGRect] {
        var result = actuals
        for (cell, actual) in actuals {
            guard let oldCell = old[cell], let newCell = new[cell] else { continue }
            result[cell] = CGRect(
                x: newCell.minX,
                y: newCell.minY,
                width: newCell.width - (oldCell.width - actual.width),
                height: newCell.height - (oldCell.height - actual.height)
            )
        }
        return result
    }
}
