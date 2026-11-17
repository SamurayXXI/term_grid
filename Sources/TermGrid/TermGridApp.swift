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
        Thread.detachNewThread {
            let code = run(requestPath: requestPath, write: write)
            try? handle.close()
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

@main
struct TermGridApp: App {
    @StateObject private var permissions = Permissions()
    @StateObject private var controller = GridController.shared

    init() {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWindow.messagingTimeout)
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
