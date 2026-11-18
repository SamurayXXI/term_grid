import CoreGraphics

public struct GridInsets: Codable, Equatable, Sendable {
    public var left: CGFloat
    public var top: CGFloat
    public var right: CGFloat
    public var bottom: CGFloat

    public static let zero = GridInsets(left: 0, top: 0, right: 0, bottom: 0)

    public init(left: CGFloat, top: CGFloat, right: CGFloat, bottom: CGFloat) {
        self.left = left
        self.top = top
        self.right = right
        self.bottom = bottom
    }

    public func applying(_ moves: [EdgeMove], in base: CGRect, minSize: CGSize) -> GridInsets {
        var result = self
        let maxWidth = max(0, base.width - minSize.width)
        let maxHeight = max(0, base.height - minSize.height)
        for move in moves where move.divider == nil {
            switch move.edge {
            case .left: result.left = min(max(0, result.left + move.delta), maxWidth - result.right)
            case .right: result.right = min(max(0, result.right - move.delta), maxWidth - result.left)
            case .top: result.top = min(max(0, result.top + move.delta), maxHeight - result.bottom)
            case .bottom: result.bottom = min(max(0, result.bottom - move.delta), maxHeight - result.top)
            }
        }
        return result
    }

    public func inset(_ base: CGRect) -> CGRect {
        CGRect(
            x: base.minX + left,
            y: base.minY + top,
            width: max(0, base.width - left - right),
            height: max(0, base.height - top - bottom)
        )
    }
}
