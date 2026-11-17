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
    static let shared = GridController(store: GridController.launchStore())
    static let gapChoices: [Int] = [4, 8, 12, 16]
    static let terminalBundleIds: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
    private static let minCell = CGSize(width: 120, height: 80)

    private final class Operation {
        let id: Int
        var pids: Set<pid_t>
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
        var lastPoint: CGPoint
    }

    let presets = LayoutPreset.allCases

    @Published private(set) var screens: [ScreenOption] = ScreenOption.current()
    @Published private(set) var windows: [DiscoveredWindow] = []
    @Published private(set) var model = GridModel<AXWindow>(tree: LayoutOps.preset(.twoColumns)) {
        didSet {
            if oldValue.bindings != model.bindings || oldValue.detached != model.detached {
                syncObservation()
            }
        }
    }
    @Published private(set) var selected: Set<AXWindow> = []
    @Published var preset: LayoutPreset = .twoColumns
    @Published var screenID: CGDirectDisplayID? = ScreenOption.current().first?.id
    @Published var gap: Int = 8
    @Published private(set) var dividersHidden = false
    private(set) var shownDividers: [Divider] = []

    @Published private(set) var pendingBindings: [SavedBinding] = []
    @Published private(set) var isRestoring = false
    private var restoreGeneration = 0

    private let store: LayoutStore
    private let mover = WindowMover()
    private lazy var overlay = DividerOverlay(handlers: DividerOverlay.Handlers(
        begin: { [unowned self] id, point in self.beginDrag(id, at: point) },
        move: { [unowned self] point in self.moveDrag(to: point) },
        end: { [unowned self] point in self.endDrag(at: point) },
        cancel: { [unowned self] in self.dragLost() },
        managesWindows: { [unowned self] pid in self.model.bindings.values.contains { $0.pid == pid } }
    ))
    private var activeDrag: ActiveDrag?
    private lazy var monitor = AXEventMonitor(mover: mover) { [unowned self] event in
        self.handle(event)
    }
    private var registry = BindingRegistry<AXWindow>()
    private var echo = EchoFilter<AXWindow>()
    private var reads = EventReadGate<AXWindow>()
    private var systemObservers: [NSObjectProtocol] = []
    private var windowInfo: [AXWindow: DiscoveredWindow] = [:]
    private var actualFrames: [CellID: CGRect] = [:]
    private var cellFrames: [CellID: CGRect] = [:]
    private var gridRect = CGRect.zero
    private var refreshGeneration = 0
    private var operationCounter = 0
    private var latestOperation = 0

    private static func launchStore() -> LayoutStore {
        #if DEBUG
        let arguments = CommandLine.arguments
        if arguments.contains(where: { $0.hasPrefix("--selftest-") }) {
            let path = arguments.firstIndex(of: "--selftest-layout-path")
                .flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
                ?? ProcessInfo.processInfo.environment["TERMGRID_LAYOUT_PATH"]
            let url = path.map { URL(fileURLWithPath: $0) }
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("termgrid-selftest")
                    .appendingPathComponent("layout.json")
            gridLogger.notice("layout store path=\(url.path, privacy: .public)")
            return LayoutStore(url: url)
        }
        #endif
        return .standard
    }

    init(store: LayoutStore = .standard) {
        self.store = store
        loadLayout()
        let workspace = NSWorkspace.shared.notificationCenter
        systemObservers.append(workspace.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let pid = application?.processIdentifier else { return }
            MainActor.assumeIsolated {
                self?.applicationTerminated(pid)
            }
        })
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screensChanged()
            }
        })
        systemObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.saveLayout()
                self?.mover.restoreAllEnhancedUI(timeout: 1)
            }
        })
    }

    var selectedWindows: [DiscoveredWindow] {
        windows.filter { selected.contains($0.window) }
    }

    func title(of cell: CellID) -> String? {
        (model.bindings[cell] ?? model.detached[cell]).flatMap { windowInfo[$0]?.displayTitle }
    }

    func cell(of window: DiscoveredWindow) -> CellID? {
        model.cell(of: window.window)
    }

    func detachedCell(of window: DiscoveredWindow) -> CellID? {
        model.detachedCell(of: window.window)
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
        pendingBindings = []
        invalidateRestore()
        actualFrames = [:]
        saveLayout()
        apply()
    }

    func setScreen(_ id: CGDirectDisplayID) {
        screenID = id
        gridLogger.notice("command setScreen \(id)")
        saveLayout()
        apply()
    }

    func setGap(_ gap: Int) {
        self.gap = gap
        gridLogger.notice("command setGap \(gap)")
        saveLayout()
        apply()
    }

    func autoArrange(_ windows: [DiscoveredWindow]) {
        gridLogger.notice("command autoArrange count=\(windows.count)")
        guard model.autoArrange(windows.map(\.window)) else { return }
        for window in windows {
            windowInfo[window.window] = window
        }
        pendingBindings = []
        invalidateRestore()
        actualFrames = [:]
        saveLayout()
        apply()
    }

    func assign(_ window: DiscoveredWindow, to cell: CellID) {
        assignAll([(window, cell)])
    }

    func assignAll(_ assignments: [(DiscoveredWindow, CellID)], onFinished: (() -> Void)? = nil) {
        gridLogger.notice("command assign count=\(assignments.count)")
        invalidateRestore()
        var affected = Set<CellID>()
        for (window, cell) in assignments {
            windowInfo[window.window] = window
            affected.formUnion(model.assign(window.window, to: cell))
        }
        for cell in affected {
            actualFrames[cell] = nil
        }
        saveLayout()
        apply(cells: affected, onFinished: onFinished)
    }

    func split(_ cell: CellID, axis: Axis) {
        gridLogger.notice("command split cell=\(cell.rawValue)")
        guard model.split(cell, axis: axis) else { return }
        saveLayout()
        apply()
    }

    func close(_ cell: CellID) {
        gridLogger.notice("command close cell=\(cell.rawValue)")
        guard model.close(cell) else { return }
        pendingBindings.removeAll { $0.cellID == cell }
        actualFrames[cell] = nil
        saveLayout()
        apply()
    }

    func release(_ cell: CellID) {
        gridLogger.notice("command release cell=\(cell.rawValue)")
        model.unbind(cell)
        pendingBindings.removeAll { $0.cellID == cell }
        actualFrames[cell] = nil
        saveLayout()
        refreshDividers()
    }

    func reattach(_ cell: CellID) {
        gridLogger.notice("command reattach cell=\(cell.rawValue)")
        guard model.reattach(cell) != nil else {
            refreshDividers()
            return
        }
        actualFrames[cell] = nil
        saveLayout()
        apply(cells: [cell])
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
        pendingBindings = []
        invalidateRestore()
        selected = []
        actualFrames = [:]
        saveLayout()
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
        activeDrag = ActiveDrag(plan: plan, operation: operation, targets: targets, tree: model.tree, lastPoint: point)
        gridLogger.notice("drag begin divider=\(Self.describe(id), privacy: .public) windows=\(targets.count)")
        return true
    }

    func moveDrag(to point: CGPoint) {
        guard var drag = activeDrag else { return }
        drag.lastPoint = point
        activeDrag = drag
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
        saveLayout()
        let delta = String(format: "%.1f", Double(drag.plan.delta(to: point)))
        gridLogger.notice("drag end divider=\(Self.describe(drag.plan.divider.id), privacy: .public) delta=\(delta, privacy: .public)")
        for (cell, window) in drag.targets where model.bindings[cell] == window {
            submit(cell, window, drag.operation, reason: .drag)
        }
        if drag.operation.outstanding == 0 {
            finish(drag.operation)
        }
    }

    private func dragLost() {
        guard let drag = activeDrag else { return }
        gridLogger.notice("drag lost divider=\(Self.describe(drag.plan.divider.id), privacy: .public)")
        endDrag(at: drag.lastPoint)
    }

    func cancelDrag() {
        guard let drag = activeDrag else { return }
        activeDrag = nil
        overlay.dragCancelled()
        gridLogger.notice("drag cancelled divider=\(Self.describe(drag.plan.divider.id), privacy: .public)")
        mover.endOperation(drag.operation.pids)
    }

    func restoreWindows(accepting: (@Sendable (DiscoveredWindow) -> Bool)? = nil, onFinished: (() -> Void)? = nil) {
        gridLogger.notice("command restoreWindows pending=\(self.pendingBindings.count)")
        guard !isRestoring else {
            onFinished?()
            return
        }
        let pending = restorablePending()
        guard !pending.isEmpty else {
            pendingBindings = []
            saveLayout()
            onFinished?()
            return
        }
        isRestoring = true
        let generation = restoreGeneration
        Task.detached(priority: .userInitiated) {
            let snapshot = WindowDiscovery.snapshot()
            await MainActor.run {
                guard generation == self.restoreGeneration else {
                    logApply("layout restore abandoned")
                    onFinished?()
                    return
                }
                self.isRestoring = false
                self.bindRestored(pending, from: snapshot, accepting: accepting, onFinished: onFinished)
            }
        }
    }

    private func restorablePending() -> [SavedBinding] {
        let occupied = Set(model.bindings.keys).union(model.detached.keys)
        return LayoutSnapshot.restorable(pendingBindings, cells: model.cells, occupied: occupied)
    }

    private func invalidateRestore() {
        restoreGeneration += 1
        isRestoring = false
    }

    private func bindRestored(
        _ captured: [SavedBinding],
        from snapshot: [DiscoveredWindow],
        accepting: (@Sendable (DiscoveredWindow) -> Bool)?,
        onFinished: (() -> Void)?
    ) {
        let current = restorablePending()
        let pending = current.filter(captured.contains)
        let candidates = snapshot.filter {
            model.cell(of: $0.window) == nil && model.detachedCell(of: $0.window) == nil && (accepting?($0) ?? true)
        }
        let matches = LayoutSnapshot.match(pending, windows: candidates.map { ($0.bundleId, $0.title) })
        let assignments = model.cells.compactMap { cell in
            matches[cell].map { (candidates[$0], cell) }
        }
        logApply("layout restore matched=\(assignments.count) pending=\(pending.count)")
        pendingBindings = LayoutSnapshot.unmatched(current, matches: matches)
        guard !assignments.isEmpty else {
            saveLayout()
            onFinished?()
            return
        }
        assignAll(assignments, onFinished: onFinished)
    }

    private func loadLayout() {
        switch store.load() {
        case .missing:
            break
        case .corrupt:
            gridLogger.notice("layout reset reason=corrupt")
        case .unreadable:
            gridLogger.error("layout load failed reason=unreadable")
        case .loaded(let snapshot):
            model = GridModel(tree: snapshot.tree)
            if Self.gapChoices.contains(snapshot.gap) {
                gap = snapshot.gap
            }
            pendingBindings = snapshot.bindings
            if let hint = snapshot.screen, let id = screenID(matching: hint) {
                screenID = id
            }
            gridLogger.notice("layout loaded cells=\(snapshot.tree.leafIDs.count) bindings=\(snapshot.bindings.count)")
        }
    }

    private func saveLayout() {
        let cells = Set(model.cells)
        var bindings: [SavedBinding] = []
        for cell in model.cells {
            let bound = pendingBindings.first { $0.cellID == cell }
            if let window = model.bindings[cell] ?? model.detached[cell],
               let info = windowInfo[window],
               let bundleId = info.bundleId {
                bindings.append(SavedBinding(cellID: cell, bundleId: bundleId, title: info.title))
            } else if let bound, cells.contains(bound.cellID) {
                bindings.append(bound)
            }
        }
        let current = screen(for: screenID)
        let hint = current.map {
            ScreenHint(name: $0.localizedName, width: Double($0.frame.width), height: Double($0.frame.height))
        }
        let snapshot = LayoutSnapshot(tree: model.tree, gap: gap, screen: hint, bindings: bindings)
        do {
            try store.save(snapshot)
        } catch {
            gridLogger.error("layout save failed \(error.localizedDescription, privacy: .public)")
        }
    }

    private func screenID(matching hint: ScreenHint) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let named = NSScreen.screens.filter { $0.localizedName == hint.name }
        let chosen = named.first { Double($0.frame.width) == hint.width && Double($0.frame.height) == hint.height }
            ?? named.first
        return (chosen?.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
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
        let solved = solve(model.tree, in: grid)
        actualFrames = GridFit.retainedActuals(actualFrames, old: cellFrames, new: solved)
        cellFrames = solved
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
        if !operation.pids.contains(window.pid) {
            operation.pids.insert(window.pid)
            mover.beginOperation([window.pid])
        }
        prepareWrite(window)
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
        settleEcho(result)
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
                saveLayout()
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
        prepareWrite(window)
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
        settleEcho(result)
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
        saveLayout()
        refreshDividers()
    }

    private func prepareWrite(_ window: AXWindow) {
        if let id = registry.id(for: window) {
            monitor.prepareWrite(window, bindingID: id)
        }
        echo.markPending(window)
    }

    private func settleEcho(_ result: ApplyResult) {
        switch result.status {
        case .ok, .clamped, .refused:
            echo.markCompleted(result.window, actual: result.actual ?? result.requested, at: Self.now())
        case .timeout:
            echo.markTimedOut(result.window)
        case .superseded, .invalidElement:
            echo.markSettled(result.window)
        }
    }

    private func syncObservation() {
        let windows = Set(model.bindings.values).union(model.detached.values)
        let change = registry.sync(windows)
        for entry in change.removed {
            monitor.unobserve(entry.window, bindingID: entry.id)
        }
        for entry in change.added {
            monitor.observe(entry.window, bindingID: entry.id)
        }
    }

    private func handle(_ event: AXEvent) {
        switch event.kind {
        case .moved, .resized:
            guard let window = model.bindings.values.first(where: {
                $0.pid == event.pid && CFEqual($0.element, event.element)
            }) else { return }
            guard !echo.isPending(window) else { return }
            if reads.request(window) {
                readFrame(window)
            }
        case .destroyed, .miniaturized:
            guard let id = event.bindingID, let window = registry.window(for: id) else { return }
            releaseWindow(window, reason: event.kind.rawValue)
        }
    }

    private func readFrame(_ window: AXWindow) {
        mover.readFrame(window) { [weak self] result in
            self?.frameRead(window, result)
        }
    }

    private func frameRead(_ window: AXWindow, _ result: Result<CGRect, AccessFailure>) {
        if reads.finished(window) {
            readFrame(window)
            return
        }
        guard let cell = model.cell(of: window) else { return }
        guard case .success(let current) = result else {
            logEvent("event read failed cell=\(cell.rawValue)")
            return
        }
        switch echo.classify(window, current: current, at: Self.now()) {
        case .echo:
            break
        case .recovered:
            logEvent("event recovered cell=\(cell.rawValue)")
            recover(cell, window)
        case .external:
            guard let reference = actualFrames[cell] ?? cellFrames[cell],
                  let change = ExternalChange.detect(reference: reference, current: current)
            else { return }
            model.markDetached(cell)
            actualFrames[cell] = nil
            logEvent("detached cell=\(cell.rawValue) reason=\(change.rawValue)")
            saveLayout()
            refreshDividers()
        }
    }

    private func recover(_ cell: CellID, _ window: AXWindow) {
        guard !gridRect.isEmpty, cellFrames[cell] != nil else { return }
        operationCounter += 1
        let operation = Operation(id: operationCounter, pids: [window.pid], runsFit: false, onFinished: nil)
        mover.beginOperation(operation.pids)
        submit(cell, window, operation, reason: .apply)
    }

    private func releaseWindow(_ window: AXWindow, reason: String) {
        guard let cell = model.cell(of: window) ?? model.detachedCell(of: window) else { return }
        model.unbind(cell)
        actualFrames[cell] = nil
        echo.forget(window)
        logEvent("cell empty reason=\(reason) cell=\(cell.rawValue)")
        saveLayout()
        refreshDividers()
    }

    private func applicationTerminated(_ pid: pid_t) {
        let cells = model.releaseAll { $0.pid == pid }
        let hadQueue = mover.forget(pid)
        guard !cells.isEmpty || hadQueue else { return }
        logEvent("app terminated pid=\(pid) cells=\(cells.count)")
        for cell in cells {
            actualFrames[cell] = nil
            logEvent("cell empty reason=terminated cell=\(cell.rawValue)")
        }
        for window in windowInfo.keys where window.pid == pid {
            echo.forget(window)
            windowInfo[window] = nil
        }
        windows.removeAll { $0.pid == pid }
        selected = selected.filter { $0.pid != pid }
        saveLayout()
        refreshDividers()
    }

    private func screensChanged() {
        screens = ScreenOption.current()
        if !screens.contains(where: { $0.id == screenID }) {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            let main = (NSScreen.main?.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
            screenID = main ?? screens.first?.id
            logEvent("screen moved to main id=\(screenID.map { String($0) } ?? "none")")
        }
        logEvent("screens changed count=\(screens.count)")
        apply()
    }

    private nonisolated static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
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
