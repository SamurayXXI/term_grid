import Foundation

public enum LayoutPreset: CaseIterable, Sendable {
    case twoColumns
    case threeColumns
    case twoRows
    case grid2x2
    case onePlusTwo
    case grid2x3
}

public enum LayoutOps {
    public static func split(_ tree: LayoutNode, cell: CellID, axis: Axis) -> LayoutNode {
        guard tree.contains(cell) else { return tree }
        let newCell = CellID((tree.leafIDs.map(\.rawValue).max() ?? -1) + 1)
        let newContainer = ContainerID((tree.containerIDs.map(\.rawValue).max() ?? -1) + 1)
        return replacingLeaf(in: tree, cell: cell) {
            .container(newContainer, axis, [
                LayoutChild(node: .leaf(cell), ratio: 0.5),
                LayoutChild(node: .leaf(newCell), ratio: 0.5),
            ])
        }
    }

    public static func close(_ tree: LayoutNode, cell: CellID) -> LayoutNode? {
        guard tree.contains(cell) else { return tree }
        return removingLeaf(from: tree, cell: cell)
    }

    public static func preset(_ preset: LayoutPreset) -> LayoutNode {
        var builder = Builder()
        switch preset {
        case .twoColumns:
            return builder.row(count: 2)
        case .threeColumns:
            return builder.row(count: 3)
        case .twoRows:
            return builder.stack([builder.leaf(), builder.leaf()])
        case .grid2x2:
            return builder.stack([builder.row(count: 2), builder.row(count: 2)])
        case .onePlusTwo:
            let left = builder.leaf()
            let right = builder.stack([builder.leaf(), builder.leaf()])
            return builder.row([left, right])
        case .grid2x3:
            return builder.stack([builder.row(count: 3), builder.row(count: 3)])
        }
    }

    public static func autoLayout(_ count: Int) -> LayoutNode? {
        guard count > 0 else { return nil }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        var builder = Builder()
        var rows: [LayoutNode] = []
        var remaining = count
        while remaining > 0 {
            let inRow = min(columns, remaining)
            rows.append(builder.row(count: inRow))
            remaining -= inRow
        }
        return builder.stack(rows)
    }

    private static func replacingLeaf(
        in node: LayoutNode,
        cell: CellID,
        with replacement: () -> LayoutNode
    ) -> LayoutNode {
        switch node {
        case .leaf(let id):
            return id == cell ? replacement() : node
        case .container(let id, let axis, let children):
            let mapped = children.map {
                LayoutChild(node: replacingLeaf(in: $0.node, cell: cell, with: replacement), ratio: $0.ratio)
            }
            return .container(id, axis, mapped)
        }
    }

    private static func removingLeaf(from node: LayoutNode, cell: CellID) -> LayoutNode? {
        switch node {
        case .leaf(let id):
            return id == cell ? nil : node
        case .container(let id, let axis, let children):
            var kept: [LayoutChild] = []
            for child in children {
                if let remaining = removingLeaf(from: child.node, cell: cell) {
                    kept.append(LayoutChild(node: remaining, ratio: child.ratio))
                }
            }
            if kept.isEmpty { return nil }
            if kept.count == 1 { return kept[0].node }
            let total = kept.reduce(0) { $0 + $1.ratio }
            let normalized = kept.map { LayoutChild(node: $0.node, ratio: $0.ratio / total) }
            return .container(id, axis, normalized)
        }
    }

    private struct Builder {
        var nextCell = 0
        var nextContainer = 0

        mutating func leaf() -> LayoutNode {
            defer { nextCell += 1 }
            return .leaf(CellID(nextCell))
        }

        mutating func row(count: Int) -> LayoutNode {
            let leaves = (0..<count).map { _ in leaf() }
            return row(leaves)
        }

        mutating func row(_ nodes: [LayoutNode]) -> LayoutNode {
            container(.horizontal, nodes)
        }

        mutating func stack(_ nodes: [LayoutNode]) -> LayoutNode {
            container(.vertical, nodes)
        }

        private mutating func container(_ axis: Axis, _ nodes: [LayoutNode]) -> LayoutNode {
            if nodes.count == 1 { return nodes[0] }
            let id = ContainerID(nextContainer)
            nextContainer += 1
            let ratio = 1.0 / Double(nodes.count)
            return .container(id, axis, nodes.map { LayoutChild(node: $0, ratio: ratio) })
        }
    }
}
