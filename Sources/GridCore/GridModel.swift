import CoreGraphics

public enum CellStatus: String, Sendable {
    case ok
    case doesNotFit
    case detached
    case empty
    case notResponding
}

public struct GridModel<Window: Hashable & Sendable>: Sendable {
    public private(set) var tree: LayoutNode
    public private(set) var bindings: [CellID: Window] = [:]
    public private(set) var minSizes: [Window: CGSize] = [:]
    private var statuses: [CellID: CellStatus] = [:]
    private var generations: [Window: Int] = [:]

    public init(tree: LayoutNode) {
        self.tree = tree
    }

    public var cells: [CellID] {
        tree.leafIDs
    }

    public func status(of cell: CellID) -> CellStatus {
        if let status = statuses[cell] {
            return status
        }
        return bindings[cell] == nil ? .empty : .ok
    }

    public func cell(of window: Window) -> CellID? {
        bindings.first { $0.value == window }?.key
    }

    public var cellMinSizes: [CellID: CGSize] {
        bindings.reduce(into: [:]) { result, entry in
            if let size = minSizes[entry.value] {
                result[entry.key] = size
            }
        }
    }

    @discardableResult
    public mutating func assign(_ window: Window, to cell: CellID) -> [CellID] {
        guard tree.contains(cell) else { return [] }
        let previousCell = self.cell(of: window)
        if previousCell == cell { return [cell] }
        let displaced = bindings[cell]
        bindings[cell] = window
        statuses[cell] = nil
        guard let previousCell else { return [cell] }
        bindings[previousCell] = displaced
        statuses[previousCell] = nil
        return [cell, previousCell]
    }

    public mutating func applyPreset(_ newTree: LayoutNode) {
        let newOrder = newTree.leafIDs
        var rebound: [CellID: Window] = [:]
        for (index, oldCell) in tree.leafIDs.enumerated() where index < newOrder.count {
            if let window = bindings[oldCell] {
                rebound[newOrder[index]] = window
            }
        }
        tree = newTree
        bindings = rebound
        statuses = [:]
    }

    @discardableResult
    public mutating func autoArrange(_ windows: [Window]) -> Bool {
        var seen = Set<Window>()
        let unique = windows.filter { seen.insert($0).inserted }
        guard let newTree = LayoutOps.autoLayout(unique.count) else { return false }
        tree = newTree
        bindings = Dictionary(uniqueKeysWithValues: zip(newTree.leafIDs, unique))
        statuses = [:]
        return true
    }

    @discardableResult
    public mutating func split(_ cell: CellID, axis: Axis) -> Bool {
        guard tree.contains(cell) else { return false }
        tree = LayoutOps.split(tree, cell: cell, axis: axis)
        return true
    }

    @discardableResult
    public mutating func close(_ cell: CellID) -> Bool {
        guard tree.contains(cell) else { return false }
        bindings[cell] = nil
        statuses[cell] = nil
        if let remaining = LayoutOps.close(tree, cell: cell) {
            tree = remaining
        }
        return true
    }

    public mutating func replaceTree(_ newTree: LayoutNode) {
        tree = newTree
    }

    public mutating func unbind(_ cell: CellID) {
        bindings[cell] = nil
        statuses[cell] = nil
    }

    public mutating func markDetached(_ cell: CellID) {
        bindings[cell] = nil
        statuses[cell] = .detached
    }

    public mutating func reset() {
        bindings = [:]
        statuses = [:]
    }

    public mutating func nextGeneration(for window: Window) -> Int {
        let next = (generations[window] ?? 0) + 1
        generations[window] = next
        return next
    }

    public func isCurrent(generation: Int, window: Window, cell: CellID) -> Bool {
        generations[window] == generation && bindings[cell] == window
    }

    @discardableResult
    public mutating func complete(
        window: Window,
        cell: CellID,
        generation: Int,
        status: ApplyStatus,
        requested: CGRect,
        actual: CGRect?
    ) -> Bool {
        guard status != .superseded, isCurrent(generation: generation, window: window, cell: cell) else {
            return false
        }
        switch status {
        case .ok:
            statuses[cell] = nil
        case .clamped:
            statuses[cell] = nil
            if let actual, let size = Self.minSize(requested: requested, actual: actual) {
                let known = minSizes[window] ?? .zero
                minSizes[window] = CGSize(width: max(known.width, size.width), height: max(known.height, size.height))
            }
        case .refused:
            statuses[cell] = .doesNotFit
        case .timeout:
            statuses[cell] = .notResponding
        case .invalidElement:
            unbind(cell)
        case .superseded:
            return false
        }
        return true
    }

    public static func minSize(requested: CGRect, actual: CGRect) -> CGSize? {
        let width = actual.width - requested.width > ApplyAttempt.tolerance ? actual.width : 0
        let height = actual.height - requested.height > ApplyAttempt.tolerance ? actual.height : 0
        return width > 0 || height > 0 ? CGSize(width: width, height: height) : nil
    }
}
