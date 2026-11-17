import Foundation
import Testing
@testable import GridCore

@Suite struct LayoutSnapshotTests {
    private func sample() -> LayoutSnapshot {
        let tree = LayoutNode.container(ContainerID(0), .horizontal, [
            LayoutChild(node: .leaf(CellID(0)), ratio: 0.3),
            LayoutChild(node: .leaf(CellID(1)), ratio: 0.7),
        ])
        return LayoutSnapshot(
            tree: tree,
            gap: 8,
            screen: ScreenHint(name: "Built-in", width: 1512, height: 982),
            bindings: [
                SavedBinding(cellID: CellID(0), bundleId: "com.apple.Terminal", title: "a"),
                SavedBinding(cellID: CellID(1), bundleId: "com.googlecode.iterm2", title: "b"),
            ]
        )
    }

    private func temporaryStore() -> LayoutStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("termgrid-tests-\(UUID().uuidString)")
        return LayoutStore(url: directory.appendingPathComponent("layout.json"))
    }

    @Test func roundTrip() throws {
        let snapshot = sample()
        #expect(try LayoutSnapshot.decode(snapshot.encoded()) == snapshot)
    }

    @Test func garbageThrows() {
        #expect(throws: (any Error).self) {
            try LayoutSnapshot.decode(Data("not json {".utf8))
        }
    }

    @Test func emptyDataThrows() {
        #expect(throws: (any Error).self) {
            try LayoutSnapshot.decode(Data())
        }
    }

    @Test func wrongShapeThrows() {
        #expect(throws: (any Error).self) {
            try LayoutSnapshot.decode(Data("{\"gap\": 8}".utf8))
        }
    }

    @Test func invalidRatiosThrow() throws {
        var snapshot = sample()
        snapshot.tree = .container(ContainerID(0), .horizontal, [
            LayoutChild(node: .leaf(CellID(0)), ratio: 0.3),
            LayoutChild(node: .leaf(CellID(1)), ratio: 0.3),
        ])
        let data = try snapshot.encoded()
        #expect(throws: LayoutSnapshotError.invalid) {
            try LayoutSnapshot.decode(data)
        }
    }

    @Test func bindingToMissingCellThrows() throws {
        var snapshot = sample()
        snapshot.bindings.append(SavedBinding(cellID: CellID(9), bundleId: "x", title: "y"))
        let data = try snapshot.encoded()
        #expect(throws: LayoutSnapshotError.invalid) {
            try LayoutSnapshot.decode(data)
        }
    }

    @Test func gapOutOfRangeLoadsAsDefault() throws {
        for gap in [-1, 0, 3, 17, 64] {
            var snapshot = sample()
            snapshot.gap = gap
            let decoded = try LayoutSnapshot.decode(snapshot.encoded())
            #expect(decoded.gap == LayoutSnapshot.defaultGap)
            #expect(decoded.tree == snapshot.tree)
        }
    }

    @Test func gapInsideRangeIsKept() throws {
        for gap in [4, 12, 16] {
            var snapshot = sample()
            snapshot.gap = gap
            #expect(try LayoutSnapshot.decode(snapshot.encoded()).gap == gap)
        }
    }

    @Test func cellIdOutsideRangeThrows() throws {
        for raw in [-1, 10_000, Int.max] {
            var snapshot = sample()
            snapshot.tree = .container(ContainerID(0), .horizontal, [
                LayoutChild(node: .leaf(CellID(0)), ratio: 0.5),
                LayoutChild(node: .leaf(CellID(raw)), ratio: 0.5),
            ])
            snapshot.bindings = []
            let data = try snapshot.encoded()
            #expect(throws: LayoutSnapshotError.invalid) {
                try LayoutSnapshot.decode(data)
            }
        }
    }

    @Test func containerIdOutsideRangeThrows() throws {
        var snapshot = sample()
        snapshot.tree = .container(ContainerID(Int.max), .horizontal, [
            LayoutChild(node: .leaf(CellID(0)), ratio: 0.5),
            LayoutChild(node: .leaf(CellID(1)), ratio: 0.5),
        ])
        let data = try snapshot.encoded()
        #expect(throws: LayoutSnapshotError.invalid) {
            try LayoutSnapshot.decode(data)
        }
    }

    @Test func tooManyCellsThrow() throws {
        let count = LayoutSnapshot.maxCells + 1
        var snapshot = sample()
        snapshot.tree = .container(ContainerID(0), .horizontal, (0..<count).map {
            LayoutChild(node: .leaf(CellID($0)), ratio: 1 / Double(count))
        })
        snapshot.bindings = []
        let data = try snapshot.encoded()
        #expect(throws: LayoutSnapshotError.invalid) {
            try LayoutSnapshot.decode(data)
        }
    }

    @Test func maxIdTreeStillSplits() throws {
        var snapshot = sample()
        snapshot.tree = .container(ContainerID(9_999), .horizontal, [
            LayoutChild(node: .leaf(CellID(0)), ratio: 0.5),
            LayoutChild(node: .leaf(CellID(9_999)), ratio: 0.5),
        ])
        snapshot.bindings = []
        let decoded = try LayoutSnapshot.decode(snapshot.encoded())
        let split = LayoutOps.split(decoded.tree, cell: CellID(9_999), axis: .vertical)
        #expect(split.leafIDs.contains(CellID(10_000)))
    }

    @Test func unreadableFileIsNotQuarantined() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: store.url, withIntermediateDirectories: true)
        #expect(store.load() == .unreadable)
        #expect(FileManager.default.fileExists(atPath: store.url.path))
        #expect(!FileManager.default.fileExists(atPath: store.badURL.path))
    }

    @Test func storeSavesAndLoads() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        #expect(store.load() == .missing)
        try store.save(sample())
        #expect(store.load() == .loaded(sample()))
    }

    @Test func corruptFileIsRenamedToBad() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("garbage".utf8).write(to: store.url)
        #expect(store.load() == .corrupt)
        #expect(!FileManager.default.fileExists(atPath: store.url.path))
        #expect(FileManager.default.fileExists(atPath: store.badURL.path))
        #expect(store.load() == .missing)
    }

    @Test func secondCorruptFileReplacesBad() throws {
        let store = temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: store.url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("one".utf8).write(to: store.badURL)
        try Data("two".utf8).write(to: store.url)
        #expect(store.load() == .corrupt)
        #expect(try Data(contentsOf: store.badURL) == Data("two".utf8))
    }

    @Test func matchPrefersExactTitle() {
        let bindings = [
            SavedBinding(cellID: CellID(0), bundleId: "t", title: "second"),
            SavedBinding(cellID: CellID(1), bundleId: "t", title: "first"),
        ]
        let windows: [(bundleId: String?, title: String)] = [("t", "first"), ("t", "second")]
        #expect(LayoutSnapshot.match(bindings, windows: windows) == [CellID(0): 1, CellID(1): 0])
    }

    @Test func matchFallsBackToSameBundleInOrder() {
        let bindings = [
            SavedBinding(cellID: CellID(0), bundleId: "t", title: "gone1"),
            SavedBinding(cellID: CellID(1), bundleId: "t", title: "gone2"),
            SavedBinding(cellID: CellID(2), bundleId: "other", title: "x"),
        ]
        let windows: [(bundleId: String?, title: String)] = [("t", "n1"), ("z", "n2"), ("t", "n3")]
        #expect(LayoutSnapshot.match(bindings, windows: windows) == [CellID(0): 0, CellID(1): 2])
    }

    @Test func exactMatchesClaimWindowsBeforeFallback() {
        let bindings = [
            SavedBinding(cellID: CellID(0), bundleId: "t", title: "gone"),
            SavedBinding(cellID: CellID(1), bundleId: "t", title: "kept"),
        ]
        let windows: [(bundleId: String?, title: String)] = [("t", "kept"), ("t", "new")]
        #expect(LayoutSnapshot.match(bindings, windows: windows) == [CellID(0): 1, CellID(1): 0])
    }

    @Test func matchIgnoresWindowsWithoutBundle() {
        let bindings = [SavedBinding(cellID: CellID(0), bundleId: "t", title: "a")]
        let windows: [(bundleId: String?, title: String)] = [(nil, "a")]
        #expect(LayoutSnapshot.match(bindings, windows: windows).isEmpty)
    }

    @Test func restorableSkipsMissingBoundAndDetachedCells() {
        let pending = [
            SavedBinding(cellID: CellID(0), bundleId: "t", title: "a"),
            SavedBinding(cellID: CellID(1), bundleId: "t", title: "b"),
            SavedBinding(cellID: CellID(2), bundleId: "t", title: "c"),
            SavedBinding(cellID: CellID(7), bundleId: "t", title: "gone"),
        ]
        let result = LayoutSnapshot.restorable(
            pending,
            cells: [CellID(0), CellID(1), CellID(2)],
            occupied: [CellID(1), CellID(2)]
        )
        #expect(result == [pending[0]])
    }

    @Test func unmatchedKeepsOnlyHintsWithoutWindow() {
        let pending = [
            SavedBinding(cellID: CellID(0), bundleId: "t", title: "a"),
            SavedBinding(cellID: CellID(1), bundleId: "u", title: "b"),
        ]
        let matches = LayoutSnapshot.match(pending, windows: [("t", "a")])
        #expect(LayoutSnapshot.unmatched(pending, matches: matches) == [pending[1]])
        #expect(LayoutSnapshot.unmatched(pending, matches: [CellID(0): 0, CellID(1): 1]).isEmpty)
    }

    @Test func restoreAfterUserAssignmentDropsTheAssignedCell() {
        let pending = [
            SavedBinding(cellID: CellID(0), bundleId: "t", title: "a"),
            SavedBinding(cellID: CellID(1), bundleId: "t", title: "b"),
        ]
        let cells = [CellID(0), CellID(1)]
        let atClick = LayoutSnapshot.restorable(pending, cells: cells, occupied: [])
        let atSnapshot = LayoutSnapshot.restorable(pending, cells: cells, occupied: [CellID(0)])
            .filter(atClick.contains)
        #expect(atSnapshot == [pending[1]])
        let matches = LayoutSnapshot.match(atSnapshot, windows: [("t", "a"), ("t", "b")])
        #expect(matches == [CellID(1): 1])
        #expect(LayoutSnapshot.unmatched(atSnapshot, matches: matches).isEmpty)
    }
}
