import CoreGraphics
import Testing
@testable import GridCore

@Suite struct GridRetargetTests {
    private let grid = CGRect(x: 4, y: 29, width: 1504, height: 945)
    private let minCell = CGSize(width: 120, height: 80)
    private let gap: CGFloat = 4

    private func solve(_ tree: LayoutNode, _ rect: CGRect) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: rect, gap: gap, minCell: minCell)
    }

    private func retarget(_ tree: LayoutNode, to target: CGRect) -> [CellID: CGRect] {
        let start = solve(tree, grid)
        let next = GridRetarget.tree(tree, startFrames: start, from: grid, to: target, gap: gap)
        return solve(next, target)
    }

    @Test func leftEdgeMovesOnlyTheFirstColumn() {
        let tree = LayoutOps.preset(.twoColumns)
        let before = solve(tree, grid)
        let target = CGRect(x: grid.minX + 100, y: grid.minY, width: grid.width - 100, height: grid.height)
        let after = retarget(tree, to: target)
        #expect(after[CellID(1)] == before[CellID(1)])
        #expect(abs(after[CellID(0)]!.width - (before[CellID(0)]!.width - 100)) <= 1)
        #expect(after[CellID(0)]!.minX == target.minX)
    }

    @Test func rightEdgeMovesOnlyTheLastColumn() {
        let tree = LayoutOps.preset(.twoColumns)
        let before = solve(tree, grid)
        let target = CGRect(x: grid.minX, y: grid.minY, width: grid.width - 80, height: grid.height)
        let after = retarget(tree, to: target)
        #expect(after[CellID(0)] == before[CellID(0)])
        #expect(after[CellID(1)]!.maxX == target.maxX)
    }

    @Test func rightEdgeOfOnePlusTwoResizesBothRightWindows() {
        let tree = LayoutOps.preset(.onePlusTwo)
        let before = solve(tree, grid)
        let target = CGRect(x: grid.minX, y: grid.minY, width: grid.width - 60, height: grid.height)
        let after = retarget(tree, to: target)
        #expect(after[CellID(0)] == before[CellID(0)])
        for cell in [1, 2] {
            #expect(after[CellID(cell)]!.maxX == target.maxX)
            #expect(after[CellID(cell)]!.minX == before[CellID(cell)]!.minX)
        }
    }

    @Test func unchangedGridKeepsTheTree() {
        let tree = LayoutOps.preset(.grid2x2)
        #expect(GridRetarget.tree(tree, startFrames: solve(tree, grid), from: grid, to: grid, gap: gap) == tree)
    }
}
