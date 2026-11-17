import CoreGraphics
import Testing
@testable import GridCore

@Suite struct FitPolicyTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let minCell = CGSize(width: 120, height: 80)
    private let gap: CGFloat = 8

    private func cells(_ tree: LayoutNode) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: screen, gap: gap, minCell: minCell)
    }

    private func actual(_ cells: [CellID: CGRect], shrinking deficits: [CellID: CGSize]) -> [CellID: CGRect] {
        var result = cells
        for (id, deficit) in deficits {
            let cell = cells[id]!
            result[id] = CGRect(x: cell.minX, y: cell.minY, width: cell.width - deficit.width, height: cell.height - deficit.height)
        }
        return result
    }

    private func adjust(
        _ tree: LayoutNode,
        _ cellFrames: [CellID: CGRect],
        _ actualFrames: [CellID: CGRect],
        where pick: (Divider) -> Bool
    ) -> LayoutNode? {
        let divider = Dividers.compute(tree, frames: cellFrames, gap: gap).first(where: pick)!
        return FitPolicy.adjust(tree, divider: divider, actualFrames: actualFrames, cellFrames: cellFrames, gap: gap)
    }

    @Test func twoColumnsDeficit7ShiftsDividerBy7() {
        let tree = LayoutOps.preset(.twoColumns)
        let before = cells(tree)
        let shown = actual(before, shrinking: [CellID(0): CGSize(width: 7, height: 0)])
        let adjusted = adjust(tree, before, shown) { _ in true }!
        let after = cells(adjusted)
        #expect(after[CellID(0)]!.width == before[CellID(0)]!.width - 7)
        #expect(after[CellID(1)]!.width == before[CellID(1)]!.width + 7)
    }

    @Test func deficitOver40ReturnsNil() {
        let tree = LayoutOps.preset(.twoColumns)
        let before = cells(tree)
        let shown = actual(before, shrinking: [CellID(0): CGSize(width: 50, height: 0)])
        #expect(adjust(tree, before, shown) { _ in true } == nil)
    }

    @Test func deficitWithinOnePointReturnsNil() {
        let tree = LayoutOps.preset(.twoColumns)
        let before = cells(tree)
        let shown = actual(before, shrinking: [CellID(0): CGSize(width: 1, height: 0)])
        #expect(adjust(tree, before, shown) { _ in true } == nil)
    }

    @Test func grid2x2TopRowDeficits12And3MoveHorizontalDividerBy3() {
        let tree = LayoutOps.preset(.grid2x2)
        let before = cells(tree)
        let shown = actual(before, shrinking: [CellID(0): CGSize(width: 0, height: 12), CellID(1): CGSize(width: 0, height: 3)])
        let adjusted = adjust(tree, before, shown) { $0.axis == .vertical }!
        let after = cells(adjusted)
        #expect(after[CellID(0)]!.height == before[CellID(0)]!.height - 3)
        #expect(after[CellID(2)]!.height == before[CellID(2)]!.height + 3)
    }

    @Test func deficitOnlyInBottomRowDoesNotMoveDivider() {
        let tree = LayoutOps.preset(.grid2x2)
        let before = cells(tree)
        let shown = actual(before, shrinking: [CellID(2): CGSize(width: 0, height: 9)])
        #expect(adjust(tree, before, shown) { $0.axis == .vertical } == nil)
    }

    @Test func onePlusTwoVerticalDividerFollowsLeftWindowDeficit() {
        let tree = LayoutOps.preset(.onePlusTwo)
        let before = cells(tree)
        let shown = actual(before, shrinking: [CellID(0): CGSize(width: 6, height: 0), CellID(1): CGSize(width: 20, height: 0)])
        let adjusted = adjust(tree, before, shown) { $0.axis == .horizontal }!
        let after = cells(adjusted)
        #expect(after[CellID(0)]!.width == before[CellID(0)]!.width - 6)
        #expect(after[CellID(1)]!.width == before[CellID(1)]!.width + 6)
    }

    @Test func outerTopEdgeAnchorsWindowToBottomOfCell() {
        let cell = CGRect(x: 10, y: 20, width: 500, height: 300)
        let origin = FitPolicy.anchoredOrigin(cell, actualSize: CGSize(width: 500, height: 291), outerEdges: [.top, .left, .right])
        #expect(origin.y + 291 == cell.maxY)
        #expect(origin.x == cell.minX)
    }

    @Test func outerLeftEdgeAnchorsWindowToRightOfCell() {
        let cell = CGRect(x: 10, y: 20, width: 500, height: 300)
        let origin = FitPolicy.anchoredOrigin(cell, actualSize: CGSize(width: 493, height: 300), outerEdges: [.left])
        #expect(origin.x + 493 == cell.maxX)
    }

    @Test func innerEdgesKeepCellOrigin() {
        let cell = CGRect(x: 10, y: 20, width: 500, height: 300)
        let origin = FitPolicy.anchoredOrigin(cell, actualSize: CGSize(width: 490, height: 291), outerEdges: [])
        #expect(origin == cell.origin)
        let both = FitPolicy.anchoredOrigin(cell, actualSize: CGSize(width: 490, height: 291), outerEdges: [.top, .bottom, .left, .right])
        #expect(both == cell.origin)
    }

    @Test func outerBottomEdgeKeepsWindowAtTop() {
        let cell = CGRect(x: 10, y: 20, width: 500, height: 300)
        let origin = FitPolicy.anchoredOrigin(cell, actualSize: CGSize(width: 500, height: 291), outerEdges: [.bottom])
        #expect(origin == cell.origin)
    }
}
