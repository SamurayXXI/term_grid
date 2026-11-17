import CoreGraphics

public enum ExternalChange: String, Sendable {
    case moved
    case resized

    public static let threshold: CGFloat = 20

    public static func detect(reference: CGRect, current: CGRect) -> ExternalChange? {
        if abs(current.width - reference.width) > threshold || abs(current.height - reference.height) > threshold {
            return .resized
        }
        if abs(current.minX - reference.minX) > threshold || abs(current.minY - reference.minY) > threshold {
            return .moved
        }
        return nil
    }
}

public struct BindingRegistry<Window: Hashable> {
    public struct Change {
        public let added: [(id: Int, window: Window)]
        public let removed: [(id: Int, window: Window)]
    }

    private var windows: [Int: Window] = [:]
    private var ids: [Window: Int] = [:]
    private var nextID = 1

    public init() {}

    public func window(for id: Int) -> Window? {
        windows[id]
    }

    public func id(for window: Window) -> Int? {
        ids[window]
    }

    public mutating func sync(_ bound: Set<Window>) -> Change {
        let removed = ids.filter { !bound.contains($0.key) }
            .map { (id: $0.value, window: $0.key) }
            .sorted { $0.id < $1.id }
        for entry in removed {
            ids[entry.window] = nil
            windows[entry.id] = nil
        }
        var added: [(id: Int, window: Window)] = []
        for window in bound where ids[window] == nil {
            let id = nextID
            nextID += 1
            ids[window] = id
            windows[id] = window
            added.append((id: id, window: window))
        }
        return Change(added: added, removed: removed)
    }
}

public struct EventReadGate<Key: Hashable> {
    private var dirty: [Key: Bool] = [:]

    public init() {}

    public mutating func request(_ key: Key) -> Bool {
        if dirty[key] != nil {
            dirty[key] = true
            return false
        }
        dirty[key] = false
        return true
    }

    public mutating func finished(_ key: Key) -> Bool {
        guard dirty[key] == true else {
            dirty[key] = nil
            return false
        }
        dirty[key] = false
        return true
    }
}
