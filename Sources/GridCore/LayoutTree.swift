public enum Axis: String, Codable, Sendable {
    case horizontal
    case vertical
}

public struct ContainerID: Hashable, Codable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}

extension CellID: Codable {
    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct LayoutChild: Equatable, Codable, Sendable {
    public var node: LayoutNode
    public var ratio: Double

    public init(node: LayoutNode, ratio: Double) {
        self.node = node
        self.ratio = ratio
    }
}

public indirect enum LayoutNode: Equatable, Codable, Sendable {
    case leaf(CellID)
    case container(ContainerID, Axis, [LayoutChild])

    public var leafIDs: [CellID] {
        switch self {
        case .leaf(let id):
            return [id]
        case .container(_, _, let children):
            return children.flatMap { $0.node.leafIDs }
        }
    }

    public var containerIDs: [ContainerID] {
        switch self {
        case .leaf:
            return []
        case .container(let id, _, let children):
            return [id] + children.flatMap { $0.node.containerIDs }
        }
    }

    public func contains(_ cell: CellID) -> Bool {
        leafIDs.contains(cell)
    }
}
