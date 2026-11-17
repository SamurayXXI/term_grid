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
                cellsSection
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
            Toggle("Скрыть разделители", isOn: dividersHiddenBinding)
            HStack {
                Button("Разложить автоматически") {
                    controller.autoArrange(controller.selectedWindows)
                }
                .disabled(controller.selected.isEmpty)
                Button("Сбросить") {
                    controller.reset()
                }
            }
            Button("Восстановить окна") {
                controller.restoreWindows()
            }
            .disabled(controller.pendingBindings.isEmpty)
        }
    }

    private var cellsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ячейки")
                .font(.headline)
            ForEach(Array(controller.model.cells.enumerated()), id: \.element) { index, cell in
                cellRow(index: index, cell: cell)
            }
        }
    }

    private func cellRow(index: Int, cell: CellID) -> some View {
        let status = controller.model.status(of: cell)
        return HStack(spacing: 6) {
            Text("\(index + 1)")
                .monospacedDigit()
                .frame(width: 16)
            Text(controller.title(of: cell) ?? "—")
                .lineLimit(1)
            Spacer()
            Text(status.title)
                .foregroundStyle(status == .ok || status == .empty ? Color.secondary : Color.orange)
            Menu("…") {
                Button("Разделить по горизонтали") {
                    controller.split(cell, axis: .horizontal)
                }
                Button("Разделить по вертикали") {
                    controller.split(cell, axis: .vertical)
                }
                Button("Закрыть ячейку") {
                    controller.close(cell)
                }
                if status == .detached, controller.model.detached[cell] != nil {
                    Button("Вернуть в сетку") {
                        controller.reattach(cell)
                    }
                }
                if status == .notResponding || status == .doesNotFit {
                    Button("Повторить") {
                        controller.retry(cell)
                    }
                }
                if controller.model.bindings[cell] != nil {
                    Button("Убрать из ячейки") {
                        controller.release(cell)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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
                    windowRow(window)
                }
            }
        }
    }

    private func windowRow(_ window: DiscoveredWindow) -> some View {
        let cell = controller.cell(of: window)
        let detachedCell = controller.detachedCell(of: window)
        return HStack(spacing: 6) {
            Button {
                controller.toggleSelection(window)
            } label: {
                Image(systemName: controller.selected.contains(window.window) ? "checkmark.square" : "square")
            }
            .buttonStyle(.plain)
            Image(nsImage: icon(for: window))
                .resizable()
                .frame(width: 16, height: 16)
            Text(window.displayTitle)
                .lineLimit(1)
            Spacer()
            if let cell {
                Text(controller.model.status(of: cell).title)
                    .foregroundStyle(.secondary)
            } else if detachedCell != nil {
                Text(CellStatus.detached.title)
                    .foregroundStyle(Color.orange)
            }
            if !window.isSizeSettable {
                Image(systemName: "exclamationmark.triangle")
                    .help("Фиксированный размер")
            }
            Menu("В ячейку…") {
                if let detachedCell {
                    Button("Вернуть в сетку") {
                        controller.reattach(detachedCell)
                    }
                }
                ForEach(Array(controller.model.cells.enumerated()), id: \.element) { index, target in
                    Button("Ячейка \(index + 1)") {
                        controller.assign(window, to: target)
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
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

    private var dividersHiddenBinding: Binding<Bool> {
        Binding(get: { controller.dividersHidden }, set: { controller.setDividersHidden($0) })
    }

    private func icon(for window: DiscoveredWindow) -> NSImage {
        NSRunningApplication(processIdentifier: window.pid)?.icon ?? NSImage()
    }
}
