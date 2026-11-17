import SwiftUI
import AppKit
import ApplicationServices
import os
import ProbeKit

private let spikeLogger = Logger(subsystem: "local.termgrid", category: "ui")

final class SpikePanelView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        spikeLogger.notice("spike panel mouseEntered")
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.arrow.set()
        spikeLogger.notice("spike panel mouseExited")
    }

    override func mouseDown(with event: NSEvent) {
        spikeLogger.notice("spike panel mouseDown")
    }

    override func mouseDragged(with event: NSEvent) {
        spikeLogger.notice("spike panel mouseDragged dx=\(event.deltaX) dy=\(event.deltaY)")
    }

    override func mouseUp(with event: NSEvent) {
        spikeLogger.notice("spike panel mouseUp")
    }
}

final class SpikePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

enum SpikeLauncher {
    static var panel: NSPanel?

    static func start() {
        spikeLogger.notice("AXIsProcessTrusted=\(AXIsProcessTrusted())")
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--spike-panel") else {
            return
        }
        let numbers = arguments.dropFirst(flag + 1).prefix(4).compactMap { Double($0) }
        let frame = numbers.count == 4
            ? NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
            : NSRect(x: 300, y: 300, width: 8, height: 400)
        let level: NSWindow.Level = arguments.contains("--spike-floating") ? .floating : .normal
        DispatchQueue.main.async {
            let panel = SpikePanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = NSColor(white: 0, alpha: 0.01)
            panel.level = level
            panel.collectionBehavior = [.ignoresCycle, .fullScreenNone]
            panel.hidesOnDeactivate = false
            panel.contentView = SpikePanelView(frame: NSRect(origin: .zero, size: frame.size))
            panel.orderFrontRegardless()
            spikeLogger.notice("spike panel shown frame=\(NSStringFromRect(frame)) pid=\(ProcessInfo.processInfo.processIdentifier)")
            SpikeLauncher.panel = panel
        }
    }
}

#if DEBUG
enum ProbeLauncher {
    static func start() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--probe"), flag + 1 < arguments.count else {
            return
        }
        let requestPath = arguments[flag + 1]
        guard let outFlag = arguments.firstIndex(of: "--probe-out"), outFlag + 1 < arguments.count else {
            spikeLogger.error("probe: --probe-out is required")
            exit(1)
        }
        let outPath = arguments[outFlag + 1]
        FileManager.default.createFile(atPath: outPath, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: outPath) else {
            spikeLogger.error("probe: cannot open \(outPath)")
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

    private static func awaitTrust(timeout: TimeInterval) {
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
            spikeLogger.error("probe: \(error.message)")
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
        for request in requests {
            do {
                if Probe.runsOnMainThread(request["cmd"] as? String) {
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
}
#endif

@main
struct TermGridApp: App {
    init() {
        SpikeLauncher.start()
        #if DEBUG
        ProbeLauncher.start()
        #endif
    }

    var body: some Scene {
        MenuBarExtra("TermGrid", systemImage: "square.grid.2x2") {
            Button("Выход") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
