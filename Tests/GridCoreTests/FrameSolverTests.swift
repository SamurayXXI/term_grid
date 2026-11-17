import CoreGraphics
import Testing
@testable import GridCore

@Suite struct FrameSolverTests {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let minCell = CGSize(width: 120, height: 80)

    @Test func grid2x2HasFourDisjointFramesAndExactRowWidth() {
        let frames = FrameSolver.frames(LayoutOps.preset(.grid2x2), in: screen, gap: 8, minCell: minCell)
        #expect(frames.count == 4)
        let rects = Array(frames.values)
        for i in rects.indices {
            for j in rects.indices where i < j {
                #expect(rects[i].intersection(rects[j]).isNull || rects[i].intersection(rects[j]).isEmpty)
            }
        }
        let topRow = [frames[CellID(0)]!, frames[CellID(1)]!]
        #expect(topRow.reduce(0) { $0 + $1.width } == CGFloat(1440 - 8))
        #expect(topRow[1].maxX == 1440)
        #expect(frames[CellID(2)]!.maxY == 900)
    }

    @Test func allFramesAreIntegralWithoutAccumulatedError() {
        for preset in LayoutPreset.allCases {
            let frames = FrameSolver.frames(LayoutOps.preset(preset), in: screen, gap: 7, minCell: minCell)
            for rect in frames.values {
                #expect(rect.minX == rect.minX.rounded() && rect.minY == rect.minY.rounded())
                #expect(rect.width == rect.width.rounded() && rect.height == rect.height.rounded())
            }
        }
        let rect = CGRect(x: 0, y: 0, width: 1000, height: 100)
        let frames = FrameSolver.frames(LayoutOps.preset(.threeColumns), in: rect, gap: 0, minCell: .zero)
        #expect(frames.values.reduce(0) { $0 + $1.width } == 1000)
        #expect(frames[CellID(2)]!.maxX == 1000)
    }

    @Test func gapIsOnlyBetweenChildren() {
        let frames = FrameSolver.frames(LayoutOps.preset(.twoColumns), in: screen, gap: 8, minCell: minCell)
        #expect(frames[CellID(0)]!.minX == 0)
        #expect(frames[CellID(1)]!.minX - frames[CellID(0)]!.maxX == 8)
        #expect(frames[CellID(1)]!.maxX == 1440)
    }

    @Test func onePlusTwoSplitsRightColumnVertically() {
        let frames = FrameSolver.frames(LayoutOps.preset(.onePlusTwo), in: screen, gap: 8, minCell: minCell)
        #expect(frames[CellID(0)]!.height == 900)
        #expect(frames[CellID(1)]!.minX == frames[CellID(2)]!.minX)
        #expect(frames[CellID(1)]!.height + frames[CellID(2)]!.height == CGFloat(900 - 8))
    }

    @Test func minCellRaisesUndersizedChild() {
        let tree = LayoutNode.container(ContainerID(0), .horizontal, [
            LayoutChild(node: .leaf(CellID(0)), ratio: 0.02),
            LayoutChild(node: .leaf(CellID(1)), ratio: 0.98),
        ])
        let frames = FrameSolver.frames(tree, in: screen, gap: 8, minCell: minCell)
        #expect(frames[CellID(0)]!.width == 120)
        #expect(frames[CellID(1)]!.maxX == 1440)
    }

    @Test func respectsRectOrigin() {
        let rect = CGRect(x: -1920, y: 40, width: 1920, height: 1000)
        let frames = FrameSolver.frames(LayoutOps.preset(.grid2x2), in: rect, gap: 8, minCell: minCell)
        #expect(frames[CellID(0)]!.origin == CGPoint(x: -1920, y: 40))
        #expect(frames[CellID(3)]!.maxX == 0)
        #expect(frames[CellID(3)]!.maxY == 1040)
    }

    @Test func leafRootFillsRect() {
        let frames = FrameSolver.frames(.leaf(CellID(0)), in: screen, gap: 8, minCell: minCell)
        #expect(frames == [CellID(0): screen])
    }
}
