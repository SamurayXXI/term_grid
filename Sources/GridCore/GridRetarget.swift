import CoreGraphics

public enum GridRetarget {
    public static func tree(
        _ tree: LayoutNode,
        startFrames: [CellID: CGRect],
        from startGrid: CGRect,
        to targetGrid: CGRect,
        gap: CGFloat
    ) -> LayoutNode {
        rebuild(tree, start: startGrid, target: targetGrid, frames: startFrames)
    }

    private static func rebuild(
        _ node: LayoutNode,
        start: CGRect,
        target: CGRect,
        frames: [CellID: CGRect]
    ) -> LayoutNode {
        guard case .container(let id, let axis, let children) = node, start != target else { return node }
        let horizontal = axis == .horizontal
        let starts = children.map { bounds(of: $0.node, frames: frames) ?? start }
        let startMin = horizontal ? start.minX : start.minY
        let startMax = horizontal ? start.maxX : start.maxY
        let targetMin = horizontal ? target.minX : target.minY
        let targetMax = horizontal ? target.maxX : target.maxY
        let nearShift = targetMin - startMin
        let farShift = targetMax - startMax
        var extents = starts.map { horizontal ? $0.width : $0.height }
        extents[0] = max(1, extents[0] - nearShift)
        extents[extents.count - 1] = max(1, extents[extents.count - 1] + farShift)
        let moved = abs(nearShift) > 0.001 || abs(farShift) > 0.001
        let total = extents.reduce(0, +)
        let gapTotal = (horizontal ? target.width : target.height) - total
        let gapEach = children.count > 1 ? gapTotal / CGFloat(children.count - 1) : 0
        var offset = targetMin
        var result: [LayoutChild] = []
        for (index, child) in children.enumerated() {
            let size = extents[index]
            let childTarget = horizontal
                ? CGRect(x: offset, y: target.minY, width: size, height: target.height)
                : CGRect(x: target.minX, y: offset, width: target.width, height: size)
            offset += size + gapEach
            let ratio = moved ? Double(size / total) : child.ratio
            result.append(LayoutChild(
                node: rebuild(child.node, start: starts[index], target: childTarget, frames: frames),
                ratio: ratio
            ))
        }
        return .container(id, axis, result)
    }

    private static func bounds(of node: LayoutNode, frames: [CellID: CGRect]) -> CGRect? {
        node.leafIDs.compactMap { frames[$0] }.reduce(nil) { partial, frame in
            partial.map { $0.union(frame) } ?? frame
        }
    }
}
