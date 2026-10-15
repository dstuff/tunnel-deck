import SwiftUI
import AppKit

@main struct TunnelDeckApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("TunnelDeck", id: "main") {
            ContentView(model: model)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 1080, height: 810)
        .commands {
            CommandGroup(replacing: .newItem) {
                Menu("Новое подключение") {
                    Button("OpenConnect") { model.add(.openConnect) }
                    Button("AmneziaWG 3.1") { model.add(.amneziaWG) }
                    Button("Xray") { model.add(.xray) }
                }.disabled(model.connection.locked)
            }
        }
        Settings { SettingsView(connection: model.connection) }
        MenuBarExtra {
            Text(model.connection.state.title)
            Button("Открыть TunnelDeck") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first(where: { $0.canBecomeMain })?.makeKeyAndOrderFront(nil) }
            if model.connection.locked { Button("Отключить") { model.connection.disconnect() } }
            Divider()
            Button("Завершить TunnelDeck") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Label("TunnelDeck — \(model.connection.state.title)", systemImage: model.connection.state.menuBarSymbol)
                .labelStyle(.iconOnly)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
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
        guard let connection = model?.connection, connection.locked else { return .terminateNow }
        connection.disconnect()
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
