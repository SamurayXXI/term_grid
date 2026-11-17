import Foundation
import CoreGraphics
import Testing
@testable import GridCore

@Suite struct LayoutTreeTests {
    @Test func presetsHaveExpectedLeafCounts() {
        let expected: [(LayoutPreset, Int)] = [
            (.twoColumns, 2), (.threeColumns, 3), (.twoRows, 2),
            (.grid2x2, 4), (.onePlusTwo, 3), (.grid2x3, 6),
        ]
        for (preset, count) in expected {
            let tree = LayoutOps.preset(preset)
            #expect(tree.leafIDs.count == count)
            #expect(Set(tree.leafIDs).count == count)
        }
    }

    @Test func presetRatiosSumToOne() {
        func check(_ node: LayoutNode) {
            guard case .container(_, _, let children) = node else { return }
            #expect(abs(children.reduce(0) { $0 + $1.ratio } - 1) < 1e-9)
            children.forEach { check($0.node) }
        }
        for preset in LayoutPreset.allCases {
            check(LayoutOps.preset(preset))
        }
    }

    @Test func splitThenCloseReturnsOriginalTree() {
        let original = LayoutOps.preset(.grid2x2)
        for cell in original.leafIDs {
            for axis in [Axis.horizontal, .vertical] {
                let split = LayoutOps.split(original, cell: cell, axis: axis)
                #expect(split.leafIDs.count == 5)
                let newCell = split.leafIDs.first { !original.contains($0) }!
                #expect(LayoutOps.close(split, cell: newCell) == original)
            }
        }
    }

    @Test func splitOfUnknownCellReturnsSameTree() {
        let tree = LayoutOps.preset(.twoColumns)
        #expect(LayoutOps.split(tree, cell: CellID(99), axis: .horizontal) == tree)
    }

    @Test func closeOfUnknownCellReturnsSameTree() {
        let tree = LayoutOps.preset(.twoColumns)
        #expect(LayoutOps.close(tree, cell: CellID(99)) == tree)
    }

    @Test func closeOfLastLeafGivesEmptyTree() {
        #expect(LayoutOps.close(.leaf(CellID(0)), cell: CellID(0)) == nil)
    }

    @Test func closeRedistributesRatioProportionallyAndCollapses() {
        let tree = LayoutNode.container(ContainerID(0), .horizontal, [
            LayoutChild(node: .leaf(CellID(0)), ratio: 0.5),
            LayoutChild(node: .leaf(CellID(1)), ratio: 0.3),
            LayoutChild(node: .leaf(CellID(2)), ratio: 0.2),
        ])
        guard case .container(_, _, let children)? = LayoutOps.close(tree, cell: CellID(0)) else {
            Issue.record("expected container")
            return
        }
        #expect(abs(children[0].ratio - 0.6) < 1e-9)
        #expect(abs(children[1].ratio - 0.4) < 1e-9)
        let twoColumns = LayoutOps.preset(.twoColumns)
        #expect(LayoutOps.close(twoColumns, cell: CellID(0)) == .leaf(CellID(1)))
    }

    @Test func jsonRoundTrip() throws {
        for preset in LayoutPreset.allCases {
            let tree = LayoutOps.preset(preset)
            let data = try JSONEncoder().encode(tree)
            #expect(try JSONDecoder().decode(LayoutNode.self, from: data) == tree)
        }
    }

    @Test func autoLayoutFiveGivesThreePlusTwo() {
        guard case .container(_, .vertical, let rows)? = LayoutOps.autoLayout(5) else {
            Issue.record("expected vertical container")
            return
        }
        #expect(rows.map { $0.node.leafIDs.count } == [3, 2])
    }

    @Test func autoLayoutHandlesSmallCounts() {
        #expect(LayoutOps.autoLayout(0) == nil)
        #expect(LayoutOps.autoLayout(1)?.leafIDs.count == 1)
        #expect(LayoutOps.autoLayout(2)?.leafIDs.count == 2)
        #expect(LayoutOps.autoLayout(9)?.leafIDs.count == 9)
    }
}
