import Foundation
import Testing
@testable import GridCore

@Suite struct ApplySchedulerTests {
    private typealias Scheduler = ApplyScheduler<String, Int, Int>

    private let interval = 1.0 / 30

    @Test func idleWindowStartsImmediately() {
        var scheduler = Scheduler(maxRate: 30)
        let submission = scheduler.submit(1, for: "a", group: 1, now: 0)
        #expect(submission.superseded == nil)
        #expect(submission.action == .start(1))
        #expect(scheduler.isGroupActive(1))
    }

    @Test func requestsWhileInFlightCoalesceLastWriteWins() {
        var scheduler = Scheduler(maxRate: 30)
        _ = scheduler.submit(1, for: "a", group: 1, now: 0)
        let second = scheduler.submit(2, for: "a", group: 1, now: 0.01)
        let third = scheduler.submit(3, for: "a", group: 1, now: 0.02)
        let afterFirst = scheduler.finish("a", now: 0.1)
        let afterThird = scheduler.finish("a", now: 0.2)
        #expect(second.superseded == nil)
        #expect(second.action == .idle)
        #expect(third.superseded == 2)
        #expect(third.action == .idle)
        #expect(afterFirst == .start(3))
        #expect(afterThird == .idle)
        #expect(!scheduler.isGroupActive(1))
    }

    @Test func startsAreThrottledPerWindow() {
        var scheduler = Scheduler(maxRate: 30)
        _ = scheduler.submit(1, for: "a", group: 1, now: 0)
        let finished = scheduler.finish("a", now: 0.001)
        let next = scheduler.submit(2, for: "a", group: 1, now: 0.005)
        let replacing = scheduler.submit(3, for: "a", group: 1, now: 0.01)
        let fired = scheduler.timerFired("a", now: interval)
        #expect(finished == .idle)
        #expect(next.action == .wait(until: interval))
        #expect(replacing.superseded == 2)
        #expect(replacing.action == .idle)
        #expect(fired == .start(3))
    }

    @Test func earlyTimerWaitsAgain() {
        var scheduler = Scheduler(maxRate: 30)
        _ = scheduler.submit(1, for: "a", group: 1, now: 0)
        _ = scheduler.finish("a", now: 0.001)
        _ = scheduler.submit(2, for: "a", group: 1, now: 0.002)
        let early = scheduler.timerFired("a", now: 0.02)
        let onTime = scheduler.timerFired("a", now: interval)
        #expect(early == .wait(until: interval))
        #expect(onTime == .start(2))
    }

    @Test func windowsAreIndependent() {
        var scheduler = Scheduler(maxRate: 30)
        _ = scheduler.submit(1, for: "a", group: 1, now: 0)
        let sameGroup = scheduler.submit(2, for: "b", group: 1, now: 0.001)
        let otherGroup = scheduler.submit(3, for: "c", group: 2, now: 0.001)
        #expect(sameGroup.action == .start(2))
        #expect(otherGroup.action == .start(3))
    }

    @Test func groupIsActiveWhileAnyWindowHasWork() {
        var scheduler = Scheduler(maxRate: 30)
        _ = scheduler.submit(1, for: "a", group: 7, now: 0)
        _ = scheduler.submit(2, for: "b", group: 7, now: 0)
        #expect(scheduler.isGroupActive(7))
        #expect(!scheduler.isGroupActive(8))
        _ = scheduler.finish("a", now: 0.1)
        #expect(scheduler.isGroupActive(7))
        _ = scheduler.finish("b", now: 0.1)
        #expect(!scheduler.isGroupActive(7))
    }

    @Test func burstOfTwoHundredRequestsInOneSecondStaysUnderMaxRate() {
        var scheduler = Scheduler(maxRate: 30)
        var starts: [(ticket: Int, at: Double)] = []
        var superseded = 0
        var finishAt: Double?
        var timerAt: Double?
        var nextRequest = 0
        while true {
            let requestAt = nextRequest < 200 ? Double(nextRequest) * 0.005 : nil
            guard let now = [requestAt, finishAt, timerAt].compactMap({ $0 }).min() else { break }
            let action: Scheduler.Action
            if now == finishAt {
                finishAt = nil
                action = scheduler.finish("a", now: now)
            } else if now == timerAt {
                timerAt = nil
                action = scheduler.timerFired("a", now: now)
            } else {
                let submission = scheduler.submit(nextRequest, for: "a", group: 1, now: now)
                nextRequest += 1
                superseded += submission.superseded == nil ? 0 : 1
                action = submission.action
            }
            switch action {
            case .idle:
                break
            case .start(let ticket):
                starts.append((ticket, now))
                finishAt = now + 0.001
            case .wait(let until):
                timerAt = until
            }
        }
        #expect(starts.count <= 32)
        #expect(starts.count >= 15)
        #expect(starts.last?.ticket == 199)
        #expect(superseded == 200 - starts.count)
        for (previous, next) in zip(starts, starts.dropFirst()) {
            #expect(next.at - previous.at >= interval - 1e-9)
        }
    }
}
