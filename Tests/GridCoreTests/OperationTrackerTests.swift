import Testing
@testable import GridCore

@Suite struct OperationTrackerTests {
    @Test func firstBeginOpensAndLastEndCloses() {
        var tracker = OperationTracker<Int>()
        let outer = tracker.begin(1)
        let nested = tracker.begin(1)
        let innerEnd = tracker.end(1, active: false)
        let outerEnd = tracker.end(1, active: false)
        #expect([outer, nested, innerEnd, outerEnd] == [true, false, false, true])
    }

    @Test func endWhileWritesRemainDefersRestoreUntilIdle() {
        var tracker = OperationTracker<Int>()
        let began = tracker.begin(1)
        let ended = tracker.end(1, active: true)
        let idle = tracker.becameIdle(1)
        let idleAgain = tracker.becameIdle(1)
        #expect([began, ended, idle, idleAgain] == [true, false, true, false])
    }

    @Test func beginDuringDeferredRestoreKeepsOperationOpen() {
        var tracker = OperationTracker<Int>()
        let first = tracker.begin(1)
        let deferred = tracker.end(1, active: true)
        let reopened = tracker.begin(1)
        let idleWhileOpen = tracker.becameIdle(1)
        let closed = tracker.end(1, active: false)
        let next = tracker.begin(1)
        #expect([first, deferred, reopened, idleWhileOpen, closed, next] == [true, false, false, false, true, true])
    }

    @Test func unmatchedEndAndIdleAreIgnored() {
        var tracker = OperationTracker<Int>()
        let ended = tracker.end(1, active: false)
        let idle = tracker.becameIdle(1)
        #expect([ended, idle] == [false, false])
    }

    @Test func groupsAreIndependent() {
        var tracker = OperationTracker<Int>()
        let first = tracker.begin(1)
        let second = tracker.begin(2)
        let secondEnd = tracker.end(2, active: false)
        let firstEnd = tracker.end(1, active: false)
        #expect([first, second, secondEnd, firstEnd] == [true, true, true, true])
    }
}
