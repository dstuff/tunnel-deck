import SwiftUI
import AppKit
import TunnelCore

@main struct TunnelDeckApp: App {
    @State private var model = AppModel.applicationModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("TunnelDeck", id: "connections") {
            ContentView(model: model)
                .preferredColorScheme(CommandLine.arguments.contains("--design-preview") ? .dark : nil)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 780, height: 630)
        .commands { ConnectionCommands(model: model) }
        Window("Настройки подключения", id: "profile-editor") {
            ProfileEditor(model: model)
                .tint(.blue)
        }
        .defaultSize(width: 640, height: 620)
        .windowResizability(.contentMinSize)
        Window("Новое подключение", id: "add-connection") {
            AddConnectionView(model: model)
                .tint(.blue)
        }
        .windowResizability(.contentSize)
        Window("Диагностика", id: "diagnostics") {
            LogView(connection: model.connection).frame(minWidth: 600, minHeight: 300)
        }
        .defaultSize(width: 780, height: 460)
        Settings { SettingsView(connection: model.connection) }
        MenuBarExtra {
            MenuBarActions(model: model)
        } label: {
            Label("TunnelDeck — \(model.connection.state.title)", systemImage: model.connection.state.menuBarSymbol)
                .labelStyle(.iconOnly)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        PrivateSession.removeAbandoned()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, !model.save(showNotice: false) {
            let alert = NSAlert()
            alert.messageText = "Не удалось сохранить настройки"
            alert.informativeText = model.persistenceError ?? "Проверьте настройки подключения и повторите выход."
            alert.runModal()
            return .terminateCancel
        }
        model?.switcher.cancel()
        guard let connection = model?.connection, connection.locked else { return .terminateNow }
        model?.disconnect()
        Task { @MainActor in
            for _ in 0..<80 {
                if !connection.hasSession { NSApp.reply(toApplicationShouldTerminate: true); return }
                try? await Task.sleep(for: .milliseconds(250))
            }
            let alert = NSAlert()
            alert.messageText = "VPN ещё завершает соединение"
            alert.informativeText = "Дождитесь восстановления сетевых настроек и повторите выход."
            alert.runModal(); NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }
}
