import CoreGraphics
import Testing
@testable import GridCore

@Suite struct DividerDragTests {
    private let grid = CGRect(x: 8, y: 33, width: 1424, height: 859)
    private let minCell = CGSize(width: 120, height: 80)
    private let gap: CGFloat = 8

    private func solve(_ tree: LayoutNode, gap: CGFloat = 8) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: grid, gap: gap, minCell: minCell)
    }

    private func start(_ tree: LayoutNode, where match: (Divider) -> Bool) -> DividerDrag {
        let frames = solve(tree)
        let divider = Dividers.compute(tree, frames: frames, gap: gap).first(where: match)!
        return DividerDrag(tree: tree, divider: divider.id, frames: frames, gap: gap, origin: divider.point(along: 0.5))!
    }

    private func frames(after drag: DividerDrag, by offset: CGVector, minSizes: [CellID: CGSize] = [:]) -> [CellID: CGRect] {
        let point = CGPoint(x: drag.origin.x + offset.dx, y: drag.origin.y + offset.dy)
        return solve(drag.tree(to: point, minSizes: minSizes, minCell: minCell))
    }

    @Test func horizontalDragFollowsPointerX() {
        let drag = start(LayoutOps.preset(.twoColumns)) { _ in true }
        let after = frames(after: drag, by: CGVector(dx: 200, dy: 37))
        #expect(after[CellID(0)]!.width == drag.frames[CellID(0)]!.width + 200)
        #expect(after[CellID(1)]!.width == drag.frames[CellID(1)]!.width - 200)
        #expect(after[CellID(1)]!.maxX == drag.frames[CellID(1)]!.maxX)
    }

    @Test func verticalDragDownGrowsTopCellInAXSpace() {
        let drag = start(LayoutOps.preset(.twoRows)) { _ in true }
        #expect(drag.divider.axis == .vertical)
        let after = frames(after: drag, by: CGVector(dx: -50, dy: 150))
        #expect(after[CellID(0)]!.height == drag.frames[CellID(0)]!.height + 150)
        #expect(after[CellID(1)]!.height == drag.frames[CellID(1)]!.height - 150)
        #expect(after[CellID(0)]!.minY == drag.frames[CellID(0)]!.minY)
    }

    @Test func deltaIsMeasuredFromMouseDownNotAccumulated() {
        let drag = start(LayoutOps.preset(.twoColumns)) { _ in true }
        let first = drag.tree(to: CGPoint(x: drag.origin.x + 40, y: drag.origin.y), minSizes: [:], minCell: minCell)
        let direct = drag.tree(to: CGPoint(x: drag.origin.x + 90, y: drag.origin.y), minSizes: [:], minCell: minCell)
        #expect(first != direct)
        #expect(drag.tree == LayoutOps.preset(.twoColumns))
        #expect(solve(direct)[CellID(0)]!.width == drag.frames[CellID(0)]!.width + 90)
    }

    @Test func dragFarPastEdgeClampsToMinCell() {
        let drag = start(LayoutOps.preset(.twoColumns)) { _ in true }
        #expect(frames(after: drag, by: CGVector(dx: 2000, dy: 0))[CellID(1)]!.width == 120)
        #expect(frames(after: drag, by: CGVector(dx: -2000, dy: 0))[CellID(0)]!.width == 120)
    }

    @Test func clampRespectsWindowMinSize() {
        let drag = start(LayoutOps.preset(.twoColumns)) { _ in true }
        let after = frames(after: drag, by: CGVector(dx: 2000, dy: 0), minSizes: [CellID(1): CGSize(width: 500, height: 0)])
        #expect(after[CellID(1)]!.width == 500)
    }

    @Test func topRowDividerAffectsOnlyTopRowCells() {
        let tree = LayoutOps.preset(.grid2x2)
        let drag = start(tree) { $0.axis == .horizontal && $0.rect.minY == 33 }
        #expect(Set(drag.cells) == [CellID(0), CellID(1)])
        let after = frames(after: drag, by: CGVector(dx: 150, dy: 0))
        #expect(after[CellID(2)]! == drag.frames[CellID(2)]!)
        #expect(after[CellID(3)]! == drag.frames[CellID(3)]!)
        #expect(after[CellID(0)]!.width == drag.frames[CellID(0)]!.width + 150)
    }

    @Test func rootDividerAffectsBothSubtrees() {
        let tree = LayoutOps.preset(.onePlusTwo)
        let drag = start(tree) { $0.axis == .horizontal }
        #expect(Set(drag.cells) == [CellID(0), CellID(1), CellID(2)])
        let after = frames(after: drag, by: CGVector(dx: -100, dy: 0))
        #expect(after[CellID(1)]!.width == drag.frames[CellID(1)]!.width + 100)
        #expect(after[CellID(2)]!.width == drag.frames[CellID(2)]!.width + 100)
    }

    @Test func nonFinitePointKeepsStartTree() {
        let drag = start(LayoutOps.preset(.twoColumns)) { _ in true }
        for value in [CGFloat.nan, .infinity, -.infinity] {
            #expect(drag.tree(to: CGPoint(x: value, y: 0), minSizes: [:], minCell: minCell) == drag.tree)
        }
    }

    @Test func unknownDividerOrNonFiniteOriginGivesNoDrag() {
        let tree = LayoutOps.preset(.twoColumns)
        let frames = solve(tree)
        let id = Dividers.compute(tree, frames: frames, gap: gap)[0].id
        #expect(DividerDrag(tree: tree, divider: DividerID(container: ContainerID(42), index: 0), frames: frames, gap: gap, origin: .zero) == nil)
        #expect(DividerDrag(tree: tree, divider: DividerID(container: id.container, index: 5), frames: frames, gap: gap, origin: .zero) == nil)
        #expect(DividerDrag(tree: tree, divider: id, frames: frames, gap: gap, origin: CGPoint(x: CGFloat.nan, y: 0)) == nil)
    }

    @Test func zeroGapDividersAreGrabbableWithPanelCentredOnSeam() {
        let tree = LayoutOps.preset(.grid2x2)
        let frames = solve(tree, gap: 0)
        let thin = Dividers.compute(tree, frames: frames, gap: 0)
        #expect(!thin.isEmpty)
        #expect(thin.allSatisfy { $0.isGrabbable })
        for divider in thin {
            let hit = divider.hitRect
            if divider.axis == .horizontal {
                #expect(hit.width == 6)
                #expect(hit.midX == divider.rect.minX)
                #expect(hit.height == divider.rect.height)
            } else {
                #expect(hit.height == 6)
                #expect(hit.midY == divider.rect.minY)
                #expect(hit.width == divider.rect.width)
            }
        }
    }

    @Test func hitZoneIsAtLeastSixPointsAndCentredOnTheGap() {
        for gap in [CGFloat(1), 2, 3, 4, 6, 8] {
            let tree = LayoutOps.preset(.twoColumns)
            let frames = solve(tree, gap: gap)
            let divider = Dividers.compute(tree, frames: frames, gap: gap)[0]
            let hit = divider.hitRect
            #expect(hit.width == max(6, gap))
            #expect(hit.midX == divider.rect.midX)
            let overlap = max(0, (6 - gap) / 2)
            #expect(frames[CellID(0)]!.maxX - hit.minX == overlap)
            #expect(hit.maxX - frames[CellID(1)]!.minX == overlap)
        }
    }

    @Test func panelFrameIsDividerRectInAppKitSpace() {
        let divider = Divider(
            id: DividerID(container: ContainerID(0), index: 0),
            axis: .horizontal,
            rect: CGRect(x: 716, y: 33, width: 8, height: 859)
        )
        #expect(divider.panelFrame(primaryHeight: 900) == CGRect(x: 716, y: 8, width: 8, height: 859))
        #expect(ScreenSpace.toAX(divider.panelFrame(primaryHeight: 900), primaryHeight: 900) == divider.rect)
        let thin = Divider(id: divider.id, axis: .vertical, rect: CGRect(x: 8, y: 400, width: 1000, height: 2))
        #expect(thin.panelFrame(primaryHeight: 900) == CGRect(x: 8, y: 496, width: 1000, height: 6))
    }

    @Test func anchorPointLiesInsideDividerAlongItsLength() {
        let vertical = Divider(
            id: DividerID(container: ContainerID(0), index: 0),
            axis: .horizontal,
            rect: CGRect(x: 716, y: 33, width: 8, height: 800)
        )
        #expect(vertical.point(along: 0.5) == CGPoint(x: 720, y: 433))
        #expect(vertical.point(along: 0.25) == CGPoint(x: 720, y: 233))
        let horizontal = Divider(
            id: DividerID(container: ContainerID(1), index: 0),
            axis: .vertical,
            rect: CGRect(x: 8, y: 400, width: 1000, height: 8)
        )
        #expect(horizontal.point(along: 0.5) == CGPoint(x: 508, y: 404))
        #expect(horizontal.rect.contains(horizontal.point(along: 0.9)))
    }
}
