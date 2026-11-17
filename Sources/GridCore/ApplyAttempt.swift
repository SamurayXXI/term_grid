import CoreGraphics

public enum ApplyStatus: String, Sendable {
    case ok
    case clamped
    case refused
    case timeout
    case invalidElement
    case superseded
}

public enum AccessFailure: Error, Equatable, Sendable {
    case timeout
    case invalidElement
    case failed
}

public enum AccessCall: String, Sendable {
    case sizeSettable
    case size
    case position
    case readback
}

public protocol WindowAccess {
    func querySizeSettable() -> Result<Bool, AccessFailure>
    func writeSize(_ size: CGSize) -> AccessFailure?
    func writePosition(_ origin: CGPoint) -> AccessFailure?
    func readFrame() -> Result<CGRect, AccessFailure>
}

public struct ApplyOutcome: Equatable, Sendable {
    public var status: ApplyStatus
    public var actual: CGRect?
    public var residual: CGFloat?
    public var attempts: Int

    public init(status: ApplyStatus, actual: CGRect? = nil, residual: CGFloat? = nil, attempts: Int = 1) {
        self.status = status
        self.actual = actual
        self.residual = residual
        self.attempts = attempts
    }
}

public enum ApplyAttempt {
    public static let tolerance: CGFloat = 1

    private struct Abort: Error {
        let failure: AccessFailure
        let call: AccessCall
    }

    public static func run<Window: WindowAccess>(
        _ window: Window,
        frame: CGRect,
        final: Bool,
        growing: Bool,
        outerEdges: OuterEdges,
        onTimeout: (Int, AccessCall) -> Void
    ) -> ApplyOutcome {
        let limit = final ? 2 : 1
        var attempt = 1
        while true {
            do throws(Abort) {
                var outcome = final
                    ? try performFinal(window, frame: frame, outerEdges: outerEdges)
                    : try performLive(window, frame: frame, growing: growing)
                outcome.attempts = attempt
                return outcome
            } catch {
                if error.failure == .invalidElement {
                    return ApplyOutcome(status: .invalidElement, attempts: attempt)
                }
                onTimeout(attempt, error.call)
                if attempt >= limit {
                    return ApplyOutcome(status: .timeout, attempts: attempt)
                }
                attempt += 1
            }
        }
    }

    public static func status(requested: CGRect, actual: CGRect) -> ApplyStatus {
        abs(requested.minX - actual.minX) <= tolerance
            && abs(requested.minY - actual.minY) <= tolerance
            && abs(requested.width - actual.width) <= tolerance
            && abs(requested.height - actual.height) <= tolerance
            ? .ok
            : .clamped
    }

    public static func residual(requested: CGRect, actual: CGRect, outerEdges: OuterEdges) -> CGFloat? {
        var deficits: [CGFloat] = []
        if outerEdges.isDisjoint(with: [.left, .right]) {
            deficits.append(requested.width - actual.width)
        }
        if outerEdges.isDisjoint(with: [.top, .bottom]) {
            deficits.append(requested.height - actual.height)
        }
        return deficits.filter { $0 > tolerance }.max()
    }

    private static func performLive<Window: WindowAccess>(
        _ window: Window,
        frame: CGRect,
        growing: Bool
    ) throws(Abort) -> ApplyOutcome {
        let calls: [AccessCall] = growing ? [.position, .size] : [.size, .position]
        for call in calls {
            let failure = call == .size ? window.writeSize(frame.size) : window.writePosition(frame.origin)
            if let failure {
                try escalate(failure, call)
                return ApplyOutcome(status: .refused)
            }
        }
        return ApplyOutcome(status: .ok)
    }

    private static func performFinal<Window: WindowAccess>(
        _ window: Window,
        frame: CGRect,
        outerEdges: OuterEdges
    ) throws(Abort) -> ApplyOutcome {
        var settable = false
        switch window.querySizeSettable() {
        case .success(let value):
            settable = value
        case .failure(let failure):
            try escalate(failure, .sizeSettable)
        }
        guard settable else {
            return try refuse(window, at: frame.origin)
        }
        if let failure = window.writeSize(frame.size) {
            try escalate(failure, .size)
            return try refuse(window, at: frame.origin)
        }
        if let failure = window.writePosition(frame.origin) {
            try escalate(failure, .position)
            return try refuse(window, at: nil)
        }
        guard var actual = try read(window) else {
            return ApplyOutcome(status: .refused)
        }
        if !sameSize(actual.size, frame.size) {
            if let failure = window.writeSize(frame.size) {
                try escalate(failure, .size)
                return ApplyOutcome(status: .refused, actual: actual)
            }
            if let reread = try read(window) {
                actual = reread
            }
        }
        let anchored = FitPolicy.anchoredOrigin(frame, actualSize: actual.size, outerEdges: outerEdges)
        if anchored != frame.origin {
            if let failure = window.writePosition(anchored) {
                try escalate(failure, .position)
                return ApplyOutcome(status: .refused, actual: actual)
            }
            if let reread = try read(window) {
                actual = reread
            }
        }
        return ApplyOutcome(
            status: status(requested: frame, actual: actual),
            actual: actual,
            residual: residual(requested: frame, actual: actual, outerEdges: outerEdges)
        )
    }

    private static func refuse<Window: WindowAccess>(_ window: Window, at origin: CGPoint?) throws(Abort) -> ApplyOutcome {
        if let origin, let failure = window.writePosition(origin) {
            try escalate(failure, .position)
        }
        return ApplyOutcome(status: .refused, actual: try read(window))
    }

    private static func read<Window: WindowAccess>(_ window: Window) throws(Abort) -> CGRect? {
        switch window.readFrame() {
        case .success(let frame):
            return frame
        case .failure(let failure):
            try escalate(failure, .readback)
            return nil
        }
    }

    private static func escalate(_ failure: AccessFailure, _ call: AccessCall) throws(Abort) {
        if failure != .failed {
            throw Abort(failure: failure, call: call)
        }
    }

    private static func sameSize(_ a: CGSize, _ b: CGSize) -> Bool {
        abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
