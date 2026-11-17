import Testing
@testable import GridCore

@Suite struct LayoutOpsTests {
    @Test func splitProducesFreshIdentifiers() {
        let tree = LayoutOps.preset(.twoColumns)
        let split = LayoutOps.split(tree, cell: CellID(0), axis: .vertical)
        #expect(Set(split.leafIDs).count == 3)
        #expect(Set(split.containerIDs.map(\.rawValue)).count == 2)
    }

    @Test func splitOnLeafRootCreatesTwoEqualChildren() {
        let split = LayoutOps.split(.leaf(CellID(0)), cell: CellID(0), axis: .horizontal)
        guard case .container(_, .horizontal, let children) = split else {
            Issue.record("expected container")
            return
        }
        #expect(children.map(\.ratio) == [0.5, 0.5])
    }

    @Test func autoLayoutLeavesAreUniqueAndOrdered() {
        let leaves = LayoutOps.autoLayout(7)?.leafIDs.map(\.rawValue)
        #expect(leaves == Array(0..<7))
    }
}
