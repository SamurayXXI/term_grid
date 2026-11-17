import CoreGraphics
import Testing
@testable import GridCore

@Suite struct EchoFilterTests {
    private let window = 1
    private let actual = CGRect(x: 100, y: 100, width: 600, height: 400)

    private func shifted(_ dx: CGFloat) -> CGRect {
        actual.offsetBy(dx: dx, dy: 0)
    }

    @Test func pendingNotificationIsEchoForAnyFrame() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        #expect(filter.classify(window, current: shifted(500), at: 0) == .echo)
    }

    @Test func notificationShortlyAfterCompletionIsEcho() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.markCompleted(window, actual: actual, at: 10)
        #expect(filter.classify(window, current: shifted(30), at: 10.1) == .echo)
    }

    @Test func offsetNotificationLongAfterCompletionIsExternal() {
        var filter = EchoFilter<Int>()
        filter.markCompleted(window, actual: actual, at: 10)
        #expect(filter.classify(window, current: shifted(30), at: 11) == .external)
    }

    @Test func frameWithinTwoPointsOfLastActualIsEcho() {
        var filter = EchoFilter<Int>()
        filter.markCompleted(window, actual: actual, at: 10)
        #expect(filter.classify(window, current: shifted(2), at: 11) == .echo)
        #expect(filter.classify(window, current: shifted(3), at: 11) == .external)
    }

    @Test func timeoutThenOffsetNotificationIsRecoveredUntilNextCompletion() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.markTimedOut(window)
        #expect(filter.classify(window, current: shifted(30), at: 11) == .recovered)
        filter.markCompleted(window, actual: actual, at: 12)
        #expect(filter.classify(window, current: shifted(30), at: 13) == .external)
    }

    @Test func unknownWindowIsExternal() {
        let filter = EchoFilter<Int>()
        #expect(filter.classify(window, current: actual, at: 0) == .external)
    }

    @Test func pendingLastsUntilEveryWriteHasCompleted() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.markPending(window)
        filter.markCompleted(window, actual: actual, at: 10)
        #expect(filter.isPending(window))
        #expect(filter.classify(window, current: shifted(500), at: 20) == .echo)
        filter.markCompleted(window, actual: actual, at: 11)
        #expect(!filter.isPending(window))
        #expect(filter.classify(window, current: shifted(500), at: 20) == .external)
    }

    @Test func settledWriteEndsPendingWithoutChangingLastActual() {
        var filter = EchoFilter<Int>()
        filter.markCompleted(window, actual: actual, at: 10)
        filter.markPending(window)
        filter.markSettled(window)
        #expect(!filter.isPending(window))
        #expect(filter.classify(window, current: shifted(1), at: 20) == .echo)
        #expect(filter.classify(window, current: shifted(30), at: 20) == .external)
    }

    @Test func timeoutWithAnotherWriteInFlightStaysPendingThenRecovers() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.markPending(window)
        filter.markTimedOut(window)
        #expect(filter.isPending(window))
        filter.markSettled(window)
        #expect(filter.classify(window, current: shifted(30), at: 20) == .recovered)
    }

    @Test func forgetDropsState() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.forget(window)
        #expect(!filter.isPending(window))
        #expect(filter.classify(window, current: actual, at: 0) == .external)
    }

    @Test func settledOnUnknownWindowIsNoOp() {
        var filter = EchoFilter<Int>()
        filter.markSettled(window)
        #expect(!filter.isPending(window))
    }

    @Test func externalChangeInsideSettleWindowIsRecheckedNotDropped() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.markCompleted(window, actual: actual, at: 10)
        #expect(filter.decide(window, current: shifted(100), at: 10.03) == .recheck(at: 10.25))
        #expect(filter.decide(window, current: shifted(100), at: 10.3) == .external)
    }

    @Test func decideTreatsLastActualMatchAsEchoEvenInsideSettleWindow() {
        var filter = EchoFilter<Int>()
        filter.markCompleted(window, actual: actual, at: 10)
        #expect(filter.decide(window, current: shifted(1), at: 10.01) == .echo)
    }

    @Test func decideWhilePendingWaitsForWrites() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        #expect(filter.decide(window, current: shifted(100), at: 0) == .afterWrites)
    }

    @Test func decideAfterTimeoutRecovers() {
        var filter = EchoFilter<Int>()
        filter.markPending(window)
        filter.markTimedOut(window)
        #expect(filter.decide(window, current: shifted(30), at: 5) == .recovered)
        #expect(filter.decide(window, current: shifted(30), at: 5) != .echo)
    }

    @Test func decideOnUnknownWindowIsExternal() {
        let filter = EchoFilter<Int>()
        #expect(filter.decide(window, current: actual, at: 0) == .external)
    }
}
