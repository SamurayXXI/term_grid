import CoreGraphics
import Testing
@testable import GridCore

@Suite struct EdgeResizeTests {
    private let grid = CGRect(x: 4, y: 29, width: 1504, height: 945)
    private let minCell = CGSize(width: 120, height: 80)
    private let gap: CGFloat = 4

    private func solve(_ tree: LayoutNode) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: grid, gap: gap, minCell: minCell)
    }

    private func moves(_ tree: LayoutNode, _ cell: Int, _ current: (CGRect) -> CGRect) -> [EdgeMove] {
        let frames = solve(tree)
        let frame = frames[CellID(cell)]!
        return EdgeResize.moves(
            of: CellID(cell), tree: tree, cellFrames: frames, gap: gap,
            reference: frame, current: current(frame)
        )
    }

    private func apply(_ tree: LayoutNode, _ moves: [EdgeMove], minSizes: [CellID: CGSize] = [:]) -> [CellID: CGRect] {
        solve(EdgeResize.tree(
            applying: moves, to: tree, cellFrames: solve(tree),
            minSizes: minSizes, minCell: minCell, solve: solve
        ))
    }

    @Test func rightEdgeOfLeftColumnMovesTheDivider() {
        let tree = LayoutOps.preset(.twoColumns)
        let found = moves(tree, 0) { CGRect(x: $0.minX, y: $0.minY, width: $0.width + 100, height: $0.height) }
        let divider = Dividers.compute(tree, frames: solve(tree), gap: gap)[0].id
        #expect(found == [EdgeMove(edge: .right, divider: divider, delta: 100)])
        let after = apply(tree, found)
        let before = solve(tree)
        #expect(after[CellID(0)]!.width == before[CellID(0)]!.width + 100)
        #expect(after[CellID(1)]!.width == before[CellID(1)]!.width - 100)
        #expect(after[CellID(1)]!.maxX == before[CellID(1)]!.maxX)
    }

    @Test func leftEdgeOfRightColumnMovesTheSameDivider() {
        let tree = LayoutOps.preset(.twoColumns)
        let found = moves(tree, 1) { CGRect(x: $0.minX - 60, y: $0.minY, width: $0.width + 60, height: $0.height) }
        #expect(found.map(\.edge) == [.left])
        #expect(found[0].divider != nil)
        #expect(found[0].delta == -60)
        let after = apply(tree, found)
        #expect(after[CellID(1)]!.width == solve(tree)[CellID(1)]!.width + 60)
    }

    @Test func outerEdgeHasNoDivider() {
        let tree = LayoutOps.preset(.twoColumns)
        let found = moves(tree, 1) { CGRect(x: $0.minX, y: $0.minY, width: $0.width - 80, height: $0.height) }
        #expect(found == [EdgeMove(edge: .right, divider: nil, delta: -80)])
        #expect(apply(tree, found) == solve(tree))
    }

    @Test func bottomEdgeOfTopRowMovesHorizontalDividerInAXSpace() {
        let tree = LayoutOps.preset(.twoRows)
        let found = moves(tree, 0) { CGRect(x: $0.minX, y: $0.minY, width: $0.width, height: $0.height + 150) }
        #expect(found.map(\.edge) == [.bottom])
        #expect(found[0].divider != nil)
        let after = apply(tree, found)
        #expect(after[CellID(0)]!.height == solve(tree)[CellID(0)]!.height + 150)
        #expect(after[CellID(1)]!.height == solve(tree)[CellID(1)]!.height - 150)
    }

    @Test func cornerResizeHandlesEachAxis() {
        let tree = LayoutOps.preset(.grid2x2)
        let found = moves(tree, 0) { CGRect(x: $0.minX, y: $0.minY, width: $0.width + 90, height: $0.height + 70) }
        #expect(Set(found.map(\.edge)) == [.right, .bottom])
        #expect(found.allSatisfy { $0.divider != nil })
        let after = apply(tree, found)
        let before = solve(tree)
        #expect(after[CellID(0)]!.width == before[CellID(0)]!.width + 90)
        #expect(after[CellID(0)]!.height == before[CellID(0)]!.height + 70)
        #expect(after[CellID(2)]!.width == before[CellID(2)]!.width)
    }

    @Test func axisBelowThresholdIsIgnored() {
        let tree = LayoutOps.preset(.grid2x2)
        let found = moves(tree, 0) { CGRect(x: $0.minX, y: $0.minY, width: $0.width + 90, height: $0.height + 15) }
        #expect(found.map(\.edge) == [.right])
    }

    @Test func pureMoveYieldsNoEdgeMoves() {
        let tree = LayoutOps.preset(.twoColumns)
        #expect(moves(tree, 0) { $0.offsetBy(dx: 100, dy: 0) }.isEmpty)
    }

    @Test func middleColumnBothEdgesMoveBothDividers() {
        let tree = LayoutOps.preset(.threeColumns)
        let found = moves(tree, 1) { CGRect(x: $0.minX - 40, y: $0.minY, width: $0.width + 100, height: $0.height) }
        #expect(Set(found.map(\.edge)) == [.left, .right])
        #expect(Set(found.compactMap(\.divider)).count == 2)
        let after = apply(tree, found)
        let before = solve(tree)
        #expect(after[CellID(1)]!.minX == before[CellID(1)]!.minX - 40)
        #expect(after[CellID(1)]!.maxX == before[CellID(1)]!.maxX + 60)
    }

    @Test func resizeIsClampedToMinCellAndMinSize() {
        let tree = LayoutOps.preset(.twoColumns)
        let found = moves(tree, 0) { CGRect(x: $0.minX, y: $0.minY, width: $0.width + 2000, height: $0.height) }
        #expect(apply(tree, found)[CellID(1)]!.width == 120)
        let sized = apply(tree, found, minSizes: [CellID(1): CGSize(width: 400, height: 0)])
        #expect(sized[CellID(1)]!.width == 400)
    }

    @Test func gridRowEdgeOnlyTouchesItsRow() {
        let tree = LayoutOps.preset(.grid2x2)
        let found = moves(tree, 2) { CGRect(x: $0.minX, y: $0.minY, width: $0.width + 120, height: $0.height) }
        let after = apply(tree, found)
        let before = solve(tree)
        #expect(after[CellID(0)]! == before[CellID(0)]!)
        #expect(after[CellID(1)]! == before[CellID(1)]!)
        #expect(after[CellID(2)]!.width == before[CellID(2)]!.width + 120)
    }

    @Test func zeroGapStillFindsTheDivider() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = FrameSolver.frames(tree, in: grid, gap: 0, minCell: minCell)
        let frame = frames[CellID(0)]!
        let found = EdgeResize.moves(
            of: CellID(0), tree: tree, cellFrames: frames, gap: 0, reference: frame,
            current: CGRect(x: frame.minX, y: frame.minY, width: frame.width + 50, height: frame.height)
        )
        #expect(found.count == 1)
        #expect(found[0].divider != nil)
    }
}
