import SwiftUI
import AppKit

struct MenuBarActions: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.connection.state.title)
        if let id = model.connection.activeProfile,
           let profile = model.profiles.first(where: { $0.id == id }) {
            Text(shortName(profile.name))
        }
        if model.connection.locked || model.switcher.isSwitching {
            Button(model.connection.state == .connected ? "Отключить" : "Отменить") { model.disconnect() }
                .disabled(model.connection.state == .disconnecting && !model.switcher.isSwitching)
        }
        Divider()
        Menu("Подключения") {
            ForEach(model.profiles) { profile in
                Button(shortName(profile.name)) { model.connectProfile(profile.id) }
                    .disabled(!model.canConnectProfile || model.connection.activeProfile == profile.id)
            }
        }.disabled(model.profiles.isEmpty)
        Button("Открыть TunnelDeck") {
            NSApp.activate(ignoringOtherApps: true)
            if let main = NSApp.windows.first(where: { $0.title == "TunnelDeck" && $0.canBecomeMain }) {
                main.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "connections")
            }
        }
        Button("Добавить подключение…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "add-connection")
        }.disabled(!model.canManageProfiles)
        Button("Маршрутизация…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "routing")
        }
        Divider()
        Button("Завершить TunnelDeck") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func shortName(_ name: String) -> String {
        name.count > 30 ? String(name.prefix(29)) + "…" : name
    }
}

struct ConnectionCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Добавить подключение…") { openWindow(id: "add-connection") }
                .keyboardShortcut("n").disabled(!model.canManageProfiles)
            Button("Настройки подключения…") { openWindow(id: "profile-editor") }
                .keyboardShortcut("i").disabled(!model.canManageProfiles || !model.hasSelectedProfile)
        }
        CommandGroup(after: .toolbar) {
            Button("Маршрутизация…") { openWindow(id: "routing") }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Диагностика") { openWindow(id: "diagnostics") }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
