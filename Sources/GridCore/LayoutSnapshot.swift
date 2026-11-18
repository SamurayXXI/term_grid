import Foundation

public struct SavedBinding: Codable, Equatable, Sendable {
    public let cellID: CellID
    public let bundleId: String
    public let title: String

    public init(cellID: CellID, bundleId: String, title: String) {
        self.cellID = cellID
        self.bundleId = bundleId
        self.title = title
    }
}

public struct ScreenHint: Codable, Equatable, Sendable {
    public let name: String
    public let width: Double
    public let height: Double

    public init(name: String, width: Double, height: Double) {
        self.name = name
        self.width = width
        self.height = height
    }
}

public enum LayoutSnapshotError: Error, Equatable {
    case invalid
}

public struct LayoutSnapshot: Codable, Equatable, Sendable {
    public static let gapRange = 0...8
    public static let defaultGap = 4
    public static let idRange = 0..<10_000
    public static let maxCells = 64
    private static let ratioTolerance = 1e-3

    public var tree: LayoutNode
    public var gap: Int
    public var insets: GridInsets?
    public var screen: ScreenHint?
    public var bindings: [SavedBinding]

    public init(tree: LayoutNode, gap: Int, screen: ScreenHint?, bindings: [SavedBinding], insets: GridInsets? = nil) {
        self.tree = tree
        self.gap = gap
        self.insets = insets
        self.screen = screen
        self.bindings = bindings
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> LayoutSnapshot {
        var snapshot = try JSONDecoder().decode(LayoutSnapshot.self, from: data)
        guard snapshot.isValid else {
            throw LayoutSnapshotError.invalid
        }
        if !gapRange.contains(snapshot.gap) {
            snapshot.gap = defaultGap
        }
        return snapshot
    }

    public static func restorable(_ pending: [SavedBinding], cells: [CellID], occupied: Set<CellID>) -> [SavedBinding] {
        pending.filter { cells.contains($0.cellID) && !occupied.contains($0.cellID) }
    }

    public static func unmatched(_ pending: [SavedBinding], matches: [CellID: Int]) -> [SavedBinding] {
        pending.filter { matches[$0.cellID] == nil }
    }

    public static func match(_ bindings: [SavedBinding], windows: [(bundleId: String?, title: String)]) -> [CellID: Int] {
        var result: [CellID: Int] = [:]
        var used = Set<Int>()
        for binding in bindings {
            let found = windows.indices.first { index in
                !used.contains(index)
                    && windows[index].bundleId == binding.bundleId
                    && windows[index].title == binding.title
            }
            if let found {
                result[binding.cellID] = found
                used.insert(found)
            }
        }
        for binding in bindings where result[binding.cellID] == nil {
            let found = windows.indices.first { index in
                !used.contains(index) && windows[index].bundleId == binding.bundleId
            }
            if let found {
                result[binding.cellID] = found
                used.insert(found)
            }
        }
        return result
    }

    private var isValid: Bool {
        guard Self.isValid(tree) else { return false }
        let leaves = tree.leafIDs
        let containers = tree.containerIDs
        guard leaves.count <= Self.maxCells,
              leaves.allSatisfy({ Self.idRange.contains($0.rawValue) }),
              containers.allSatisfy({ Self.idRange.contains($0.rawValue) }),
              Set(leaves).count == leaves.count,
              Set(containers).count == containers.count
        else { return false }
        let bound = bindings.map(\.cellID)
        return Set(bound).count == bound.count && bound.allSatisfy(leaves.contains)
    }

    private static func isValid(_ node: LayoutNode) -> Bool {
        switch node {
        case .leaf:
            return true
        case .container(_, _, let children):
            guard !children.isEmpty,
                  children.allSatisfy({ $0.ratio.isFinite && $0.ratio > 0 }),
                  abs(children.reduce(0) { $0 + $1.ratio } - 1) < ratioTolerance
            else { return false }
            return children.allSatisfy { isValid($0.node) }
        }
    }
}

public enum LayoutLoadResult: Equatable, Sendable {
    case missing
    case loaded(LayoutSnapshot)
    case corrupt
    case unreadable
}

public struct LayoutStore: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static var standard: LayoutStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LayoutStore(url: base.appendingPathComponent("TermGrid").appendingPathComponent("layout.json"))
    }

    public var badURL: URL {
        url.appendingPathExtension("bad")
    }

    public func save(_ snapshot: LayoutSnapshot) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try snapshot.encoded().write(to: url, options: .atomic)
    }

    public func load() -> LayoutLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        do {
            return .loaded(try LayoutSnapshot.decode(data))
        } catch {
            quarantine()
            return .corrupt
        }
    }

    private func quarantine() {
        let manager = FileManager.default
        try? manager.removeItem(at: badURL)
        try? manager.moveItem(at: url, to: badURL)
    }
}
