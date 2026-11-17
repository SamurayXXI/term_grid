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
}
