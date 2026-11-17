import CoreGraphics

public enum FrameSolver {
    public static func frames(
        _ tree: LayoutNode,
        in rect: CGRect,
        gap: CGFloat,
        minCell: CGSize
    ) -> [CellID: CGRect] {
        var result: [CellID: CGRect] = [:]
        solve(tree, rect: rect, gap: gap, minCell: minCell, into: &result)
        return result
    }

    private static func solve(
        _ node: LayoutNode,
        rect: CGRect,
        gap: CGFloat,
        minCell: CGSize,
        into result: inout [CellID: CGRect]
    ) {
        switch node {
        case .leaf(let id):
            result[id] = rect
        case .container(_, let axis, let children):
            let horizontal = axis == .horizontal
            let length = horizontal ? rect.width : rect.height
            let available = length - gap * CGFloat(children.count - 1)
            let minimum = horizontal ? minCell.width : minCell.height
            let sizes = distribute(children.map(\.ratio), total: available, minimum: minimum)
            var offset: CGFloat = 0
            for (child, size) in zip(children, sizes) {
                let childRect = horizontal
                    ? CGRect(x: rect.minX + offset, y: rect.minY, width: size, height: rect.height)
                    : CGRect(x: rect.minX, y: rect.minY + offset, width: rect.width, height: size)
                solve(child.node, rect: childRect, gap: gap, minCell: minCell, into: &result)
                offset += size + gap
            }
        }
    }

    private static func distribute(_ ratios: [Double], total: CGFloat, minimum: CGFloat) -> [CGFloat] {
        let count = ratios.count
        let floorSize = minimum.rounded(.up)
        let canPin = floorSize > 0 && floorSize * CGFloat(count) <= total
        var pinned = Set<Int>()
        var sizes = [CGFloat](repeating: 0, count: count)
        while true {
            let free = (0..<count).filter { !pinned.contains($0) }
            let freeTotal = total - floorSize * CGFloat(pinned.count)
            let ratioSum = free.reduce(0.0) { $0 + ratios[$1] }
            var cumulativeRatio = 0.0
            var previousEdge: CGFloat = 0
            for index in free {
                cumulativeRatio += ratios[index]
                let edge = index == free.last ? freeTotal : (freeTotal * CGFloat(cumulativeRatio / ratioSum)).rounded()
                sizes[index] = edge - previousEdge
                previousEdge = edge
            }
            let undersized = canPin ? free.filter { sizes[$0] < floorSize } : []
            if undersized.isEmpty { break }
            pinned.formUnion(undersized)
            for index in undersized { sizes[index] = floorSize }
        }
        for index in pinned { sizes[index] = floorSize }
        if pinned.count == count, let last = sizes.indices.last {
            sizes[last] += total - sizes.reduce(0, +)
        }
        return sizes
    }
}
