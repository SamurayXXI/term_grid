import CoreGraphics

public struct DividerID: Hashable, Sendable {
    public let container: ContainerID
    public let index: Int

    public init(container: ContainerID, index: Int) {
        self.container = container
        self.index = index
    }
}

public struct Divider: Equatable, Sendable {
    public let id: DividerID
    public let axis: Axis
    public let rect: CGRect

    public init(id: DividerID, axis: Axis, rect: CGRect) {
        self.id = id
        self.axis = axis
        self.rect = rect
    }
}

public enum Dividers {
    public static func compute(_ tree: LayoutNode, frames: [CellID: CGRect], gap: CGFloat) -> [Divider] {
        guard case .container(let id, let axis, let children) = tree else { return [] }
        var result: [Divider] = []
        let whole = bounds(of: tree, frames: frames)
        for index in 0..<(children.count - 1) {
            let near = bounds(of: children[index].node, frames: frames)
            let rect = axis == .horizontal
                ? CGRect(x: near.maxX, y: whole.minY, width: gap, height: whole.height)
                : CGRect(x: whole.minX, y: near.maxY, width: whole.width, height: gap)
            result.append(Divider(id: DividerID(container: id, index: index), axis: axis, rect: rect))
        }
        for child in children {
            result += compute(child.node, frames: frames, gap: gap)
        }
        return result
    }

    public static func moveDivider(
        _ tree: LayoutNode,
        id: DividerID,
        delta: CGFloat,
        frames: [CellID: CGRect],
        minSizes: [CellID: CGSize] = [:],
        minCell: CGSize
    ) -> LayoutNode {
        guard delta.isFinite,
              let (axis, children) = container(in: tree, id: id.container),
              id.index >= 0, id.index + 1 < children.count
        else { return tree }
        let near = bounds(of: children[id.index].node, frames: frames)
        let far = bounds(of: children[id.index + 1].node, frames: frames)
        let nearSize = extent(near, axis)
        let total = nearSize + extent(far, axis)
        let gap = axis == .horizontal ? far.minX - near.maxX : far.minY - near.maxY
        let lower = required(children[id.index].node, axis: axis, gap: gap, minCell: minCell, minSizes: minSizes)
        let upper = total - required(children[id.index + 1].node, axis: axis, gap: gap, minCell: minCell, minSizes: minSizes)
        guard lower <= upper else { return tree }
        let target = min(max(nearSize + delta, lower), upper)
        return resized(tree, id: id, nearSize: target, frames: frames)
    }

    static func resized(_ tree: LayoutNode, id: DividerID, nearSize: CGFloat, frames: [CellID: CGRect]) -> LayoutNode {
        guard case .container(let containerID, let axis, let children) = tree else { return tree }
        if containerID == id.container, id.index + 1 < children.count {
            let near = extent(bounds(of: children[id.index].node, frames: frames), axis)
            let far = extent(bounds(of: children[id.index + 1].node, frames: frames), axis)
            let pair = children[id.index].ratio + children[id.index + 1].ratio
            var updated = children
            updated[id.index].ratio = pair * Double(nearSize / (near + far))
            updated[id.index + 1].ratio = pair - updated[id.index].ratio
            return .container(containerID, axis, updated)
        }
        let mapped = children.map {
            LayoutChild(node: resized($0.node, id: id, nearSize: nearSize, frames: frames), ratio: $0.ratio)
        }
        return .container(containerID, axis, mapped)
    }

    static func container(in tree: LayoutNode, id: ContainerID) -> (Axis, [LayoutChild])? {
        guard case .container(let containerID, let axis, let children) = tree else { return nil }
        if containerID == id { return (axis, children) }
        for child in children {
            if let found = container(in: child.node, id: id) { return found }
        }
        return nil
    }

    static func bounds(of node: LayoutNode, frames: [CellID: CGRect]) -> CGRect {
        node.leafIDs.compactMap { frames[$0] }.reduce(CGRect.null) { $0.union($1) }
    }

    static func extent(_ rect: CGRect, _ axis: Axis) -> CGFloat {
        axis == .horizontal ? rect.width : rect.height
    }

    private static func required(
        _ node: LayoutNode,
        axis: Axis,
        gap: CGFloat,
        minCell: CGSize,
        minSizes: [CellID: CGSize]
    ) -> CGFloat {
        switch node {
        case .leaf(let id):
            let own = minSizes[id] ?? .zero
            return axis == .horizontal ? max(minCell.width, own.width) : max(minCell.height, own.height)
        case .container(_, let containerAxis, let children):
            let parts = children.map { required($0.node, axis: axis, gap: gap, minCell: minCell, minSizes: minSizes) }
            if containerAxis == axis {
                return parts.reduce(0, +) + gap * CGFloat(children.count - 1)
            }
            return parts.max() ?? 0
        }
    }
}
