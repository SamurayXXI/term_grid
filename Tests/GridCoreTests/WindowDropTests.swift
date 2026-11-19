import CoreGraphics
import Testing
@testable import GridCore

@Suite struct WindowDropTests {
    private let frames: [CellID: CGRect] = [
        CellID(0): CGRect(x: 0, y: 0, width: 100, height: 100),
        CellID(1): CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    @Test func pointInsideOtherCellIsTarget() {
        let target = WindowDrop.target(at: CGPoint(x: 150, y: 50), frames: frames, excluding: CellID(0))
        #expect(target == CellID(1))
    }

    @Test func pointInsideSourceCellIsNotTarget() {
        let target = WindowDrop.target(at: CGPoint(x: 50, y: 50), frames: frames, excluding: CellID(0))
        #expect(target == nil)
    }

    @Test func pointOutsideGridHasNoTarget() {
        let target = WindowDrop.target(at: CGPoint(x: 500, y: 50), frames: frames, excluding: CellID(0))
        #expect(target == nil)
    }

    @Test func centerOfFrame() {
        #expect(WindowDrop.center(of: CGRect(x: 10, y: 20, width: 40, height: 60)) == CGPoint(x: 30, y: 50))
    }
}
