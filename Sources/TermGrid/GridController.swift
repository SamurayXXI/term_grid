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

@MainActor
final class GridController: ObservableObject {
    static let gapChoices: [Int] = [0, 4, 8, 12, 16]

    let presets = LayoutPreset.allCases

    @Published private(set) var screens: [ScreenOption] = ScreenOption.current()
    @Published private(set) var windows: [DiscoveredWindow] = []
    @Published var preset: LayoutPreset = .twoColumns
    @Published var screenID: CGDirectDisplayID? = ScreenOption.current().first?.id
    @Published var gap: Int = 8
    private var refreshGeneration = 0

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
                }
            }
        }
    }

    func setPreset(_ preset: LayoutPreset) {
        self.preset = preset
        gridLogger.notice("command setPreset \(preset.title, privacy: .public)")
    }

    func setScreen(_ id: CGDirectDisplayID) {
        screenID = id
        gridLogger.notice("command setScreen \(id)")
    }

    func setGap(_ gap: Int) {
        self.gap = gap
        gridLogger.notice("command setGap \(gap)")
    }

    func autoArrange() {
        gridLogger.notice("command autoArrange")
    }

    func reset() {
        gridLogger.notice("command reset")
    }
}
