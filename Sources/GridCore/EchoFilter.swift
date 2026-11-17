import CoreGraphics
import Foundation

public enum EchoClassification: Equatable, Sendable {
    case echo
    case external
    case recovered
}

public struct EchoFilter<Window: Hashable & Sendable>: Sendable {
    public static var settleInterval: TimeInterval { 0.25 }
    public static var tolerance: CGFloat { 2 }

    private struct State: Sendable {
        var pending = false
        var timedOut = false
        var lastActual: CGRect?
        var completedAt: TimeInterval?
    }

    private var states: [Window: State] = [:]

    public init() {}

    public mutating func markPending(_ window: Window) {
        states[window, default: State()].pending = true
    }

    public mutating func markCompleted(_ window: Window, actual: CGRect, at time: TimeInterval) {
        states[window] = State(pending: false, timedOut: false, lastActual: actual, completedAt: time)
    }

    public mutating func markTimedOut(_ window: Window) {
        var state = states[window, default: State()]
        state.pending = false
        state.timedOut = true
        states[window] = state
    }

    public func classify(_ window: Window, current: CGRect, at time: TimeInterval) -> EchoClassification {
        guard let state = states[window] else { return .external }
        if state.pending { return .echo }
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
