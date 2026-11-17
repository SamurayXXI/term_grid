import CoreGraphics
import Testing
@testable import GridCore

@Suite struct GridFitTests {
    private let grid = CGRect(x: 8, y: 8, width: 1424, height: 884)
    private let minCell = CGSize(width: 120, height: 80)
    private let gap: CGFloat = 8

    private func solve(_ tree: LayoutNode) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: grid, gap: gap, minCell: minCell)
    }

    private func shrunk(_ frames: [CellID: CGRect], _ deficits: [CellID: CGSize]) -> [CellID: CGRect] {
        var result = frames
        for (id, deficit) in deficits {
            let cell = frames[id]!
            result[id] = CGRect(x: cell.minX, y: cell.minY, width: cell.width - deficit.width, height: cell.height - deficit.height)
        }
        return result
    }

    @Test func outerEdgesOfLeftCellInTwoColumns() {
        let frames = solve(LayoutOps.preset(.twoColumns))
        let edges = GridFit.outerEdges(of: frames[CellID(0)]!, in: grid)
        #expect(edges == [.top, .bottom, .left])
    }

    @Test func outerEdgesOfInnerCellInThreeColumns() {
        let frames = solve(LayoutOps.preset(.threeColumns))
        #expect(GridFit.outerEdges(of: frames[CellID(1)]!, in: grid) == [.top, .bottom])
    }

    @Test func adjacentCellsOfTwoColumnsDivider() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let divider = Dividers.compute(tree, frames: frames, gap: gap)[0]
        let adjacent = GridFit.adjacentCells(of: divider, in: tree, cellFrames: frames)
        #expect(adjacent.near == [CellID(0)])
        #expect(adjacent.far == [CellID(1)])
    }

    @Test func adjacentCellsOfOnePlusTwoSeeBothRightCells() {
        let tree = LayoutOps.preset(.onePlusTwo)
        let frames = solve(tree)
        let divider = Dividers.compute(tree, frames: frames, gap: gap).first { $0.axis == .horizontal }!
        let adjacent = GridFit.adjacentCells(of: divider, in: tree, cellFrames: frames)
        #expect(adjacent.near == [CellID(0)])
        #expect(Set(adjacent.far) == [CellID(1), CellID(2)])
    }

    @Test func planAdjustsDividerBetweenTerminals() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let actual = shrunk(frames, [CellID(0): CGSize(width: 7, height: 0)])
        let plan = GridFit.plan(
            tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { _ in true }, solve: solve
        )!
        #expect(plan.adjustments.count == 1)
        #expect(plan.adjustments[0].delta == 7)
        #expect(solve(plan.tree)[CellID(0)]!.width == frames[CellID(0)]!.width - 7)
    }

    @Test func planSkipsDividerWhenOneSideIsNotTerminal() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let actual = shrunk(frames, [CellID(0): CGSize(width: 7, height: 0)])
        let plan = GridFit.plan(
            tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { $0 == CellID(0) }, solve: solve
        )
        #expect(plan == nil)
    }

    @Test func planReportsSkippedDividerWhenDeficitTooLarge() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let actual = shrunk(frames, [CellID(0): CGSize(width: 60, height: 0)])
        let plan = GridFit.plan(
            tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { _ in true }, solve: solve
        )
        #expect(plan?.adjustments.isEmpty == true)
        #expect(plan?.skipped.count == 1)
    }

    @Test func planAdjustsBothDividersOfThreeColumns() {
        let tree = LayoutOps.preset(.threeColumns)
        let frames = solve(tree)
        let actual = shrunk(frames, [CellID(0): CGSize(width: 5, height: 0), CellID(1): CGSize(width: 6, height: 0)])
        let plan = GridFit.plan(
            tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { _ in true }, solve: solve
        )!
        #expect(plan.adjustments.map(\.delta) == [5, 6])
    }

    @Test func fitOfDraggedDividerBetweenTerminalsAdjustsByDeficit() {
        let tree = LayoutOps.preset(.grid2x2)
        let frames = solve(tree)
        let id = Dividers.compute(tree, frames: frames, gap: gap).first { $0.axis == .horizontal }!.id
        let actual = shrunk(frames, [CellID(0): CGSize(width: 6, height: 0), CellID(2): CGSize(width: 3, height: 0)])
        let result = GridFit.fit(
            divider: id, tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { _ in true }, solve: solve
        )
        guard case .adjusted(let next, let nextFrames, let delta) = result else {
            Issue.record("expected adjusted, got \(result)")
            return
        }
        #expect(delta == 6)
        #expect(nextFrames == solve(next))
        #expect(nextFrames[CellID(0)]!.width == frames[CellID(0)]!.width - 6)
        #expect(nextFrames[CellID(2)]! == frames[CellID(2)]!)
    }

    @Test func fitOfDraggedDividerIsNotApplicableWithNonTerminalNeighbour() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let id = Dividers.compute(tree, frames: frames, gap: gap)[0].id
        let actual = shrunk(frames, [CellID(0): CGSize(width: 7, height: 0)])
        let result = GridFit.fit(
            divider: id, tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { $0 == CellID(0) }, solve: solve
        )
        #expect(result == .notApplicable)
    }

    @Test func fitOfDraggedDividerIsSkippedWhenDeficitOutOfRange() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let id = Dividers.compute(tree, frames: frames, gap: gap)[0].id
        for deficit in [CGFloat(0.5), 50] {
            let actual = shrunk(frames, [CellID(0): CGSize(width: deficit, height: 0)])
            let result = GridFit.fit(
                divider: id, tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
                isTerminalCell: { _ in true }, solve: solve
            )
            #expect(result == .skipped)
        }
    }

    @Test func fitOfUnknownDividerIsNotApplicable() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let result = GridFit.fit(
            divider: DividerID(container: ContainerID(77), index: 0), tree: tree, cellFrames: frames,
            actualFrames: frames, gap: gap, isTerminalCell: { _ in true }, solve: solve
        )
        #expect(result == .notApplicable)
    }

    @Test func planLeavesOuterEdgeUntouched() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let actual = shrunk(frames, [CellID(1): CGSize(width: 9, height: 0)])
        let plan = GridFit.plan(
            tree: tree, cellFrames: frames, actualFrames: actual, gap: gap,
            isTerminalCell: { _ in true }, solve: solve
        )
        #expect(plan?.adjustments.isEmpty == true)
    }
}
