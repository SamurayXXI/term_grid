#if DEBUG
import AppKit
import ApplicationServices
import Foundation
import GridCore

@MainActor private let selfTestMover = WindowMover()

struct SelfTestOptions {
    var move: String?
    var burst: [String]
    var stop: String?
    var discover: Bool

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
        stop = value("--selftest-stop")
        discover = arguments.contains("--selftest-discover")
        guard move != nil || !burst.isEmpty || stop != nil || discover else {
            return nil
        }
    }
}

enum SelfTestLauncher {
    static func start() {
        guard let options = SelfTestOptions(arguments: CommandLine.arguments) else {
            return
        }
        Thread.detachNewThread {
            SelfTestRun(options: options).run()
        }
    }
}

final class SelfTestRun: @unchecked Sendable {
    private struct BoundWindow {
        let cell: Int
        let window: DiscoveredWindow
        let frame: CGRect
    }

    private static let testMarker = "TGTEST"
    private static let burstCount = 200

    private let options: SelfTestOptions
    private let lock = NSLock()
    private var stoppedPid: pid_t?
    private var continued = false

    init(options: SelfTestOptions) {
        self.options = options
    }

    func run() -> Never {
        if options.move != nil, !options.burst.isEmpty {
            logApply("selftest move and burst are exclusive")
            finish(1)
        }
        ProbeLauncher.awaitTrust(timeout: 90)
        guard AXIsProcessTrusted() else {
            logApply("selftest accessibility not trusted")
            finish(2)
        }
        let snapshot = WindowDiscovery.snapshot()
        let bound = bind(snapshot)
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

    private func bind(_ snapshot: [DiscoveredWindow]) -> [BoundWindow] {
        let entries = options.move.map { [$0] } ?? options.burst
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
        if target.hasPrefix("pid:") {
            return pid_t(target.dropFirst(4))
        }
        return NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == target && $0.activationPolicy == .regular }?
            .processIdentifier
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
