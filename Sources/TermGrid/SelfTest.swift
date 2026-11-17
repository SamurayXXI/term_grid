#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import GridCore

@MainActor private let selfTestMover = WindowMover()

struct SelfTestOptions {
    var move: String?
    var burst: [String]
    var arrange: [String]
    var presetName: String
    var stop: String?
    var discover: Bool
    var heartbeat: Bool
    var restore: Bool

    var runsBody: Bool {
        move != nil || !burst.isEmpty || !arrange.isEmpty || stop != nil || discover
    }

    init?(arguments: [String]) {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
                return nil
            }
            return arguments[index + 1]
        }
        move = value("--selftest-move")
        burst = value("--selftest-burst")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        arrange = value("--selftest-arrange")?
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        presetName = value("--selftest-preset") ?? "twoColumns"
        stop = value("--selftest-stop")
        discover = arguments.contains("--selftest-discover")
        heartbeat = arguments.contains("--selftest-heartbeat")
        restore = arguments.contains("--selftest-restore")
        guard runsBody || heartbeat || restore else {
            return nil
        }
    }
}

enum SelfTestLauncher {
    static func start() {
        guard let options = SelfTestOptions(arguments: CommandLine.arguments) else {
            return
        }
        if options.heartbeat {
            Thread.detachNewThread {
                beat()
            }
        }
        if options.restore {
            Thread.detachNewThread {
                SelfTestRun(options: options).runRestore()
            }
        }
        guard options.runsBody else {
            return
        }
        Thread.detachNewThread {
            SelfTestRun(options: options).run()
        }
    }

    private static func beat() {
        while true {
            let scheduled = DispatchTime.now()
            DispatchQueue.main.async {
                let delay = (DispatchTime.now().uptimeNanoseconds - scheduled.uptimeNanoseconds) / 1_000_000
                if delay > 100 {
                    logApply("main stall ms=\(delay)")
                }
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
    }
}

final class SelfTestRun: @unchecked Sendable {
    private struct BoundWindow {
        let cell: Int
        let window: DiscoveredWindow
        let frame: CGRect
    }

    static let arranged = DispatchSemaphore(value: 0)
    static let stopped = DispatchSemaphore(value: 0)
    private static let testMarker = "TGTEST"
    private static let burstCount = 200

    private let options: SelfTestOptions
    private let lock = NSLock()
    private var stoppedPid: pid_t?
    private var continued = false

    init(options: SelfTestOptions) {
        self.options = options
    }

    func run() {
        let modes = [options.move != nil, !options.burst.isEmpty, !options.arrange.isEmpty].filter { $0 }.count
        if modes > 1 {
            logApply("selftest move, burst and arrange are exclusive")
            finish(1)
        }
        ProbeLauncher.awaitTrust(timeout: 90)
        guard AXIsProcessTrusted() else {
            logApply("selftest accessibility not trusted")
            finish(2)
        }
        let snapshot = WindowDiscovery.snapshot()
        let bound = bind(snapshot)
        if !options.arrange.isEmpty {
            runArrange(bound)
            return
        }
        let stoppedAt = options.stop.map { suspend($0) }
        if options.discover {
            discover()
        }
        if options.move != nil, let target = bound.first {
            runMove(target)
        } else if !bound.isEmpty {
            runBurst(bound)
        }
        drain(Set(bound.map { $0.window.pid }))
        if let stoppedAt {
            hold(from: stoppedAt)
        }
        logApply("selftest done")
        finish(0)
    }

    func runRestore() {
        ProbeLauncher.awaitTrust(timeout: 90)
        guard AXIsProcessTrusted() else {
            logApply("selftest accessibility not trusted")
            finish(2)
        }
        awaitMain(timeout: 30) { controller, done in
            controller.restoreWindows(accepting: { $0.title.hasPrefix(Self.testMarker) }, onFinished: done)
        }
        logApply("selftest restored")
    }

    private func bind(_ snapshot: [DiscoveredWindow]) -> [BoundWindow] {
        let entries = options.move.map { [$0] } ?? (options.arrange.isEmpty ? options.burst : options.arrange)
        var occurrences: [String: Int] = [:]
        var bound: [BoundWindow] = []
        for (cell, entry) in entries.enumerated() {
            let occurrence = occurrences[entry, default: 0]
            occurrences[entry] = occurrence + 1
            let candidates = snapshot.filter { Self.matches($0, target: entry) }
            guard occurrence < candidates.count else {
                logApply("no windows target=\(entry) index=\(occurrence)")
                finish(0)
            }
            let candidate = candidates[occurrence]
            guard candidate.title.hasPrefix(Self.testMarker) else {
                logApply("selftest skip non-test window pid=\(candidate.pid) cell=\(cell)")
                continue
            }
            guard let frame = candidate.frame else {
                logApply("selftest frame unavailable pid=\(candidate.pid) cell=\(cell)")
                continue
            }
            bound.append(BoundWindow(cell: cell, window: candidate, frame: frame))
        }
        if !entries.isEmpty, bound.isEmpty {
            logApply("selftest no test windows")
            finish(0)
        }
        return bound
    }

    private func runArrange(_ bound: [BoundWindow]) {
        guard let preset = Self.preset(named: options.presetName) else {
            logApply("selftest unknown preset name=\(options.presetName)")
            finish(1)
        }
        awaitMain(timeout: 30) { controller, done in
            controller.setPreset(preset)
            let cells = controller.model.cells
            let assignments = bound.compactMap { target -> (DiscoveredWindow, CellID)? in
                target.cell < cells.count ? (target.window, cells[target.cell]) : nil
            }
            controller.assignAll(assignments, onFinished: done)
        }
        logApply("selftest arranged windows=\(bound.count) preset=\(options.presetName)")
        Self.arranged.signal()
        guard let stop = options.stop else {
            return
        }
        let stoppedAt = suspend(stop)
        if options.discover {
            discover()
        }
        if let pid = lock.withLock({ stoppedPid }) {
            logApply("selftest body=stoppedReapply")
            awaitMain(timeout: 10) { controller, done in
                controller.reapply(pids: [pid], onFinished: done)
            }
        }
        hold(from: stoppedAt)
        Thread.sleep(forTimeInterval: 1)
        awaitMain(timeout: 30) { controller, done in
            controller.reapply(onFinished: done)
        }
        logApply("selftest done")
        finish(0)
    }

    private func awaitMain(
        timeout: TimeInterval,
        _ body: @escaping @MainActor (GridController, @escaping () -> Void) -> Void
    ) {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                body(GridController.shared) {
                    done.signal()
                }
            }
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            logApply("selftest incomplete")
            if timeout >= 30 {
                finish(1)
            }
        }
    }

    private static func preset(named name: String) -> LayoutPreset? {
        switch name {
        case "twoColumns": .twoColumns
        case "threeColumns": .threeColumns
        case "twoRows": .twoRows
        case "grid2x2": .grid2x2
        case "onePlusTwo": .onePlusTwo
        case "grid2x3": .grid2x3
        default: nil
        }
    }

    private func suspend(_ target: String) -> DispatchTime {
        guard let pid = Self.resolvePid(target) else {
            logApply("no windows target=\(target)")
            finish(0)
        }
        guard Self.ownsOnlyTestWindows(pid) else {
            logApply("selftest skip non-test window pid=\(pid)")
            finish(0)
        }
        let stoppedAt = DispatchTime.now()
        guard kill(pid, SIGSTOP) == 0 else {
            logApply("selftest stop failed errno=\(errno)")
            finish(1)
        }
        logApply("selftest stopped pid=\(pid)")
        lock.withLock {
            stoppedPid = pid
        }
        Self.stopped.signal()
        DispatchQueue.global().asyncAfter(deadline: stoppedAt + 10) {
            self.resume()
        }
        if options.discover {
            DispatchQueue.global().asyncAfter(deadline: stoppedAt + 6) {
                self.resume()
            }
        }
        return stoppedAt
    }

    private func hold(from stoppedAt: DispatchTime) {
        let resumeAt = stoppedAt + (options.discover ? 6 : 5)
        let now = DispatchTime.now()
        if now < resumeAt {
            Thread.sleep(forTimeInterval: Double(resumeAt.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000)
        }
        resume()
    }

    private func resume() {
        lock.lock()
        defer { lock.unlock() }
        guard let pid = stoppedPid, !continued else {
            return
        }
        continued = true
        kill(pid, SIGCONT)
        logApply("selftest continued pid=\(pid)")
    }

    private func finish(_ code: Int32) -> Never {
        resume()
        exit(code)
    }

    private func discover() {
        let found = WindowDiscovery.snapshot()
        DispatchQueue.main.sync {
            logApply("windows discovered count=\(found.count)")
        }
    }

    private func runMove(_ target: BoundWindow) {
        let frame = DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                Self.leftHalf(of: target.frame)
            }
        }
        guard let frame else {
            logApply("selftest no screen")
            finish(1)
        }
        let pids: Set<pid_t> = [target.window.pid]
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                selfTestMover.beginOperation(pids)
                selfTestMover.request(
                    target.window.window,
                    frame: frame,
                    generation: 1,
                    final: true,
                    reason: .apply,
                    cell: CellID(target.cell)
                ) { _ in
                    selfTestMover.endOperation(pids)
                    done.signal()
                }
            }
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            logApply("selftest incomplete")
            finish(1)
        }
    }

    private func runBurst(_ targets: [BoundWindow]) {
        let pids = Set(targets.map { $0.window.pid })
        let group = DispatchGroup()
        for _ in 0..<(Self.burstCount * targets.count) {
            group.enter()
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                selfTestMover.beginOperation(pids)
            }
        }
        let start = DispatchTime.now() + 0.05
        for step in 0..<Self.burstCount {
            let last = step == Self.burstCount - 1
            DispatchQueue.main.asyncAfter(deadline: start + Double(step) / Double(Self.burstCount)) {
                MainActor.assumeIsolated {
                    for target in targets {
                        selfTestMover.request(
                            target.window.window,
                            frame: Self.burstFrame(target.frame, step: step),
                            generation: step + 1,
                            final: last,
                            reason: last ? .apply : .live,
                            cell: CellID(target.cell)
                        ) { _ in
                            group.leave()
                        }
                    }
                }
            }
        }
        guard group.wait(timeout: .now() + 30) == .success else {
            logApply("selftest incomplete")
            finish(1)
        }
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                selfTestMover.endOperation(pids)
            }
        }
        logApply("selftest burst done windows=\(targets.count) requests=\(Self.burstCount)")
    }

    private func drain(_ pids: Set<pid_t>) {
        guard !pids.isEmpty else {
            return
        }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                selfTestMover.whenDrained(pids) {
                    done.signal()
                }
            }
        }
        if done.wait(timeout: .now() + 2) == .timedOut {
            logApply("selftest drain timeout")
        }
    }

    private static func matches(_ window: DiscoveredWindow, target: String) -> Bool {
        if target.hasPrefix("pid:") {
            return target == "pid:\(window.pid)"
        }
        return window.bundleId == target
    }

    private static func ownsOnlyTestWindows(_ pid: pid_t) -> Bool {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, AXWindow.messagingTimeout)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement],
              !elements.isEmpty
        else {
            return false
        }
        for element in elements {
            AXUIElementSetMessagingTimeout(element, AXWindow.messagingTimeout)
            var title: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String,
                  text.hasPrefix(testMarker)
            else {
                return false
            }
        }
        guard let infos = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let layerZero = infos.filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        return layerZero.count == elements.count
    }

    private static func resolvePid(_ target: String) -> pid_t? {
        let pid = target.hasPrefix("pid:")
            ? pid_t(target.dropFirst(4))
            : NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == target && $0.activationPolicy == .regular }?
                .processIdentifier
        guard let pid, pid > 0, pid != getpid() else {
            return nil
        }
        return pid
    }

    private static func burstFrame(_ base: CGRect, step: Int) -> CGRect {
        CGRect(x: base.minX, y: base.minY, width: base.width - 150 + CGFloat(step / 2), height: base.height)
    }

    @MainActor
    private static func leftHalf(of axFrame: CGRect) -> CGRect? {
        guard let primary = NSScreen.screens.first else {
            return nil
        }
        let primaryHeight = primary.frame.height
        let appKitFrame = ScreenSpace.fromAX(axFrame, primaryHeight: primaryHeight)
        let center = CGPoint(x: appKitFrame.midX, y: appKitFrame.midY)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? primary
        let visible = screen.visibleFrame
        let half = CGRect(x: visible.minX, y: visible.minY, width: (visible.width / 2).rounded(.down), height: visible.height)
        return ScreenSpace.toAX(half, primaryHeight: primaryHeight)
    }
}
#endif
