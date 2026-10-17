import TunnelLocalization
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
            Button(model.connection.state == .connected ? L10n.text("action.disconnect") : L10n.text("action.cancel_operation")) { model.disconnect() }
                .disabled(model.connection.state == .disconnecting && !model.switcher.isSwitching)
        }
        Divider()
        Menu(L10n.text("contentview.connections")) {
            ForEach(model.profiles) { profile in
                Button(shortName(profile.name)) { model.connectProfile(profile.id) }
                    .disabled(!model.canConnectProfile || model.connection.activeProfile == profile.id)
            }
        }.disabled(model.profiles.isEmpty)
        Button(L10n.text("menubaractions.open_tunneldeck")) {
            NSApp.activate(ignoringOtherApps: true)
            if let main = NSApp.windows.first(where: { $0.title == "TunnelDeck" && $0.canBecomeMain }) {
                main.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "connections")
            }
        }
        Button(L10n.text("menubaractions.add_connection")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "add-connection")
        }.disabled(!model.canManageProfiles)
        Button(L10n.text("menubaractions.routing")) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "routing")
        }
        Divider()
        Button(L10n.text("menubaractions.quit_tunneldeck")) { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    private func shortName(_ name: String) -> String {
        name.count > 30 ? String(name.prefix(29)) + "…" : name
    }
}

struct ConnectionCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.text("menu.about")) {
                NSApp.orderFrontStandardAboutPanel(nil)
            }
        }
        CommandGroup(replacing: .appSettings) {
            Button(L10n.text("menu.settings")) { openSettings() }.keyboardShortcut(",")
        }
        CommandGroup(replacing: .appVisibility) {
            Button(L10n.text("menu.hide")) { NSApp.hide(nil) }.keyboardShortcut("h")
            Button(L10n.text("menu.hide_others")) { NSApp.hideOtherApplications(nil) }
                .keyboardShortcut("h", modifiers: [.command, .option])
            Button(L10n.text("menu.show_all")) { NSApp.unhideAllApplications(nil) }
        }
        CommandGroup(replacing: .appTermination) {
            Button(L10n.text("menubaractions.quit_tunneldeck")) { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        CommandGroup(replacing: .newItem) {
            Button(L10n.text("menubaractions.add_connection")) { openWindow(id: "add-connection") }
                .keyboardShortcut("n").disabled(!model.canManageProfiles)
            Button(L10n.text("menubaractions.connection_settings")) { openWindow(id: "profile-editor") }
                .keyboardShortcut("i").disabled(!model.canManageProfiles || !model.hasSelectedProfile)
        }
        CommandGroup(after: .toolbar) {
            Button(L10n.text("menubaractions.routing")) { openWindow(id: "routing") }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button(L10n.text("window.diagnostics")) { openWindow(id: "diagnostics") }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
