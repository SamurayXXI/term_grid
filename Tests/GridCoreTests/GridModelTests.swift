import CoreGraphics
import Testing
@testable import GridCore

@Suite struct GridModelTests {
    private func model(_ preset: LayoutPreset = .twoColumns) -> GridModel<String> {
        GridModel<String>(tree: LayoutOps.preset(preset))
    }

    @Test func assignBindsWindowToCell() {
        var grid = model()
        let affected = grid.assign("a", to: CellID(1))
        #expect(affected == [CellID(1)])
        #expect(grid.bindings == [CellID(1): "a"])
        #expect(grid.status(of: CellID(1)) == .ok)
        #expect(grid.status(of: CellID(0)) == .empty)
    }

    @Test func assignToUnknownCellChangesNothing() {
        var grid = model()
        let affected = grid.assign("a", to: CellID(9))
        #expect(affected.isEmpty)
        #expect(grid.bindings.isEmpty)
    }

    @Test func assignWindowFromOtherCellSwapsCells() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        grid.assign("b", to: CellID(1))
        let affected = grid.assign("a", to: CellID(1))
        #expect(Set(affected) == [CellID(0), CellID(1)])
        #expect(grid.bindings == [CellID(0): "b", CellID(1): "a"])
    }

    @Test func assignWindowIntoEmptyCellMovesIt() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        grid.assign("a", to: CellID(1))
        #expect(grid.bindings == [CellID(1): "a"])
        #expect(grid.status(of: CellID(0)) == .empty)
    }

    @Test func assignDisplacedWindowBecomesUnbound() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        grid.assign("b", to: CellID(0))
        #expect(grid.bindings == [CellID(0): "b"])
        #expect(grid.cell(of: "a") == nil)
    }

    @Test func presetKeepsBindingsByCellOrder() {
        var grid = model(.twoColumns)
        grid.assign("a", to: CellID(0))
        grid.assign("b", to: CellID(1))
        grid.applyPreset(LayoutOps.preset(.grid2x2))
        #expect(grid.bindings == [CellID(0): "a", CellID(1): "b"])
        #expect(grid.cells.count == 4)
    }

    @Test func presetWithFewerCellsDropsExtraBindings() {
        var grid = model(.grid2x2)
        grid.assign("a", to: CellID(0))
        grid.assign("d", to: CellID(3))
        grid.applyPreset(LayoutOps.preset(.twoColumns))
        #expect(grid.bindings == [CellID(0): "a"])
    }

    @Test func presetPreservesGapsInCellOrder() {
        var grid = model(.threeColumns)
        grid.assign("c", to: CellID(2))
        grid.applyPreset(LayoutOps.preset(.grid2x2))
        #expect(grid.bindings == [CellID(2): "c"])
    }

    @Test func autoArrangeBindsInOrderAndDeduplicates() {
        var grid = model()
        let result = grid.autoArrange(["a", "b", "a", "c"])
        #expect(result)
        #expect(grid.cells.count == 3)
        #expect(grid.bindings[grid.cells[0]] == "a")
        #expect(grid.bindings[grid.cells[2]] == "c")
    }

    @Test func autoArrangeWithNoWindowsKeepsState() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let result = grid.autoArrange([])
        #expect(!result)
        #expect(grid.bindings == [CellID(0): "a"])
    }

    @Test func splitAddsEmptyCell() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let result = grid.split(CellID(0), axis: .vertical)
        #expect(result)
        #expect(grid.cells.count == 3)
        #expect(grid.bindings == [CellID(0): "a"])
    }

    @Test func closeRemovesCellAndBinding() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        grid.assign("b", to: CellID(1))
        let result = grid.close(CellID(0))
        #expect(result)
        #expect(grid.cells == [CellID(1)])
        #expect(grid.bindings == [CellID(1): "b"])
    }

    @Test func closeLastCellKeepsTreeAndUnbinds() {
        var grid = GridModel<String>(tree: .leaf(CellID(0)))
        grid.assign("a", to: CellID(0))
        let result = grid.close(CellID(0))
        #expect(result)
        #expect(grid.cells == [CellID(0)])
        #expect(grid.bindings.isEmpty)
    }

    @Test func generationsIncreasePerWindow() {
        var grid = model()
        #expect(grid.nextGeneration(for: "a") == 1)
        #expect(grid.nextGeneration(for: "a") == 2)
        #expect(grid.nextGeneration(for: "b") == 1)
    }

    @Test func staleGenerationCompletionIsIgnored() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let first = grid.nextGeneration(for: "a")
        _ = grid.nextGeneration(for: "a")
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let accepted = grid.complete(window: "a", cell: CellID(0), generation: first, status: .refused, requested: rect, actual: rect)
        #expect(!accepted)
        #expect(grid.status(of: CellID(0)) == .ok)
    }

    @Test func completionForRebindWindowIsIgnored() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let generation = grid.nextGeneration(for: "a")
        grid.assign("a", to: CellID(1))
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = grid.complete(window: "a", cell: CellID(0), generation: generation, status: .ok, requested: rect, actual: rect)
        #expect(!result)
    }

    @Test func supersededCompletionIsIgnored() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let generation = grid.nextGeneration(for: "a")
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        let result = grid.complete(window: "a", cell: CellID(0), generation: generation, status: .superseded, requested: rect, actual: nil)
        #expect(!result)
    }

    @Test func statusMappingForCurrentCompletions() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        func complete(_ status: ApplyStatus) {
            let generation = grid.nextGeneration(for: "a")
            let result = grid.complete(window: "a", cell: CellID(0), generation: generation, status: status, requested: rect, actual: rect)
            #expect(result)
        }
        complete(.refused)
        #expect(grid.status(of: CellID(0)) == .doesNotFit)
        complete(.timeout)
        #expect(grid.status(of: CellID(0)) == .notResponding)
        #expect(grid.bindings[CellID(0)] == "a")
        complete(.ok)
        #expect(grid.status(of: CellID(0)) == .ok)
        complete(.invalidElement)
        #expect(grid.status(of: CellID(0)) == .empty)
        #expect(grid.bindings.isEmpty)
    }

    @Test func clampedLargerThanRequestedRecordsMinSize() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        let generation = grid.nextGeneration(for: "a")
        let requested = CGRect(x: 0, y: 0, width: 100, height: 100)
        let actual = CGRect(x: 0, y: 0, width: 160, height: 100)
        grid.complete(window: "a", cell: CellID(0), generation: generation, status: .clamped, requested: requested, actual: actual)
        #expect(grid.cellMinSizes[CellID(0)] == CGSize(width: 160, height: 0))
        #expect(grid.status(of: CellID(0)) == .ok)
    }

    @Test func clampedSmallerThanRequestedRecordsNoMinSize() {
        let requested = CGRect(x: 0, y: 0, width: 100, height: 100)
        let actual = CGRect(x: 0, y: 0, width: 90, height: 100)
        #expect(GridModel<String>.minSize(requested: requested, actual: actual) == nil)
    }

    @Test func markDetachedKeepsStatusWithoutBinding() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        grid.markDetached(CellID(0))
        #expect(grid.status(of: CellID(0)) == .detached)
        #expect(grid.bindings.isEmpty)
    }

    @Test func resetClearsBindingsAndKeepsTree() {
        var grid = model()
        grid.assign("a", to: CellID(0))
        grid.reset()
        #expect(grid.bindings.isEmpty)
        #expect(grid.cells.count == 2)
    }
}
