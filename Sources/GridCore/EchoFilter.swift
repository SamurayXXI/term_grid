import CoreGraphics
import Foundation

public enum EchoClassification: Equatable, Sendable {
    case echo
    case external
    case recovered
}

public enum EchoDecision: Equatable, Sendable {
    case echo
    case external
    case recovered
    case afterWrites
    case recheck(at: TimeInterval)
}

public struct EchoFilter<Window: Hashable & Sendable>: Sendable {
    public static var settleInterval: TimeInterval { 0.25 }
    public static var tolerance: CGFloat { 2 }

    private struct State: Sendable {
        var writes = 0
        var timedOut = false
        var lastActual: CGRect?
        var completedAt: TimeInterval?
    }

    private var states: [Window: State] = [:]

    public init() {}

    public mutating func markPending(_ window: Window) {
        states[window, default: State()].writes += 1
    }

    public mutating func markCompleted(_ window: Window, actual: CGRect, at time: TimeInterval) {
        let writes = max(0, (states[window]?.writes ?? 0) - 1)
        states[window] = State(writes: writes, timedOut: false, lastActual: actual, completedAt: time)
    }

    public mutating func markTimedOut(_ window: Window) {
        var state = states[window, default: State()]
        state.writes = max(0, state.writes - 1)
        state.timedOut = true
        states[window] = state
    }

    public mutating func markSettled(_ window: Window) {
        guard var state = states[window] else { return }
        state.writes = max(0, state.writes - 1)
        states[window] = state
    }

    public mutating func forget(_ window: Window) {
        states[window] = nil
    }

    public func isPending(_ window: Window) -> Bool {
        (states[window]?.writes ?? 0) > 0
    }

    public func decide(_ window: Window, current: CGRect, at time: TimeInterval) -> EchoDecision {
        guard let state = states[window] else { return .external }
        if state.writes > 0 { return .afterWrites }
        if let last = state.lastActual, Self.matches(last, current) { return .echo }
        if let completedAt = state.completedAt, time - completedAt < Self.settleInterval {
            return .recheck(at: completedAt + Self.settleInterval)
        }
        return state.timedOut ? .recovered : .external
    }

    public func classify(_ window: Window, current: CGRect, at time: TimeInterval) -> EchoClassification {
        guard let state = states[window] else { return .external }
        if state.writes > 0 { return .echo }
        if let completedAt = state.completedAt, time - completedAt < Self.settleInterval { return .echo }
        if let last = state.lastActual, Self.matches(last, current) { return .echo }
        return state.timedOut ? .recovered : .external
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= tolerance
            && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance
            && abs(a.height - b.height) <= tolerance
    }
}
