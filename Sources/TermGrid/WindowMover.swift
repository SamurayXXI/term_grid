import ApplicationServices
import Foundation
import GridCore
import os

let applyLogger = Logger(subsystem: "local.termgrid", category: "apply")

func logApply(_ message: String) {
    applyLogger.notice("\(message, privacy: .public)")
}

enum ApplyReason: String {
    case live
    case drag
    case fit
    case apply
}

struct ApplyResult {
    let window: AXWindow
    let requested: CGRect
    let actual: CGRect?
    let status: ApplyStatus
    let generation: Int
    let final: Bool
}

@MainActor
final class WindowMover {
    nonisolated static let defaultMaxApplyHz: Double = 30

    private struct Request {
        let window: AXWindow
        let frame: CGRect
        let generation: Int
        let final: Bool
        let reason: ApplyReason
        let cell: CellID?
        let outerEdges: OuterEdges
        let completion: @MainActor (ApplyResult) -> Void
    }

    private var scheduler: ApplyScheduler<AXWindow, pid_t, Int>
    private var operations = OperationTracker<pid_t>()
    private var lanes: [pid_t: ProcessLane] = [:]
    private var requests: [Int: Request] = [:]
    private var lastFrames: [AXWindow: CGRect] = [:]
    private var nextTicket = 0

    init(maxApplyHz: Double = WindowMover.defaultMaxApplyHz) {
        scheduler = ApplyScheduler(maxRate: maxApplyHz)
    }

    func request(
        _ window: AXWindow,
        frame: CGRect,
        generation: Int,
        final: Bool,
        reason: ApplyReason? = nil,
        cell: CellID? = nil,
        outerEdges: OuterEdges = [],
        completion: @escaping @MainActor (ApplyResult) -> Void
    ) {
        nextTicket += 1
        let ticket = nextTicket
        requests[ticket] = Request(
            window: window,
            frame: frame,
            generation: generation,
            final: final,
            reason: reason ?? (final ? .apply : .live),
            cell: cell,
            outerEdges: outerEdges,
            completion: completion
        )
        let submission = scheduler.submit(ticket, for: window, group: window.pid, now: Self.now())
        if let superseded = submission.superseded {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.deliver(superseded, outcome: ApplyOutcome(status: .superseded, attempts: 0))
                }
            }
        }
        perform(submission.action, for: window)
    }

    func beginOperation(_ pids: Set<pid_t>) {
        for pid in pids where operations.begin(pid) {
            let lane = lane(for: pid)
            lane.queue.async {
                lane.disableEnhancedUI()
            }
        }
    }

    func endOperation(_ pids: Set<pid_t>) {
        for pid in pids where operations.end(pid, active: scheduler.isGroupActive(pid)) {
            restoreEnhancedUI(pid)
        }
    }

    func queue(for pid: pid_t) -> DispatchQueue {
        lane(for: pid).queue
    }

    func readFrame(_ window: AXWindow, completion: @escaping @MainActor (Result<CGRect, AccessFailure>) -> Void) {
        lane(for: window.pid).queue.async {
            let result = window.readFrame()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(result)
                }
            }
        }
    }

    @discardableResult
    func forget(_ pid: pid_t) -> Bool {
        operations.forget(pid)
        lastFrames = lastFrames.filter { $0.key.pid != pid }
        return lanes.removeValue(forKey: pid) != nil
    }

    func restoreAllEnhancedUI(timeout: TimeInterval) {
        let group = DispatchGroup()
        for lane in lanes.values {
            group.enter()
            lane.queue.async {
                lane.restoreEnhancedUI()
                group.leave()
            }
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            logApply("enhanced ui restore timeout")
        }
    }

    #if DEBUG
    func whenDrained(_ pids: Set<pid_t>, completion: @escaping @MainActor () -> Void) {
        let group = DispatchGroup()
        for pid in pids {
            group.enter()
            lane(for: pid).queue.async {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MainActor.assumeIsolated {
                completion()
            }
        }
    }
    #endif

    private func lane(for pid: pid_t) -> ProcessLane {
        if let lane = lanes[pid] {
            return lane
        }
        let lane = ProcessLane(pid: pid)
        lanes[pid] = lane
        return lane
    }

    private func perform(_ action: ApplyScheduler<AXWindow, pid_t, Int>.Action, for window: AXWindow) {
        switch action {
        case .idle:
            break
        case .start(let ticket):
            dispatchAttempt(ticket, for: window)
        case .wait(let until):
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, until - Self.now())) {
                MainActor.assumeIsolated {
                    self.perform(self.scheduler.timerFired(window, now: Self.now()), for: window)
                }
            }
        }
    }

    private func dispatchAttempt(_ ticket: Int, for window: AXWindow) {
        guard let request = requests[ticket] else {
            attemptFinished(ticket, window: window, outcome: ApplyOutcome(status: .refused, attempts: 0))
            return
        }
        let frame = request.frame
        let final = request.final
        let outerEdges = request.outerEdges
        let cellText = Self.describe(request.cell)
        let growing = lastFrames[window].map { frame.width > $0.width || frame.height > $0.height } ?? false
        lastFrames[window] = frame
        lane(for: window.pid).queue.async {
            let outcome = ApplyAttempt.run(
                window,
                frame: frame,
                final: final,
                growing: growing,
                outerEdges: outerEdges
            ) { attempt, call in
                logApply("ax timeout pid=\(window.pid) cell=\(cellText) attempt=\(attempt) call=\(call.rawValue)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.attemptFinished(ticket, window: window, outcome: outcome)
                }
            }
        }
    }

    private func attemptFinished(_ ticket: Int, window: AXWindow, outcome: ApplyOutcome) {
        deliver(ticket, outcome: outcome)
        perform(scheduler.finish(window, now: Self.now()), for: window)
        if !scheduler.isGroupActive(window.pid), operations.becameIdle(window.pid) {
            restoreEnhancedUI(window.pid)
        }
    }

    private func deliver(_ ticket: Int, outcome: ApplyOutcome) {
        guard let request = requests.removeValue(forKey: ticket) else { return }
        let cellText = Self.describe(request.cell)
        logApply(
            "apply final=\(request.final) reason=\(request.reason.rawValue) cell=\(cellText)"
                + " requested=\(Self.describe(request.frame)) actual=\(Self.describe(outcome.actual))"
                + " status=\(outcome.status.rawValue) generation=\(request.generation)"
        )
        if let residual = outcome.residual {
            logApply("fit residual cell=\(cellText) pt=\(String(format: "%.1f", residual))")
        }
        if let actual = outcome.actual {
            lastFrames[request.window] = actual
        }
        request.completion(ApplyResult(
            window: request.window,
            requested: request.frame,
            actual: outcome.actual,
            status: outcome.status,
            generation: request.generation,
            final: request.final
        ))
    }

    private func restoreEnhancedUI(_ pid: pid_t) {
        guard let lane = lanes[pid] else { return }
        lane.queue.async {
            lane.restoreEnhancedUI()
        }
    }

    private nonisolated static func now() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private nonisolated static func describe(_ cell: CellID?) -> String {
        cell.map { String($0.rawValue) } ?? "-"
    }

    private nonisolated static func describe(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(format: "[%.1f,%.1f,%.1f,%.1f]", rect.minX, rect.minY, rect.width, rect.height)
    }
}

private final class ProcessLane: @unchecked Sendable {
    private static let enhancedUIAttribute = "AXEnhancedUserInterface" as CFString

    let pid: pid_t
    let queue: DispatchQueue
    private lazy var application: AXUIElement = makeApplicationElement()
    private var restoresEnhancedUI = false

    init(pid: pid_t) {
        self.pid = pid
        queue = DispatchQueue(label: "termgrid.ax.\(pid)")
    }

    func disableEnhancedUI() {
        dispatchPrecondition(condition: .onQueue(queue))
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(application, Self.enhancedUIAttribute, &value)
        if error == .cannotComplete {
            logApply("ax timeout pid=\(pid) call=enhancedUIRead")
            return
        }
        guard error == .success, (value as? Bool) == true else { return }
        let result = AXUIElementSetAttributeValue(application, Self.enhancedUIAttribute, kCFBooleanFalse)
        restoresEnhancedUI = result == .success || result == .cannotComplete
        logApply("enhanced ui disabled pid=\(pid) result=\(result.rawValue)")
    }

    func restoreEnhancedUI() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard restoresEnhancedUI else { return }
        restoresEnhancedUI = false
        let result = AXUIElementSetAttributeValue(application, Self.enhancedUIAttribute, kCFBooleanTrue)
        logApply("enhanced ui restored pid=\(pid) result=\(result.rawValue)")
    }

    private func makeApplicationElement() -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, AXWindow.messagingTimeout)
        return element
    }
}
