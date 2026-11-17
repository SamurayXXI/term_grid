public struct CellID: Hashable, Sendable {
    public let rawValue: Int

    public init(_ rawValue: Int) {
        self.rawValue = rawValue
    }
}
