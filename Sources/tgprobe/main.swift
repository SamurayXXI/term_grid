import AppKit
import ApplicationServices
import Foundation
import ProbeKit

setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

func emit(_ object: Any, pretty: Bool = true) {
    var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
    if pretty {
        options.insert(.prettyPrinted)
    }
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: options),
          let text = String(data: data, encoding: .utf8)
    else {
        fail(4, "json encode failed")
    }
    print(text)
}

var arguments = Array(CommandLine.arguments.dropFirst())

func takeOption(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func requireNumbers(_ values: [String], count: Int) -> [Double] {
    let numbers = values.compactMap { Double($0) }
    guard numbers.count == count, values.count == count else {
        fail(1, "expected \(count) numeric arguments")
    }
    return numbers
}

func printRecord(_ record: [String: Any]) {
    let type = record["type"] as? String
    var body = record
    body["type"] = nil
    switch type {
    case "list":
        emit(record["windows"] ?? [])
    case "focused":
        print(record["bundle"] as? String ?? "")
    case "close":
        break
    case "sample", "mouseUp", "summary":
        emit(record, pretty: false)
    default:
        emit(body)
    }
}

func runProbe(_ body: (ProbeSink) throws -> Void) {
    do {
        try body(printRecord)
    } catch let error as ProbeError {
        fail(error.code, error.message)
    } catch {
        fail(4, "\(error)")
    }
}

func runList() {
    let bundle = takeOption("--bundle")
    runProbe { Probe.list(bundle: bundle, emit: $0) }
}

func runSetFrame() {
    guard let bundle = takeOption("--bundle"), let indexText = takeOption("--index"), let index = Int(indexText) else {
        fail(1, "usage: tgprobe set-frame --bundle <id> --index <n> x y w h")
    }
    let numbers = requireNumbers(arguments, count: 4)
    runProbe { try Probe.setFrame(bundle: bundle, index: index, frame: numbers, emit: $0) }
}

func runBench() {
    guard let bundle = takeOption("--bundle") else {
        fail(1, "usage: tgprobe bench --bundle <id> --count <n> [--windows <k>]")
    }
    let count = takeOption("--count").flatMap { Int($0) } ?? 60
    let windowCount = takeOption("--windows").flatMap { Int($0) }
    runProbe { try Probe.bench(bundle: bundle, count: count, windows: windowCount, emit: $0) }
}

func runDrag() {
    let steps = takeOption("--steps").flatMap { Int($0) } ?? 20
    let durationMs = takeOption("--duration-ms").flatMap { Double($0) } ?? 1000
    let sampleBundle = takeOption("--sample")
    let numbers = requireNumbers(arguments, count: 4)
    runProbe {
        try Probe.drag(
            from: CGPoint(x: numbers[0], y: numbers[1]),
            to: CGPoint(x: numbers[2], y: numbers[3]),
            steps: steps,
            durationMs: durationMs,
            sample: sampleBundle,
            emit: $0
        )
    }
}

func runCursorAt() {
    let numbers = requireNumbers(arguments, count: 2)
    runProbe { Probe.cursorAt(x: numbers[0], y: numbers[1], emit: $0) }
}

func runFocused() {
    runProbe { try Probe.focused(emit: $0) }
}

func runClose() {
    guard let bundle = takeOption("--bundle"), let indexText = takeOption("--index"), let index = Int(indexText) else {
        fail(1, "usage: tgprobe close --bundle <id> --index <n>")
    }
    runProbe { try Probe.close(bundle: bundle, index: index, emit: $0) }
}

func runFixedWindow() -> Never {
    let title = takeOption("--title") ?? "tgprobe fixed"
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let window = NSWindow(
        contentRect: NSRect(x: 200, y: 200, width: 400, height: 300),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: false
    )
    window.title = title
    window.isReleasedWhenClosed = false
    window.makeKeyAndOrderFront(nil)
    app.activate(ignoringOtherApps: true)
    app.run()
    exit(0)
}

func runTestWindows() -> Never {
    let title = takeOption("--title") ?? "TGTEST"
    let count = takeOption("--count").flatMap { Int($0) } ?? 5
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    for number in 1...max(count, 1) {
        let window = NSWindow(
            contentRect: NSRect(x: 200 + number * 30, y: 200 + number * 30, width: 570, height: 462),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(title) \(number)"
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
    }
    print("{\"pid\":\(ProcessInfo.processInfo.processIdentifier),\"count\":\(count)}")
    fflush(stdout)
    app.run()
    exit(0)
}

func runWindowsOnScreen() {
    let owner = takeOption("--owner")
    let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    var rows: [[String: Any]] = []
    for (order, info) in raw.enumerated() {
        let ownerName = info[kCGWindowOwnerName as String] as? String ?? ""
        if let owner = owner, !ownerName.localizedCaseInsensitiveContains(owner) {
            continue
        }
        rows.append([
            "order": order,
            "ownerPid": info[kCGWindowOwnerPID as String] as? Int ?? 0,
            "ownerName": ownerName,
            "layer": info[kCGWindowLayer as String] as? Int ?? 0,
            "number": info[kCGWindowNumber as String] as? Int ?? 0,
            "name": info[kCGWindowName as String] as? String ?? "",
            "bounds": info[kCGWindowBounds as String] as? [String: Any] ?? [:],
        ])
    }
    emit(rows)
}

func runSpaceSwitch() {
    let direction = arguments.first ?? "right"
    let keyCode: CGKeyCode = direction == "left" ? 123 : 124
    for keyDown in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
        event?.flags = .maskControl
        event?.post(tap: .cghidEventTap)
        usleep(50_000)
    }
}

func printUsage() {
    print("usage: tgprobe <command> [options]")
    print("commands: list, set-frame, bench, drag, cursor-at, focused, close, fixed-window, test-windows, windows-on-screen, space-switch")
}

guard let command = arguments.first else {
    printUsage()
    exit(1)
}
arguments.removeFirst()

if command == "fixed-window" {
    runFixedWindow()
}

if command == "test-windows" {
    runTestWindows()
}

switch command {
case "list", "set-frame", "bench", "drag", "cursor-at", "focused", "close", "windows-on-screen", "space-switch":
    do {
        try Probe.requireTrust()
    } catch let error as ProbeError {
        fail(error.code, error.message)
    } catch {
        fail(4, "\(error)")
    }
    Probe.prepare()
default:
    printUsage()
    exit(1)
}

switch command {
case "list":
    runList()
case "set-frame":
    runSetFrame()
case "bench":
    runBench()
case "drag":
    runDrag()
case "cursor-at":
    runCursorAt()
case "focused":
    runFocused()
case "close":
    runClose()
case "windows-on-screen":
    runWindowsOnScreen()
default:
    runSpaceSwitch()
}
