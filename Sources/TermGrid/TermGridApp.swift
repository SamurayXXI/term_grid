import SwiftUI
import AppKit
import ApplicationServices
import os
import ProbeKit
import GridCore

#if DEBUG
private let probeLogger = Logger(subsystem: "local.termgrid", category: "ui")

enum ProbeLauncher {
    static func start() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--probe"), flag + 1 < arguments.count else {
            return
        }
        let requestPath = arguments[flag + 1]
        guard let outFlag = arguments.firstIndex(of: "--probe-out"), outFlag + 1 < arguments.count else {
            probeLogger.error("probe: --probe-out is required")
            exit(1)
        }
        let outPath = arguments[outFlag + 1]
        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outPath) else {
            probeLogger.error("probe: cannot open \(outPath)")
            exit(1)
        }
        let write: ProbeSink = { record in
            guard let data = try? JSONSerialization.data(
                withJSONObject: record,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ) else {
                return
            }
            handle.write(data + Data("\n".utf8))
        }
        let selfTestHoldsProcess = SelfTestOptions(arguments: arguments)?.stop != nil
        Thread.detachNewThread {
            let code = run(requestPath: requestPath, write: write)
            try? handle.close()
            if selfTestHoldsProcess {
                probeLogger.notice("probe finished code=\(code), selftest exits the process")
                return
            }
            exit(code)
        }
    }

    static func awaitTrust(timeout: TimeInterval) {
        guard ProcessInfo.processInfo.environment["TGPROBE_FORCE_UNTRUSTED"] != "1", !AXIsProcessTrusted() else {
            return
        }
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([promptKey: true] as CFDictionary)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !AXIsProcessTrusted() {
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    private static func run(requestPath: String, write: ProbeSink) -> Int32 {
        awaitTrust(timeout: 90)
        do {
            try Probe.requireTrust()
        } catch let error as ProbeError {
            probeLogger.error("probe: \(error.message)")
            write(["type": "error", "message": error.message, "code": Int(error.code)])
            return error.code
        } catch {
            return 1
        }
        Probe.prepare()
        let requests: [[String: Any]]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: requestPath))
            guard let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                write(["type": "error", "message": "request must be a JSON array of objects", "code": 1])
                return 1
            }
            requests = parsed
        } catch {
            write(["type": "error", "message": "cannot read request: \(error.localizedDescription)", "code": 1])
            return 1
        }
        if SelfTestOptions(arguments: CommandLine.arguments)?.arrange.isEmpty == false {
            guard SelfTestRun.arranged.wait(timeout: .now() + 150) == .success else {
                write(["type": "error", "message": "grid not arranged", "code": 4])
                return 4
            }
        }
        for request in requests {
            do {
                let command = request["cmd"] as? String
                if command == "dividers" {
                    write(["type": "dividers", "dividers": shownDividers().map(describe)])
                } else if command == "await-stopped" {
                    let timeout = (request["timeout_ms"] as? NSNumber)?.doubleValue ?? 30_000
                    guard SelfTestRun.stopped.wait(timeout: .now() + timeout / 1000) == .success else {
                        throw ProbeError(4, "selftest did not stop a process")
                    }
                    write(["type": "await-stopped"])
                } else if command == "shift" {
                    try Probe.execute(try resolveShift(request), emit: write)
                } else if command == "drag", request["divider"] != nil {
                    try Probe.execute(try resolveDividerDrag(request, emit: write), emit: write)
                } else if Probe.runsOnMainThread(command) {
                    try DispatchQueue.main.sync { try Probe.execute(request, emit: write) }
                } else {
                    try Probe.execute(request, emit: write)
                }
            } catch let error as ProbeError {
                write(["type": "error", "message": error.message, "code": Int(error.code)])
                return error.code
            } catch {
                write(["type": "error", "message": "\(error)", "code": 4])
                return 4
            }
        }
        return 0
    }

    private static func shownDividers() -> [GridCore.Divider] {
        DispatchQueue.main.sync {
            MainActor.assumeIsolated {
                GridController.shared.shownDividers
            }
        }
    }

    private static func describe(_ divider: GridCore.Divider) -> [String: Any] {
        [
            "id": "\(divider.id.container.rawValue).\(divider.id.index)",
            "axis": divider.axis.rawValue,
            "x": Double(divider.rect.minX),
            "y": Double(divider.rect.minY),
            "w": Double(divider.rect.width),
            "h": Double(divider.rect.height),
        ]
    }

    private static func resolveShift(_ request: [String: Any]) throws -> [String: Any] {
        guard let bundle = request["bundle"] as? String else {
            throw ProbeError(1, "usage: shift needs bundle, index and any of dx, dy, dw, dh")
        }
        let index = (request["index"] as? NSNumber)?.intValue ?? 0
        var windows: [[String: Any]] = []
        Probe.list(bundle: bundle) { record in
            windows = record["windows"] as? [[String: Any]] ?? []
        }
        let marked = windows.filter { ($0["title"] as? String)?.hasPrefix("TGTEST") == true }
        guard marked.indices.contains(index),
              let frame = marked[index]["frame"] as? [String: Any],
              let x = (frame["x"] as? NSNumber)?.doubleValue,
              let y = (frame["y"] as? NSNumber)?.doubleValue,
              let w = (frame["w"] as? NSNumber)?.doubleValue,
              let h = (frame["h"] as? NSNumber)?.doubleValue
        else {
            throw ProbeError(3, "window index out of range (writes only target windows whose title starts with TGTEST)")
        }
        func offset(_ key: String) -> Double {
            (request[key] as? NSNumber)?.doubleValue ?? 0
        }
        return [
            "cmd": "set-frame",
            "bundle": bundle,
            "index": index,
            "frame": ["x": x + offset("dx"), "y": y + offset("dy"), "w": w + offset("dw"), "h": h + offset("dh")],
        ]
    }

    private static func resolveDividerDrag(_ request: [String: Any], emit: ProbeSink) throws -> [String: Any] {
        let dividers = shownDividers()
        guard let index = (request["divider"] as? NSNumber)?.intValue, dividers.indices.contains(index) else {
            throw ProbeError(3, "divider index out of range (shown: \(dividers.count))")
        }
        let along = (request["along"] as? NSNumber)?.doubleValue ?? 0.5
        let dx = (request["dx"] as? NSNumber)?.doubleValue ?? 0
        let dy = (request["dy"] as? NSNumber)?.doubleValue ?? 0
        let start = dividers[index].point(along: CGFloat(along))
        var resolved = request
        resolved["divider"] = nil
        resolved["x1"] = Double(start.x)
        resolved["y1"] = Double(start.y)
        resolved["x2"] = Double(start.x) + dx
        resolved["y2"] = Double(start.y) + dy
        emit([
            "type": "drag-target",
            "divider": describe(dividers[index]),
            "x1": Double(start.x),
            "y1": Double(start.y),
            "x2": Double(start.x) + dx,
            "y2": Double(start.y) + dy,
        ])
        return resolved
    }
}
#endif

enum TerminationSignal {
    private static var source: DispatchSourceSignal?

    static func install() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                NSApplication.shared.terminate(nil)
            }
        }
        source.resume()
        self.source = source
    }
}

@main
struct TermGridApp: App {
    @StateObject private var permissions = Permissions()
    @StateObject private var controller = GridController.shared

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWindow.messagingTimeout)
        TerminationSignal.install()
        #if DEBUG
        ProbeLauncher.start()
        SelfTestLauncher.start()
        #endif
    }

    var body: some Scene {
        MenuBarExtra("TermGrid", systemImage: "square.grid.2x2") {
            MenuContent(permissions: permissions, controller: controller)
        }
        .menuBarExtraStyle(.window)
    }
}
