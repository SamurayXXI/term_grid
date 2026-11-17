import Foundation

public struct ApplyScheduler<Key: Hashable, Group: Hashable, Ticket> {
    public enum Action {
        case idle
        case start(Ticket)
        case wait(until: TimeInterval)
    }

    public struct Submission {
        public let superseded: Ticket?
        public let action: Action
    }

    private struct Lane {
        let group: Group
        var inFlight = false
        var waiting = false
        var pending: Ticket?
        var lastStart: TimeInterval?

        var isActive: Bool {
            inFlight || pending != nil
        }
    }

    public let minInterval: TimeInterval
    private var lanes: [Key: Lane] = [:]

    public init(maxRate: Double) {
        minInterval = maxRate > 0 ? 1 / maxRate : 0
    }

    public mutating func submit(_ ticket: Ticket, for key: Key, group: Group, now: TimeInterval) -> Submission {
        var lane = lanes[key] ?? Lane(group: group)
        let superseded = lane.pending
        lane.pending = ticket
        lanes[key] = lane
        return Submission(superseded: superseded, action: advance(key, now: now))
    }

    public mutating func finish(_ key: Key, now: TimeInterval) -> Action {
        guard lanes[key] != nil else { return .idle }
        lanes[key]?.inFlight = false
        let action = advance(key, now: now)
        dropIdleLanes(now: now)
        return action
    }

    public mutating func removeGroup(_ group: Group) -> [Ticket] {
        let keys = lanes.filter { $0.value.group == group }.map(\.key)
        var pending: [Ticket] = []
        for key in keys {
            if let ticket = lanes.removeValue(forKey: key)?.pending {
                pending.append(ticket)
            }
        }
        return pending
    }

    var laneCount: Int {
        lanes.count
    }

    public mutating func timerFired(_ key: Key, now: TimeInterval) -> Action {
        guard lanes[key] != nil else { return .idle }
        lanes[key]?.waiting = false
        return advance(key, now: now)
    }

    public func isGroupActive(_ group: Group) -> Bool {
        lanes.values.contains { $0.group == group && $0.isActive }
    }

    private mutating func dropIdleLanes(now: TimeInterval) {
        lanes = lanes.filter { _, lane in
            lane.inFlight || lane.waiting || lane.pending != nil
                || lane.lastStart.map { now < $0 + minInterval } ?? false
        }
    }

    private mutating func advance(_ key: Key, now: TimeInterval) -> Action {
        guard var lane = lanes[key], !lane.inFlight, !lane.waiting, let ticket = lane.pending else {
            return .idle
        }
        if let lastStart = lane.lastStart, now < lastStart + minInterval {
            lane.waiting = true
            lanes[key] = lane
            return .wait(until: lastStart + minInterval)
        }
        lane.pending = nil
        lane.inFlight = true
        lane.lastStart = now
        lanes[key] = lane
        return .start(ticket)
    }
}

extension ApplyScheduler.Action: Equatable where Ticket: Equatable {}
