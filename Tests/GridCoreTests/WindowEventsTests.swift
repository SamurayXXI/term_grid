import CoreGraphics
import Testing
@testable import GridCore

@Suite struct WindowEventsTests {
    private let reference = CGRect(x: 8, y: 33, width: 700, height: 850)

    @Test func moveOverTwentyPointsIsMoved() {
        #expect(ExternalChange.detect(reference: reference, current: reference.offsetBy(dx: 100, dy: 0)) == .moved)
        #expect(ExternalChange.detect(reference: reference, current: reference.offsetBy(dx: 0, dy: -21)) == .moved)
    }

    @Test func sizeChangeOverTwentyPointsIsResizedEvenWhenOriginMoves() {
        let wider = CGRect(x: reference.minX, y: reference.minY, width: reference.width + 100, height: reference.height)
        #expect(ExternalChange.detect(reference: reference, current: wider) == .resized)
        let leftEdge = CGRect(x: reference.minX - 50, y: reference.minY, width: reference.width + 50, height: reference.height)
        #expect(ExternalChange.detect(reference: reference, current: leftEdge) == .resized)
    }

    @Test func changesUpToTwentyPointsAreIgnored() {
        let nudged = CGRect(x: reference.minX + 20, y: reference.minY - 20, width: reference.width - 20, height: reference.height + 20)
        #expect(ExternalChange.detect(reference: reference, current: nudged) == nil)
    }

    @Test func registryIdsStartAtOneAndAreNeverReused() {
        var registry = BindingRegistry<String>()
        let first = registry.sync(["a", "b"])
        #expect(Set(first.added.map(\.id)) == [1, 2])
        #expect(first.removed.isEmpty)
        let idA = registry.id(for: "a")!
        let second = registry.sync(["b"])
        #expect(second.removed.map(\.id) == [idA])
        #expect(second.removed.map(\.window) == ["a"])
        #expect(second.added.isEmpty)
        #expect(registry.window(for: idA) == nil)
        let third = registry.sync(["a", "b"])
        #expect(third.added.map(\.id) == [3])
        #expect(registry.window(for: 3) == "a")
    }

    @Test func registrySyncWithSameSetChangesNothing() {
        var registry = BindingRegistry<String>()
        _ = registry.sync(["a"])
        let again = registry.sync(["a"])
        #expect(again.added.isEmpty)
        #expect(again.removed.isEmpty)
        #expect(registry.id(for: "a") == 1)
    }

    @Test func registryUnknownIdIsNil() {
        let registry = BindingRegistry<String>()
        #expect(registry.window(for: 1) == nil)
    }

    @Test func readGateCoalescesWhileInFlight() {
        var gate = EventReadGate<Int>()
        let first = gate.request(1)
        let second = gate.request(1)
        let third = gate.request(1)
        let rerun = gate.finished(1)
        let done = gate.finished(1)
        let next = gate.request(1)
        #expect([first, second, third, rerun, done, next] == [true, false, false, true, false, true])
    }

    @Test func readGateIsPerKey() {
        var gate = EventReadGate<Int>()
        let one = gate.request(1)
        let two = gate.request(2)
        let twoDone = gate.finished(2)
        let oneAgain = gate.request(1)
        let oneRerun = gate.finished(1)
        #expect([one, two, twoDone, oneAgain, oneRerun] == [true, true, false, false, true])
    }
}
