import CoreGraphics
import Testing
@testable import GridCore

private final class FakeWindow: WindowAccess {
    var frame: CGRect
    var settable: Result<Bool, AccessFailure> = .success(true)
    var failures: [AccessCall: AccessFailure] = [:]
    var failuresByOrdinal: [AccessCall: [Int: AccessFailure]] = [:]
    var widthStep: CGFloat?
    var firstSizeWidthLimit: CGFloat?
    private(set) var calls: [AccessCall] = []

    private func failure(for call: AccessCall) -> AccessFailure? {
        calls.append(call)
        let ordinal = calls.filter { $0 == call }.count
        return failures[call] ?? failuresByOrdinal[call]?[ordinal]
    }

    init(frame: CGRect) {
        self.frame = frame
    }

    func querySizeSettable() -> Result<Bool, AccessFailure> {
        if let failure = failure(for: .sizeSettable) {
            return .failure(failure)
        }
        return settable
    }

    func writeSize(_ size: CGSize) -> AccessFailure? {
        if let failure = failure(for: .size) {
            return failure
        }
        var width = size.width
        if let limit = firstSizeWidthLimit {
            width = min(width, limit)
            firstSizeWidthLimit = nil
        }
        if let step = widthStep {
            width = (width / step).rounded(.down) * step
        }
        frame.size = CGSize(width: width, height: size.height)
        return nil
    }

    func writePosition(_ origin: CGPoint) -> AccessFailure? {
        if let failure = failure(for: .position) {
            return failure
        }
        frame.origin = origin
        return nil
    }

    func readFrame() -> Result<CGRect, AccessFailure> {
        if let failure = failure(for: .readback) {
            return .failure(failure)
        }
        return .success(frame)
    }
}

@Suite struct ApplyAttemptTests {
    private let start = CGRect(x: 500, y: 300, width: 400, height: 300)
    private let target = CGRect(x: 0, y: 25, width: 720, height: 875)

    private func run(
        _ window: FakeWindow,
        frame: CGRect,
        final: Bool,
        growing: Bool = false,
        outerEdges: OuterEdges = []
    ) -> (ApplyOutcome, [String]) {
        var timeouts: [String] = []
        let outcome = ApplyAttempt.run(
            window,
            frame: frame,
            final: final,
            growing: growing,
            outerEdges: outerEdges
        ) { attempt, call in
            timeouts.append("\(attempt):\(call.rawValue)")
        }
        return (outcome, timeouts)
    }

    @Test func finalWritesSizeThenPositionAndReadsBack() {
        let window = FakeWindow(frame: start)
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size, .position, .readback])
        #expect(outcome == ApplyOutcome(status: .ok, actual: target, attempts: 1))
        #expect(timeouts.isEmpty)
    }

    @Test func secondSizeIsSentOnlyWhenReadbackDiffersByMoreThanOnePoint() {
        let window = FakeWindow(frame: start)
        window.firstSizeWidthLimit = 600
        let (outcome, _) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size, .position, .readback, .size, .readback])
        #expect(outcome.status == .ok)
        #expect(outcome.actual == target)
    }

    @Test func characterStepGivesClampedWithOneSecondSize() {
        let window = FakeWindow(frame: start)
        window.widthStep = 7
        let (outcome, _) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size, .position, .readback, .size, .readback])
        #expect(outcome.status == .clamped)
        #expect(outcome.actual?.width == 714)
        #expect(outcome.residual == 6)
    }

    @Test func firstTimeoutAbortsAttemptAndFinalRetriesExactlyOnce() {
        let window = FakeWindow(frame: start)
        window.failures[.position] = .timeout
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size, .position, .sizeSettable, .size, .position])
        #expect(outcome == ApplyOutcome(status: .timeout, attempts: 2))
        #expect(timeouts == ["1:position", "2:position"])
    }

    @Test func timeoutOnFirstCallStopsAllOtherCalls() {
        let window = FakeWindow(frame: start)
        window.failures[.sizeSettable] = .timeout
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .sizeSettable])
        #expect(outcome.status == .timeout)
        #expect(timeouts == ["1:sizeSettable", "2:sizeSettable"])
    }

    @Test func readbackTimeoutAbortsAttempt() {
        let window = FakeWindow(frame: start)
        window.failures[.readback] = .timeout
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(outcome.status == .timeout)
        #expect(outcome.actual == nil)
        #expect(timeouts == ["1:readback", "2:readback"])
    }

    @Test func liveTimeoutIsSingleAttempt() {
        let window = FakeWindow(frame: start)
        window.failures[.size] = .timeout
        let (outcome, timeouts) = run(window, frame: target, final: false)
        #expect(window.calls == [.size])
        #expect(outcome == ApplyOutcome(status: .timeout, attempts: 1))
        #expect(timeouts == ["1:size"])
    }

    @Test func liveWritesOnePairOrderedByGrowth() {
        let growing = FakeWindow(frame: start)
        let (grown, _) = run(growing, frame: target, final: false, growing: true)
        #expect(growing.calls == [.position, .size])
        #expect(grown == ApplyOutcome(status: .ok, actual: nil, attempts: 1))
        let shrinking = FakeWindow(frame: start)
        _ = run(shrinking, frame: target, final: false, growing: false)
        #expect(shrinking.calls == [.size, .position])
    }

    @Test func fixedSizeWindowIsRefusedAndOnlyMoved() {
        let window = FakeWindow(frame: start)
        window.settable = .success(false)
        let (outcome, _) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .position, .readback])
        #expect(outcome.status == .refused)
        #expect(outcome.actual == CGRect(origin: target.origin, size: start.size))
    }

    @Test func failedSizeWriteIsRefused() {
        let window = FakeWindow(frame: start)
        window.failures[.size] = .failed
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(outcome.status == .refused)
        #expect(outcome.attempts == 1)
        #expect(timeouts.isEmpty)
        #expect(outcome.actual?.size == start.size)
    }

    @Test func invalidElementStopsWithoutRetry() {
        let window = FakeWindow(frame: start)
        window.failures[.size] = .invalidElement
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size])
        #expect(outcome == ApplyOutcome(status: .invalidElement, attempts: 1))
        #expect(timeouts.isEmpty)
    }

    @Test func shortWindowWithOneOuterEdgeIsAnchoredToInnerEdge() {
        let window = FakeWindow(frame: start)
        window.widthStep = 7
        let (outcome, _) = run(window, frame: target, final: true, outerEdges: [.left, .top, .bottom])
        #expect(window.calls == [.sizeSettable, .size, .position, .readback, .size, .readback, .position, .readback])
        #expect(outcome.actual?.maxX == target.maxX)
        #expect(outcome.status == .clamped)
        #expect(outcome.residual == nil)
    }

    @Test func timeoutOnSecondSizeWriteRetriesWholeAttempt() {
        let window = FakeWindow(frame: start)
        window.firstSizeWidthLimit = 600
        window.failuresByOrdinal[.size] = [2: .timeout]
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [
            .sizeSettable, .size, .position, .readback, .size,
            .sizeSettable, .size, .position, .readback,
        ])
        #expect(timeouts == ["1:size"])
        #expect(outcome == ApplyOutcome(status: .ok, actual: target, attempts: 2))
    }

    @Test func timeoutOnAnchoringPositionWriteRetriesWholeAttempt() {
        let window = FakeWindow(frame: start)
        window.widthStep = 7
        window.failuresByOrdinal[.position] = [2: .timeout]
        let (outcome, timeouts) = run(window, frame: target, final: true, outerEdges: [.left, .top, .bottom])
        #expect(timeouts == ["1:position"])
        #expect(outcome.attempts == 2)
        #expect(outcome.status == .clamped)
        #expect(outcome.actual?.maxX == target.maxX)
    }

    @Test func timeoutOnAnchoringReadbackRetriesWholeAttempt() {
        let window = FakeWindow(frame: start)
        window.widthStep = 7
        window.failuresByOrdinal[.readback] = [3: .timeout]
        let (outcome, timeouts) = run(window, frame: target, final: true, outerEdges: [.left, .top, .bottom])
        #expect(timeouts == ["1:readback"])
        #expect(outcome.attempts == 2)
        #expect(outcome.status == .clamped)
        #expect(outcome.actual?.maxX == target.maxX)
    }

    @Test func invalidElementOnReadbackStopsWithoutRetry() {
        let window = FakeWindow(frame: start)
        window.failures[.readback] = .invalidElement
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size, .position, .readback])
        #expect(outcome == ApplyOutcome(status: .invalidElement, attempts: 1))
        #expect(timeouts.isEmpty)
    }

    @Test func failedRereadAfterSecondSizeKeepsLastKnownActual() {
        let window = FakeWindow(frame: start)
        window.firstSizeWidthLimit = 600
        window.failuresByOrdinal[.readback] = [2: .failed]
        let (outcome, timeouts) = run(window, frame: target, final: true)
        #expect(window.calls == [.sizeSettable, .size, .position, .readback, .size, .readback])
        #expect(timeouts.isEmpty)
        #expect(outcome.actual == CGRect(x: target.minX, y: target.minY, width: 600, height: target.height))
        #expect(outcome.status == .clamped)
        #expect(outcome.residual == 120)
        #expect(outcome.attempts == 1)
    }

    @Test func failedRereadAfterAnchoringKeepsLastKnownActual() {
        let window = FakeWindow(frame: start)
        window.widthStep = 7
        window.failuresByOrdinal[.readback] = [3: .failed]
        let (outcome, timeouts) = run(window, frame: target, final: true, outerEdges: [.left, .top, .bottom])
        #expect(timeouts.isEmpty)
        #expect(outcome.actual == CGRect(x: target.minX, y: target.minY, width: 714, height: target.height))
        #expect(outcome.status == .clamped)
        #expect(outcome.attempts == 1)
    }

    @Test func statusToleratesOnePoint() {
        let nearly = target.insetBy(dx: 0.5, dy: 0.5)
        #expect(ApplyAttempt.status(requested: target, actual: nearly) == .ok)
        #expect(ApplyAttempt.status(requested: target, actual: target.offsetBy(dx: 2, dy: 0)) == .clamped)
    }
}
