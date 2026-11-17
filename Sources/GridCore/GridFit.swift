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

public enum DividerFit: Equatable, Sendable {
    case notApplicable
    case skipped
    case adjusted(tree: LayoutNode, frames: [CellID: CGRect], delta: CGFloat)
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
            switch fit(
                divider: id,
                tree: current,
                cellFrames: frames,
                actualFrames: actuals,
                gap: gap,
                isTerminalCell: isTerminalCell,
                solve: solve
            ) {
            case .notApplicable:
                continue
            case .skipped:
                skipped.append(id)
            case .adjusted(let next, let nextFrames, let delta):
                adjustments.append(FitAdjustment(divider: id, delta: delta))
                actuals = carry(actuals, from: frames, to: nextFrames)
                current = next
                frames = nextFrames
            }
        }
        guard !adjustments.isEmpty || !skipped.isEmpty else { return nil }
        return FitPlan(tree: current, adjustments: adjustments, skipped: skipped)
    }

    public static func fit(
        divider id: DividerID,
        tree: LayoutNode,
        cellFrames: [CellID: CGRect],
        actualFrames: [CellID: CGRect],
        gap: CGFloat,
        isTerminalCell: (CellID) -> Bool,
        solve: (LayoutNode) -> [CellID: CGRect]
    ) -> DividerFit {
        guard let divider = Dividers.compute(tree, frames: cellFrames, gap: gap).first(where: { $0.id == id }),
              let (axis, children) = Dividers.container(in: tree, id: id.container)
        else { return .notApplicable }
        let (near, far) = adjacentCells(of: divider, in: tree, cellFrames: cellFrames)
        guard !near.isEmpty, !far.isEmpty, (near + far).allSatisfy(isTerminalCell) else { return .notApplicable }
        guard let next = FitPolicy.adjust(
            tree,
            divider: divider,
            actualFrames: actualFrames,
            cellFrames: cellFrames,
            gap: gap
        ) else { return .skipped }
        let nextFrames = solve(next)
        let nearNode = children[id.index].node
        let before = Dividers.extent(Dividers.bounds(of: nearNode, frames: cellFrames), axis)
        let after = Dividers.extent(Dividers.bounds(of: nearNode, frames: nextFrames), axis)
        return .adjusted(tree: next, frames: nextFrames, delta: before - after)
    }

    public static func retainedActuals(
        _ actuals: [CellID: CGRect],
        old: [CellID: CGRect],
        new: [CellID: CGRect]
    ) -> [CellID: CGRect] {
        actuals.filter { cell, _ in
            guard let before = old[cell], let after = new[cell] else { return false }
            return before == after
        }
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
