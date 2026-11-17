import AppKit
import ApplicationServices
import Foundation

public struct ProbeError: Error {
    public let code: Int32
    public let message: String

    public init(_ code: Int32, _ message: String) {
        self.code = code
        self.message = message
    }
}

public typealias ProbeSink = ([String: Any]) -> Void

public enum Probe {
    public static func requireTrust() throws {
        let forced = ProcessInfo.processInfo.environment["TGPROBE_FORCE_UNTRUSTED"] == "1"
        if forced || !AXIsProcessTrusted() {
            throw ProbeError(2, "accessibility not trusted")
        }
    }

    public static func prepare() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
    }

    public static func list(bundle: String?, emit: ProbeSink) {
        emit(["type": "list", "windows": appWindows(bundle: bundle).map { describe($0, full: true) }])
    }

    public static func setFrame(bundle: String, index: Int, frame: [Double], emit: ProbeSink) throws {
        guard frame.count == 4 else {
            throw ProbeError(1, "expected 4 numeric arguments")
        }
        let window = try targetWindow(bundle: bundle, index: index)
        let before = frameDictionary(window)
        writeFrame(
            window,
            origin: CGPoint(x: frame[0], y: frame[1]),
            size: CGSize(width: frame[2], height: frame[3])
        )
        let after = frameDictionary(window)
        emit([
            "type": "set-frame",
            "requested": ["x": frame[0], "y": frame[1], "w": frame[2], "h": frame[3]],
            "before": before,
            "after": after,
        ])
    }

    public static func bench(bundle: String, count: Int, windows windowCount: Int?, offset: Int = 0, emit: ProbeSink) throws {
        let windows = markedWindows(bundle: bundle).map { $0.element }
        let needed = windowCount ?? 1
        guard needed >= 1, offset >= 0, windows.count >= offset + needed else {
            throw ProbeError(3, "window index out of range (writes only target windows whose title starts with \(testMarker))")
        }
        let targets = Array(windows.dropFirst(offset).prefix(needed))
        let origins = targets.map { pointAttribute($0, kAXPositionAttribute) ?? .zero }
        let sizes = targets.map { sizeAttribute($0, kAXSizeAttribute) ?? .zero }
        defer {
            for (index, element) in targets.enumerated() {
                writeFrame(element, origin: origins[index], size: sizes[index])
            }
        }
        if windowCount != nil {
            var rounds: [Double] = []
            for iteration in 0..<count {
                let grow = iteration % 2 == 0
                let start = nowNanos()
                for (index, element) in targets.enumerated() {
                    let size = CGSize(width: sizes[index].width + (grow ? 40 : 0), height: sizes[index].height)
                    let origin = CGPoint(x: origins[index].x + (grow ? 10 : 0), y: origins[index].y)
                    setSize(element, size)
                    setPosition(element, origin)
                }
                rounds.append(millis(start, nowNanos()))
            }
            let summary = stats(rounds)
            emit([
                "type": "bench",
                "bundle": bundle,
                "windows": needed,
                "count": count,
                "round_ms": summary,
                "hz_per_window": 1000 / (summary["p95"] ?? 1),
            ])
            return
        }
        let element = targets[0]
        var sizeLatency: [Double] = []
        var pairLatency: [Double] = []
        for iteration in 0..<count {
            let grow = iteration % 2 == 0
            let widthA = sizes[0].width + (grow ? 40 : 0)
            let sizeStart = nowNanos()
            setSize(element, CGSize(width: widthA, height: sizes[0].height))
            sizeLatency.append(millis(sizeStart, nowNanos()))
            let widthB = sizes[0].width + (grow ? 0 : 40)
            let pairStart = nowNanos()
            setSize(element, CGSize(width: widthB, height: sizes[0].height))
            setPosition(element, CGPoint(x: origins[0].x + (grow ? 0 : 10), y: origins[0].y))
            pairLatency.append(millis(pairStart, nowNanos()))
        }
        emit([
            "type": "bench",
            "bundle": bundle,
            "count": count,
            "size_ms": stats(sizeLatency),
            "pair_ms": stats(pairLatency),
        ])
    }

    public static func drag(
        from start: CGPoint,
        to end: CGPoint,
        steps: Int,
        durationMs: Double,
        sample sampleBundle: String?,
        emit: ProbeSink
    ) throws {
        guard steps >= 1 else {
            throw ProbeError(1, "steps must be positive")
        }
        CGWarpMouseCursorPosition(start)
        postMouse(.mouseMoved, at: start)
        usleep(100_000)
        let origin = nowNanos()
        postMouse(.leftMouseDown, at: start)
        for step in 1...steps {
            usleep(UInt32(durationMs * 1000 / Double(steps)))
            let fraction = Double(step) / Double(steps)
            let point = CGPoint(x: start.x + (end.x - start.x) * fraction, y: start.y + (end.y - start.y) * fraction)
            postMouse(.leftMouseDragged, at: point)
            if let bundle = sampleBundle {
                emit([
                    "type": "sample",
                    "t_ms": millis(origin, nowNanos()),
                    "frames": appWindows(bundle: bundle).map { describe($0, full: false) },
                ])
            }
        }
        postMouse(.leftMouseUp, at: end)
        let upTime = millis(origin, nowNanos())
        emit(["type": "mouseUp", "t_ms": upTime])
        emit(["type": "summary", "steps": steps, "duration_ms": upTime])
    }

    public static func cursorAt(x: Double, y: Double, emit: ProbeSink) {
        _ = NSApplication.shared
        let point = CGPoint(x: x, y: y)
        CGWarpMouseCursorPosition(point)
        postMouse(.mouseMoved, at: point)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
        let first = cursorSnapshot(afterMs: 200)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.8))
        let second = cursorSnapshot(afterMs: 1000)
        emit(["type": "cursor-at", "x": x, "y": y, "samples": [first, second]])
    }

    public static func focused(emit: ProbeSink) throws {
        let systemWide = AXUIElementCreateSystemWide()
        if let raw = attribute(systemWide, kAXFocusedApplicationAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() {
            var pid: pid_t = 0
            AXUIElementGetPid(raw as! AXUIElement, &pid)
            if let bundleId = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
                emit(["type": "focused", "bundle": bundleId])
                return
            }
        }
        guard let bundleId = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            throw ProbeError(4, "no focused application")
        }
        emit(["type": "focused", "bundle": bundleId])
    }

    public static func close(bundle: String, index: Int, emit: ProbeSink) throws {
        let window = try targetWindow(bundle: bundle, index: index)
        guard let raw = attribute(window, kAXCloseButtonAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            throw ProbeError(4, "close button not found")
        }
        let result = AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString)
        guard result == .success else {
            throw ProbeError(4, "press failed: \(result.rawValue)")
        }
        emit(["type": "close", "bundle": bundle, "index": index])
    }

    public static func execute(_ request: [String: Any], emit: ProbeSink) throws {
        guard let command = request["cmd"] as? String else {
            throw ProbeError(1, "missing cmd")
        }
        let bundle = request["bundle"] as? String
        let index = intValue(request["index"])
        switch command {
        case "list":
            list(bundle: bundle, emit: emit)
        case "set-frame":
            guard let bundle = bundle, let index = index, let frame = request["frame"] as? [String: Any],
                  let x = number(frame["x"]), let y = number(frame["y"]),
                  let w = number(frame["w"]), let h = number(frame["h"])
            else {
                throw ProbeError(1, "usage: set-frame needs bundle, index, frame {x,y,w,h}")
            }
            try setFrame(bundle: bundle, index: index, frame: [x, y, w, h], emit: emit)
        case "bench":
            guard let bundle = bundle else {
                throw ProbeError(1, "usage: bench needs bundle")
            }
            try bench(
                bundle: bundle,
                count: intValue(request["count"]) ?? 60,
                windows: intValue(request["windows"]),
                offset: intValue(request["offset"]) ?? 0,
                emit: emit
            )
        case "drag":
            guard let x1 = number(request["x1"]), let y1 = number(request["y1"]),
                  let x2 = number(request["x2"]), let y2 = number(request["y2"])
            else {
                throw ProbeError(1, "usage: drag needs x1, y1, x2, y2")
            }
            try drag(
                from: CGPoint(x: x1, y: y1),
                to: CGPoint(x: x2, y: y2),
                steps: intValue(request["steps"]) ?? 20,
                durationMs: number(request["duration_ms"]) ?? 1000,
                sample: request["sample"] as? String,
                emit: emit
            )
        case "cursor-at":
            guard let x = number(request["x"]), let y = number(request["y"]) else {
                throw ProbeError(1, "usage: cursor-at needs x, y")
            }
            cursorAt(x: x, y: y, emit: emit)
        case "focused":
            try focused(emit: emit)
        case "sleep":
            usleep(UInt32(min(max(number(request["ms"]) ?? 1000, 0), 60_000) * 1000))
            emit(["type": "sleep", "ms": number(request["ms"]) ?? 1000])
        case "close":
            guard let bundle = bundle, let index = index else {
                throw ProbeError(1, "usage: close needs bundle, index")
            }
            try close(bundle: bundle, index: index, emit: emit)
        default:
            throw ProbeError(1, "unknown cmd: \(command)")
        }
    }

    public static func runsOnMainThread(_ command: String?) -> Bool {
        command == "cursor-at"
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func intValue(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }

    private static func nowNanos() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func millis(_ from: UInt64, _ to: UInt64) -> Double {
        Double(to - from) / 1_000_000
    }

    private static func stats(_ values: [Double]) -> [String: Double] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else {
            return [:]
        }
        func percentile(_ p: Double) -> Double {
            let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
            return sorted[max(0, min(sorted.count - 1, rank))]
        }
        return ["p50": percentile(0.5), "p95": percentile(0.95), "max": sorted[sorted.count - 1]]
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else {
            return nil
        }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    @discardableResult
    private static func setPosition(_ element: AXUIElement, _ point: CGPoint) -> AXError {
        var value = point
        guard let axValue = AXValueCreate(.cgPoint, &value) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axValue)
    }

    @discardableResult
    private static func setSize(_ element: AXUIElement, _ size: CGSize) -> AXError {
        var value = size
        guard let axValue = AXValueCreate(.cgSize, &value) else {
            return .failure
        }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axValue)
    }

    private static func isSettable(_ element: AXUIElement, _ name: String) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, name as CFString, &settable) == .success && settable.boolValue
    }

    private struct AppWindow {
        let pid: pid_t
        let bundleId: String
        let element: AXUIElement
    }

    private static func appWindows(bundle: String?) -> [AppWindow] {
        var result: [AppWindow] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let bundleId = app.bundleIdentifier ?? ""
            if let bundle = bundle {
                if bundle.hasPrefix("pid:") {
                    if bundle != "pid:\(app.processIdentifier)" {
                        continue
                    }
                } else if bundle != bundleId {
                    continue
                }
            }
            let axApp = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            guard let windows = attribute(axApp, kAXWindowsAttribute) as? [AXUIElement] else {
                continue
            }
            for window in windows {
                AXUIElementSetMessagingTimeout(window, 0.5)
                result.append(AppWindow(pid: app.processIdentifier, bundleId: bundleId, element: window))
            }
        }
        return result
    }

    private static func frameDictionary(_ element: AXUIElement) -> [String: Any] {
        let origin = pointAttribute(element, kAXPositionAttribute) ?? .zero
        let size = sizeAttribute(element, kAXSizeAttribute) ?? .zero
        return ["x": origin.x, "y": origin.y, "w": size.width, "h": size.height]
    }

    private static func describe(_ window: AppWindow, full: Bool) -> [String: Any] {
        var entry: [String: Any] = [
            "pid": Int(window.pid),
            "title": (attribute(window.element, kAXTitleAttribute) as? String) ?? "",
            "frame": frameDictionary(window.element),
        ]
        guard full else {
            return entry
        }
        entry["bundleId"] = window.bundleId
        entry["role"] = (attribute(window.element, kAXRoleAttribute) as? String) ?? ""
        entry["subrole"] = (attribute(window.element, kAXSubroleAttribute) as? String) ?? ""
        entry["positionSettable"] = isSettable(window.element, kAXPositionAttribute)
        entry["sizeSettable"] = isSettable(window.element, kAXSizeAttribute)
        entry["minimized"] = (attribute(window.element, kAXMinimizedAttribute) as? Bool) ?? false
        entry["fullscreen"] = (attribute(window.element, "AXFullScreen") as? Bool) ?? false
        return entry
    }

    private static let testMarker = "TGTEST"

    private static func markedWindows(bundle: String) -> [AppWindow] {
        appWindows(bundle: bundle).filter {
            (attribute($0.element, kAXTitleAttribute) as? String)?.hasPrefix(testMarker) == true
        }
    }

    private static func targetWindow(bundle: String, index: Int) throws -> AXUIElement {
        let windows = markedWindows(bundle: bundle)
        guard index >= 0, index < windows.count else {
            throw ProbeError(3, "window index out of range (writes only target windows whose title starts with \(testMarker))")
        }
        return windows[index].element
    }

    private static func writeFrame(_ element: AXUIElement, origin: CGPoint, size: CGSize) {
        setSize(element, size)
        setPosition(element, origin)
        setSize(element, size)
    }

    private static func postMouse(_ type: CGEventType, at point: CGPoint) {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged {
            event?.setIntegerValueField(.mouseEventClickState, value: 1)
        }
        event?.post(tap: .cghidEventTap)
    }

    private static func cursorSnapshot(afterMs: Int) -> [String: Any] {
        let current = NSCursor.currentSystem
        let reference = NSCursor.resizeLeftRight
        var entry: [String: Any] = ["after_ms": afterMs, "available": current != nil]
        if let current = current {
            entry["hotSpot"] = ["x": current.hotSpot.x, "y": current.hotSpot.y]
            entry["image"] = ["w": current.image.size.width, "h": current.image.size.height]
            entry["matchesResizeLeftRight"] =
                current.hotSpot == reference.hotSpot && current.image.size == reference.image.size
        }
        entry["resizeLeftRight"] = [
            "hotSpot": ["x": reference.hotSpot.x, "y": reference.hotSpot.y],
            "image": ["w": reference.image.size.width, "h": reference.image.size.height],
        ]
        return entry
    }
}
