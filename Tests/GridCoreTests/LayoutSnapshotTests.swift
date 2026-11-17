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

    @Test func gapOutOfRangeThrows() throws {
        var snapshot = sample()
        snapshot.gap = -1
        let data = try snapshot.encoded()
        #expect(throws: LayoutSnapshotError.invalid) {
            try LayoutSnapshot.decode(data)
        }
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
}
