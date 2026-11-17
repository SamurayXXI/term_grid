import AppKit
import GridCore
import SwiftUI

private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if window !== view.window {
                window = view.window
            }
        }
    }
}

struct MenuContent: View {
    @ObservedObject var permissions: Permissions
    @ObservedObject var controller: GridController
    @State private var hostWindow: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if permissions.isTrusted {
                gridSection
                Divider()
                windowsSection
            } else {
                onboarding
            }
            Divider()
            Button("Выход") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(WindowReader(window: $hostWindow))
        .onAppear {
            if permissions.isTrusted {
                controller.refreshWindows()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            guard permissions.isTrusted,
                  let hostWindow,
                  (notification.object as? NSWindow) === hostWindow
            else {
                return
            }
            controller.refreshWindows()
        }
        .onChange(of: permissions.isTrusted) { _, trusted in
            if trusted {
                controller.refreshWindows()
            }
        }
    }

    private var onboarding: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Нужен доступ к универсальному доступу")
                .font(.headline)
            Text("TermGrid двигает окна других приложений. Разрешите доступ в Системных настройках: Конфиденциальность и безопасность, Универсальный доступ.")
                .fixedSize(horizontal: false, vertical: true)
            Button("Открыть настройки") {
                permissions.openSettings()
            }
        }
    }

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Сетка")
                .font(.headline)
            Picker("Пресет", selection: presetBinding) {
                ForEach(controller.presets, id: \.self) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Picker("Экран", selection: screenBinding) {
                ForEach(controller.screens) { screen in
                    Text(screen.name).tag(Optional(screen.id))
                }
            }
            Picker("Зазор", selection: gapBinding) {
                ForEach(GridController.gapChoices, id: \.self) { gap in
                    Text("\(gap) pt").tag(gap)
                }
            }
            HStack {
                Button("Разложить автоматически") {
                    controller.autoArrange()
                }
                Button("Сбросить") {
                    controller.reset()
                }
            }
        }
    }

    private var windowsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Окна")
                .font(.headline)
            if controller.windows.isEmpty {
                Text("Нет окон")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(controller.windows.enumerated()), id: \.offset) { _, window in
                    HStack(spacing: 6) {
                        Image(nsImage: icon(for: window))
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(window.displayTitle)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var presetBinding: Binding<LayoutPreset> {
        Binding(get: { controller.preset }, set: { controller.setPreset($0) })
    }

    private var screenBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { controller.screenID },
            set: { id in
                if let id {
                    controller.setScreen(id)
                }
            }
        )
    }

    private var gapBinding: Binding<Int> {
        Binding(get: { controller.gap }, set: { controller.setGap($0) })
    }

    private func icon(for window: DiscoveredWindow) -> NSImage {
        NSRunningApplication(processIdentifier: window.pid)?.icon ?? NSImage()
    }
}
