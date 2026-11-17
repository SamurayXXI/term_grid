import CoreGraphics
import Testing
@testable import GridCore

@Suite struct DividerTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let minCell = CGSize(width: 120, height: 80)

    private func frames(_ tree: LayoutNode, gap: CGFloat = 8) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: screen, gap: gap, minCell: minCell)
    }

    private func move(_ tree: LayoutNode, _ id: DividerID, _ delta: CGFloat) -> LayoutNode {
        Dividers.moveDivider(tree, id: id, delta: delta, frames: frames(tree), minCell: minCell)
    }

    @Test func dragPlus100ChangesOnlyTwoNeighbours() {
        let tree = LayoutOps.preset(.threeColumns)
        let before = frames(tree)
        let divider = Dividers.compute(tree, frames: before, gap: 8)[0]
        let after = frames(move(tree, divider.id, 100))
        #expect(after[CellID(0)]!.width == before[CellID(0)]!.width + 100)
        #expect(after[CellID(1)]!.width == before[CellID(1)]!.width - 100)
        #expect(after[CellID(2)]! == before[CellID(2)]!)
    }

    @Test func dragBeyondMinimumStopsAtMinCell() {
        let tree = LayoutOps.preset(.twoColumns)
        let divider = Dividers.compute(tree, frames: frames(tree), gap: 8)[0]
        let after = frames(move(tree, divider.id, 5000))
        #expect(after[CellID(1)]!.width == 120)
        let back = frames(move(tree, divider.id, -5000))
        #expect(back[CellID(0)]!.width == 120)
    }

    @Test func windowMinSizeRaisesClamp() {
        let tree = LayoutOps.preset(.twoColumns)
        let before = frames(tree)
        let divider = Dividers.compute(tree, frames: before, gap: 8)[0]
        let moved = Dividers.moveDivider(
            tree, id: divider.id, delta: 5000, frames: before,
            minSizes: [CellID(1): CGSize(width: 400, height: 0)], minCell: minCell
        )
        #expect(frames(moved)[CellID(1)]!.width == 400)
    }

    @Test func topRowVerticalDividerDoesNotAffectBottomRow() {
        let tree = LayoutOps.preset(.grid2x2)
        let before = frames(tree)
        let dividers = Dividers.compute(tree, frames: before, gap: 8)
        let vertical = dividers.first { $0.axis == .horizontal && $0.rect.minY == 0 }!
        let after = frames(move(tree, vertical.id, 100))
        #expect(after[CellID(0)]!.width == before[CellID(0)]!.width + 100)
        #expect(after[CellID(2)]! == before[CellID(2)]!)
        #expect(after[CellID(3)]! == before[CellID(3)]!)
    }

    @Test func nonFiniteDeltaAndUnknownIdReturnOriginalTree() {
        let tree = LayoutOps.preset(.grid2x2)
        let divider = Dividers.compute(tree, frames: frames(tree), gap: 8)[0]
        for delta in [CGFloat.nan, .infinity, -.infinity] {
            #expect(move(tree, divider.id, delta) == tree)
        }
        #expect(move(tree, DividerID(container: ContainerID(99), index: 0), 10) == tree)
        #expect(move(tree, DividerID(container: divider.id.container, index: 7), 10) == tree)
    }

    @Test func dividerRectsNeverIntersectCells() {
        for gap in stride(from: CGFloat(4), through: 16, by: 2) {
            for preset in [LayoutPreset.grid2x2, .onePlusTwo] {
                let tree = LayoutOps.preset(preset)
                let cells = frames(tree, gap: gap)
                let dividers = Dividers.compute(tree, frames: cells, gap: gap)
                #expect(!dividers.isEmpty)
                for divider in dividers {
                    for cell in cells.values {
                        let overlap = divider.rect.intersection(cell)
                        #expect(overlap.isNull || overlap.width * overlap.height == 0)
                    }
                }
            }
        }
    }

    @Test func dividerSpansContainerAndFillsGap() {
        let tree = LayoutOps.preset(.onePlusTwo)
        let cells = frames(tree)
        let dividers = Dividers.compute(tree, frames: cells, gap: 8)
        #expect(dividers.count == 2)
        let vertical = dividers.first { $0.axis == .horizontal }!
        #expect(vertical.rect == CGRect(x: cells[CellID(0)]!.maxX, y: 0, width: 8, height: 900))
    }
}
