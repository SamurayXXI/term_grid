public struct OperationTracker<Group: Hashable> {
    private struct State {
        var depth = 0
        var awaitingIdle = false
    }

    private var states: [Group: State] = [:]

    public init() {}

    public mutating func begin(_ group: Group) -> Bool {
        var state = states[group] ?? State()
        let opensOperation = state.depth == 0 && !state.awaitingIdle
        state.depth += 1
        state.awaitingIdle = false
        states[group] = state
        return opensOperation
    }

    public mutating func end(_ group: Group, active: Bool) -> Bool {
        guard var state = states[group], state.depth > 0 else { return false }
        state.depth -= 1
        if state.depth > 0 {
            states[group] = state
            return false
        }
        if active {
            state.awaitingIdle = true
            states[group] = state
            return false
        }
        states[group] = nil
        return true
    }

    public mutating func becameIdle(_ group: Group) -> Bool {
        guard states[group]?.awaitingIdle == true else { return false }
        states[group] = nil
        return true
    }
}
