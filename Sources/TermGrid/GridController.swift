import AppKit
import GridCore
import os

private let gridLogger = Logger(subsystem: "local.termgrid", category: "ui")

struct ScreenOption: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String

    static func current() -> [ScreenOption] {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[key] as? NSNumber else {
                return nil
            }
            return ScreenOption(id: CGDirectDisplayID(number.uint32Value), name: screen.localizedName)
        }
    }
}

extension LayoutPreset {
    var title: String {
        switch self {
        case .twoColumns: "2 колонки"
        case .threeColumns: "3 колонки"
        case .twoRows: "2 строки"
        case .grid2x2: "Сетка 2×2"
        case .onePlusTwo: "1 + 2"
        case .grid2x3: "Сетка 2×3"
        }
    }
}

extension CellStatus {
    var title: String {
        switch self {
        case .ok: "ок"
        case .doesNotFit: "не вписывается"
        case .detached: "откреплено"
        case .empty: "пусто"
        case .notResponding: "не отвечает"
        }
    }
}

@MainActor
final class GridController: ObservableObject {
    static let shared = GridController()
    static let gapChoices: [Int] = [0, 4, 8, 12, 16]
    static let terminalBundleIds: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    private static let minCell = CGSize(width: 120, height: 80)

    private final class Operation {
        let id: Int
        let pids: Set<pid_t>
        let runsFit: Bool
        var outstanding = 0
        var fitStarted = false
        var onFinished: (() -> Void)?

        init(id: Int, pids: Set<pid_t>, runsFit: Bool, onFinished: (() -> Void)?) {
            self.id = id
            self.pids = pids
            self.runsFit = runsFit
            self.onFinished = onFinished
        }
    }

    let presets = LayoutPreset.allCases

    @Published private(set) var screens: [ScreenOption] = ScreenOption.current()
    @Published private(set) var windows: [DiscoveredWindow] = []
    @Published private(set) var model = GridModel<AXWindow>(tree: LayoutOps.preset(.twoColumns))
    @Published private(set) var selected: Set<AXWindow> = []
    @Published var preset: LayoutPreset = .twoColumns
    @Published var screenID: CGDirectDisplayID? = ScreenOption.current().first?.id
    @Published var gap: Int = 8

    private let mover = WindowMover()
    private var windowInfo: [AXWindow: DiscoveredWindow] = [:]
    private var actualFrames: [CellID: CGRect] = [:]
    private var cellFrames: [CellID: CGRect] = [:]
    private var gridRect = CGRect.zero
    private var refreshGeneration = 0
    private var operationCounter = 0
    private var latestOperation = 0

    var selectedWindows: [DiscoveredWindow] {
        windows.filter { selected.contains($0.window) }
    }

    func title(of cell: CellID) -> String? {
        model.bindings[cell].flatMap { windowInfo[$0]?.displayTitle }
    }

    func cell(of window: DiscoveredWindow) -> CellID? {
        model.cell(of: window.window)
    }

    func toggleSelection(_ window: DiscoveredWindow) {
        if selected.contains(window.window) {
            selected.remove(window.window)
        } else {
            selected.insert(window.window)
        }
    }

    func refreshWindows() {
        screens = ScreenOption.current()
        if screenID == nil || !screens.contains(where: { $0.id == screenID }) {
            screenID = screens.first?.id
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        Task.detached(priority: .userInitiated) {
            let snapshot = WindowDiscovery.snapshot()
            await MainActor.run {
                if generation == self.refreshGeneration {
                    self.windows = snapshot
                    self.selected.formIntersection(snapshot.map(\.window))
                    logApply("windows discovered count=\(snapshot.count)")
                }
            }
        }
    }

    func setPreset(_ preset: LayoutPreset) {
        self.preset = preset
        gridLogger.notice("command setPreset \(preset.title, privacy: .public)")
        model.applyPreset(LayoutOps.preset(preset))
        actualFrames = [:]
        apply()
    }

    func setScreen(_ id: CGDirectDisplayID) {
        screenID = id
        gridLogger.notice("command setScreen \(id)")
        apply()
    }

    func setGap(_ gap: Int) {
        self.gap = gap
        gridLogger.notice("command setGap \(gap)")
        apply()
    }

    func autoArrange(_ windows: [DiscoveredWindow]) {
        gridLogger.notice("command autoArrange count=\(windows.count)")
        guard model.autoArrange(windows.map(\.window)) else { return }
        for window in windows {
            windowInfo[window.window] = window
        }
        actualFrames = [:]
        apply()
    }

    func assign(_ window: DiscoveredWindow, to cell: CellID) {
        assignAll([(window, cell)])
    }

    func assignAll(_ assignments: [(DiscoveredWindow, CellID)], onFinished: (() -> Void)? = nil) {
        gridLogger.notice("command assign count=\(assignments.count)")
        var affected = Set<CellID>()
        for (window, cell) in assignments {
            windowInfo[window.window] = window
            affected.formUnion(model.assign(window.window, to: cell))
        }
        for cell in affected {
            actualFrames[cell] = nil
        }
        apply(cells: affected, onFinished: onFinished)
    }

    func split(_ cell: CellID, axis: Axis) {
        gridLogger.notice("command split cell=\(cell.rawValue)")
        guard model.split(cell, axis: axis) else { return }
        apply()
    }

    func close(_ cell: CellID) {
        gridLogger.notice("command close cell=\(cell.rawValue)")
        guard model.close(cell) else { return }
        actualFrames[cell] = nil
        apply()
    }

    func release(_ cell: CellID) {
        gridLogger.notice("command release cell=\(cell.rawValue)")
        model.unbind(cell)
        actualFrames[cell] = nil
    }

    func retry(_ cell: CellID) {
        gridLogger.notice("command retry cell=\(cell.rawValue)")
        apply(cells: [cell], runsFit: false)
    }

    func reapply(onFinished: (() -> Void)? = nil) {
        gridLogger.notice("command reapply")
        apply(onFinished: onFinished)
    }

    func reapply(pids: Set<pid_t>, onFinished: (() -> Void)? = nil) {
        gridLogger.notice("command reapply pids=\(pids.count)")
        apply(pids: pids, runsFit: false, onFinished: onFinished)
    }

    func reset() {
        gridLogger.notice("command reset")
        model.reset()
        selected = []
        actualFrames = [:]
    }

    private func screen(for id: CGDirectDisplayID?) -> NSScreen? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return NSScreen.screens.first { screen in
            (screen.deviceDescription[key] as? NSNumber)?.uint32Value == id
        } ?? NSScreen.main
    }

    private func gridRectInAX() -> CGRect? {
        guard let screen = screen(for: screenID), let primary = NSScreen.screens.first else { return nil }
        let inset = CGFloat(gap)
        let area = screen.visibleFrame.insetBy(dx: inset, dy: inset)
        return ScreenSpace.toAX(area, primaryHeight: primary.frame.height)
    }

    private func solve(_ tree: LayoutNode, in grid: CGRect) -> [CellID: CGRect] {
        FrameSolver.frames(tree, in: grid, gap: CGFloat(gap), minCell: Self.minCell)
    }

    private func apply(
        cells: Set<CellID>? = nil,
        pids: Set<pid_t>? = nil,
        runsFit: Bool = true,
        onFinished: (() -> Void)? = nil
    ) {
        guard let grid = gridRectInAX() else {
            logApply("apply skipped no screen")
            onFinished?()
            return
        }
        gridRect = grid
        cellFrames = solve(model.tree, in: grid)
        let targets = boundTargets(cells: cells, pids: pids)
        guard !targets.isEmpty else {
            onFinished?()
            return
        }
        operationCounter += 1
        latestOperation = operationCounter
        let operation = Operation(
            id: operationCounter,
            pids: Set(targets.map { $0.1.pid }),
            runsFit: runsFit,
            onFinished: onFinished
        )
        mover.beginOperation(operation.pids)
        for (cell, window) in targets {
            submit(cell, window, operation, reason: .apply)
        }
    }

    private func boundTargets(cells: Set<CellID>?, pids: Set<pid_t>?) -> [(CellID, AXWindow)] {
        model.cells.compactMap { cell in
            guard let window = model.bindings[cell],
                  cells?.contains(cell) ?? true,
                  pids?.contains(window.pid) ?? true
            else { return nil }
            return (cell, window)
        }
    }

    private func submit(_ cell: CellID, _ window: AXWindow, _ operation: Operation, reason: ApplyReason) {
        guard let frame = cellFrames[cell] else { return }
        let generation = model.nextGeneration(for: window)
        operation.outstanding += 1
        mover.request(
            window,
            frame: frame,
            generation: generation,
            final: true,
            reason: reason,
            cell: cell,
            outerEdges: GridFit.outerEdges(of: frame, in: gridRect)
        ) { [weak self] result in
            self?.completed(result, cell: cell, operation: operation)
        }
    }

    private func completed(_ result: ApplyResult, cell: CellID, operation: Operation) {
        operation.outstanding -= 1
        let accepted = model.complete(
            window: result.window,
            cell: cell,
            generation: result.generation,
            status: result.status,
            requested: result.requested,
            actual: result.actual
        )
        if accepted {
            if let actual = result.actual {
                actualFrames[cell] = actual
            }
            if model.bindings[cell] == nil {
                actualFrames[cell] = nil
            }
            logApply("cell status=\(model.status(of: cell).rawValue) cell=\(cell.rawValue)")
        } else {
            logApply(
                "completion ignored cell=\(cell.rawValue) generation=\(result.generation)"
                    + " status=\(result.status.rawValue)"
            )
        }
        if operation.outstanding == 0 {
            finish(operation)
        }
    }

    private func finish(_ operation: Operation) {
        if operation.runsFit, !operation.fitStarted, operation.id == latestOperation, startFit(operation) {
            return
        }
        mover.endOperation(operation.pids)
        operation.onFinished?()
        operation.onFinished = nil
    }

    private func startFit(_ operation: Operation) -> Bool {
        operation.fitStarted = true
        let grid = gridRect
        let isTerminal: (CellID) -> Bool = { [model, windowInfo] cell in
            guard let window = model.bindings[cell], let bundleId = windowInfo[window]?.bundleId else { return false }
            return Self.terminalBundleIds.contains(bundleId)
        }
        guard let plan = GridFit.plan(
            tree: model.tree,
            cellFrames: cellFrames,
            actualFrames: actualFrames,
            gap: CGFloat(gap),
            isTerminalCell: isTerminal,
            solve: { solve($0, in: grid) }
        ) else { return false }
        for id in plan.skipped {
            logApply("fit skipped divider=\(id.container.rawValue).\(id.index)")
        }
        guard !plan.adjustments.isEmpty else { return false }
        for adjustment in plan.adjustments {
            let id = adjustment.divider
            logApply(
                "fit adjusted divider=\(id.container.rawValue).\(id.index)"
                    + " delta=\(String(format: "%.1f", Double(adjustment.delta)))"
            )
        }
        let previous = cellFrames
        model.replaceTree(plan.tree)
        cellFrames = solve(plan.tree, in: grid)
        for (cell, window) in boundTargets(cells: nil, pids: nil) {
            guard let old = previous[cell], let new = cellFrames[cell], !Self.sameRect(old, new) else { continue }
            submit(cell, window, operation, reason: .fit)
        }
        return operation.outstanding > 0
    }

    private nonisolated static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}
