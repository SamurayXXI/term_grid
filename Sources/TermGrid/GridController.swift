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
        let fitDivider: DividerID?
        var outstanding = 0
        var fitStarted = false
        var onFinished: (() -> Void)?

        init(id: Int, pids: Set<pid_t>, runsFit: Bool, fitDivider: DividerID? = nil, onFinished: (() -> Void)?) {
            self.id = id
            self.pids = pids
            self.runsFit = runsFit
            self.fitDivider = fitDivider
            self.onFinished = onFinished
        }
    }

    private struct ActiveDrag {
        let plan: DividerDrag
        let operation: Operation
        let targets: [(CellID, AXWindow)]
        var tree: LayoutNode
    }

    let presets = LayoutPreset.allCases

    @Published private(set) var screens: [ScreenOption] = ScreenOption.current()
    @Published private(set) var windows: [DiscoveredWindow] = []
    @Published private(set) var model = GridModel<AXWindow>(tree: LayoutOps.preset(.twoColumns))
    @Published private(set) var selected: Set<AXWindow> = []
    @Published var preset: LayoutPreset = .twoColumns
    @Published var screenID: CGDirectDisplayID? = ScreenOption.current().first?.id
    @Published var gap: Int = 8
    @Published private(set) var dividersHidden = false
    private(set) var shownDividers: [Divider] = []

    private let mover = WindowMover()
    private lazy var overlay = DividerOverlay(handlers: DividerOverlay.Handlers(
        begin: { [unowned self] id, point in self.beginDrag(id, at: point) },
        move: { [unowned self] point in self.moveDrag(to: point) },
        end: { [unowned self] point in self.endDrag(at: point) },
        cancel: { [unowned self] in self.cancelDrag() },
        managesWindows: { [unowned self] pid in self.model.bindings.values.contains { $0.pid == pid } }
    ))
    private var activeDrag: ActiveDrag?
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
        refreshDividers()
    }

    func setDividersHidden(_ hidden: Bool) {
        gridLogger.notice("command setDividersHidden \(hidden)")
        dividersHidden = hidden
        refreshDividers()
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
        cancelDrag()
        model.reset()
        selected = []
        actualFrames = [:]
        refreshDividers()
    }

    func beginDrag(_ id: DividerID, at point: CGPoint) -> Bool {
        cancelDrag()
        guard !gridRect.isEmpty else { return false }
        cellFrames = solve(model.tree, in: gridRect)
        guard let plan = DividerDrag(tree: model.tree, divider: id, frames: cellFrames, gap: CGFloat(gap), origin: point) else {
            return false
        }
        let targets = boundTargets(cells: Set(plan.cells), pids: nil)
        operationCounter += 1
        latestOperation = operationCounter
        let operation = Operation(
            id: operationCounter,
            pids: Set(targets.map { $0.1.pid }),
            runsFit: false,
            fitDivider: id,
            onFinished: nil
        )
        mover.beginOperation(operation.pids)
        activeDrag = ActiveDrag(plan: plan, operation: operation, targets: targets, tree: model.tree)
        gridLogger.notice("drag begin divider=\(Self.describe(id), privacy: .public) windows=\(targets.count)")
        return true
    }

    func moveDrag(to point: CGPoint) {
        guard var drag = activeDrag else { return }
        let next = drag.plan.tree(to: point, minSizes: model.cellMinSizes, minCell: Self.minCell)
        guard next != drag.tree else { return }
        drag.tree = next
        activeDrag = drag
        let previous = cellFrames
        layout(next)
        for (cell, window) in drag.targets where model.bindings[cell] == window {
            guard let old = previous[cell], let new = cellFrames[cell], !Self.sameRect(old, new) else { continue }
            submitLive(cell, window)
        }
    }

    func endDrag(at point: CGPoint) {
        guard let drag = activeDrag else { return }
        activeDrag = nil
        layout(drag.plan.tree(to: point, minSizes: model.cellMinSizes, minCell: Self.minCell))
        let delta = String(format: "%.1f", Double(drag.plan.delta(to: point)))
        gridLogger.notice("drag end divider=\(Self.describe(drag.plan.divider.id), privacy: .public) delta=\(delta, privacy: .public)")
        for (cell, window) in drag.targets where model.bindings[cell] == window {
            submit(cell, window, drag.operation, reason: .drag)
        }
        if drag.operation.outstanding == 0 {
            finish(drag.operation)
        }
    }

    func cancelDrag() {
        guard let drag = activeDrag else { return }
        activeDrag = nil
        overlay.dragCancelled()
        gridLogger.notice("drag cancelled divider=\(Self.describe(drag.plan.divider.id), privacy: .public)")
        mover.endOperation(drag.operation.pids)
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
        cancelDrag()
        guard let grid = gridRectInAX() else {
            logApply("apply skipped no screen")
            gridRect = .zero
            refreshDividers()
            onFinished?()
            return
        }
        gridRect = grid
        cellFrames = solve(model.tree, in: grid)
        refreshDividers()
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
                refreshDividers()
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
        if !operation.fitStarted, operation.id == latestOperation {
            operation.fitStarted = true
            if let divider = operation.fitDivider {
                if startDividerFit(operation, divider) {
                    return
                }
            } else if operation.runsFit, startFit(operation) {
                return
            }
        }
        mover.endOperation(operation.pids)
        operation.onFinished?()
        operation.onFinished = nil
    }

    private func isTerminalCell(_ cell: CellID) -> Bool {
        guard let window = model.bindings[cell], let bundleId = windowInfo[window]?.bundleId else { return false }
        return Self.terminalBundleIds.contains(bundleId)
    }

    private func startFit(_ operation: Operation) -> Bool {
        let grid = gridRect
        guard let plan = GridFit.plan(
            tree: model.tree,
            cellFrames: cellFrames,
            actualFrames: actualFrames,
            gap: CGFloat(gap),
            isTerminalCell: isTerminalCell,
            solve: { solve($0, in: grid) }
        ) else { return false }
        for id in plan.skipped {
            logApply("fit skipped divider=\(Self.describe(id))")
        }
        guard !plan.adjustments.isEmpty else { return false }
        for adjustment in plan.adjustments {
            logFitAdjusted(adjustment.divider, delta: adjustment.delta)
        }
        return submitFit(plan.tree, operation)
    }

    private func startDividerFit(_ operation: Operation, _ id: DividerID) -> Bool {
        let grid = gridRect
        switch GridFit.fit(
            divider: id,
            tree: model.tree,
            cellFrames: cellFrames,
            actualFrames: actualFrames,
            gap: CGFloat(gap),
            isTerminalCell: isTerminalCell,
            solve: { solve($0, in: grid) }
        ) {
        case .notApplicable:
            logApply("fit skipped divider=\(Self.describe(id)) reason=notApplicable")
            return false
        case .skipped:
            logApply("fit skipped divider=\(Self.describe(id))")
            return false
        case .adjusted(let tree, _, let delta):
            logFitAdjusted(id, delta: delta)
            return submitFit(tree, operation)
        }
    }

    private func logFitAdjusted(_ id: DividerID, delta: CGFloat) {
        logApply("fit adjusted divider=\(Self.describe(id)) delta=\(String(format: "%.1f", Double(delta)))")
    }

    private func submitFit(_ tree: LayoutNode, _ operation: Operation) -> Bool {
        let previous = cellFrames
        layout(tree)
        for (cell, window) in boundTargets(cells: nil, pids: nil) {
            guard let old = previous[cell], let new = cellFrames[cell], !Self.sameRect(old, new) else { continue }
            submit(cell, window, operation, reason: .fit)
        }
        return operation.outstanding > 0
    }

    private func submitLive(_ cell: CellID, _ window: AXWindow) {
        guard let frame = cellFrames[cell] else { return }
        let generation = model.nextGeneration(for: window)
        mover.request(
            window,
            frame: frame,
            generation: generation,
            final: false,
            reason: .live,
            cell: cell
        ) { [weak self] result in
            self?.completedLive(result, cell: cell)
        }
    }

    private func completedLive(_ result: ApplyResult, cell: CellID) {
        guard result.status == .invalidElement,
              model.complete(
                  window: result.window,
                  cell: cell,
                  generation: result.generation,
                  status: result.status,
                  requested: result.requested,
                  actual: result.actual
              )
        else { return }
        actualFrames[cell] = nil
        logApply("cell status=\(model.status(of: cell).rawValue) cell=\(cell.rawValue)")
        refreshDividers()
    }

    private func layout(_ tree: LayoutNode) {
        model.replaceTree(tree)
        cellFrames = solve(tree, in: gridRect)
        refreshDividers()
    }

    private func refreshDividers() {
        let visible = !dividersHidden && !model.bindings.isEmpty && !gridRect.isEmpty
        let dividers = visible
            ? Dividers.compute(model.tree, frames: cellFrames, gap: CGFloat(gap)).filter(\.isGrabbable)
            : []
        shownDividers = dividers
        overlay.show(dividers, primaryHeight: NSScreen.screens.first?.frame.height ?? 0)
    }

    private nonisolated static func describe(_ id: DividerID) -> String {
        "\(id.container.rawValue).\(id.index)"
    }

    private nonisolated static func sameRect(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }
}
