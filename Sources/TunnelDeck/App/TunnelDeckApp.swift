import TunnelLocalization
import SwiftUI
import AppKit
import TunnelCore

@main struct TunnelDeckApp: App {
    @State private var model: AppModel
    @State private var language: LanguageSettings
    private let windows = MainWindowCoordinator()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    init() {
        let language = LanguageSettings.shared
        _language = State(initialValue: language)
        _model = State(initialValue: AppModel.applicationModel())
    }
    var body: some Scene {
        WindowGroup("TunnelDeck", id: "connections") {
            ContentView(model: model, language: language, windows: windows)
                .preferredColorScheme(CommandLine.arguments.contains("--design-preview") ? (CommandLine.arguments.contains("--light-preview") ? .light : .dark) : nil)
                .onAppear { appDelegate.model = model }
        }
        .defaultSize(width: 780, height: 630)
        .windowResizability(.contentMinSize)
        .commands { ConnectionCommands(model: model, windows: windows) }
        Window(L10n.text("window.profile_editor"), id: "profile-editor") {
            ProfileEditor(model: model)
                .localizedWindowTitle(L10n.text("window.profile_editor"))
        }
        .defaultSize(width: 640, height: 620)
        .windowResizability(.contentMinSize)
        Window(L10n.text("connection.new"), id: "add-connection") {
            AddConnectionView(model: model)
                .localizedWindowTitle(L10n.text("connection.new"))
        }
        .windowResizability(.contentSize)
        Window(L10n.text("window.diagnostics"), id: "diagnostics") {
            LogView(connection: model.connection).frame(minWidth: 600, minHeight: 300)
                .localizedWindowTitle(L10n.text("window.diagnostics"))
        }
        .defaultSize(width: 780, height: 460)
        MenuBarExtra {
            MenuBarActions(model: model, windows: windows)
        } label: {
            Label {
                Text("TunnelDeck — \(model.connection.state.title)")
            } icon: {
                if model.connection.state == .connected || model.connection.state.busy,
                   let image = NSImage(systemSymbolName: model.connection.state.menuBarSymbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 16, weight: .regular)) {
                    Image(nsImage: image).renderingMode(.template)
                } else {
                    Image(systemName: model.connection.state.menuBarSymbol)
                }
            }
            .labelStyle(.iconOnly)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var menuObservers: [NSObjectProtocol] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        PrivateSession.removeAbandoned()
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
        for name in [Notification.Name.appLanguageDidChange, NSMenu.didBeginTrackingNotification] {
            menuObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MenuLocalization.refresh() }
                DispatchQueue.main.async { MenuLocalization.refresh() }
                RunLoop.main.perform(inModes: [.eventTracking, .common]) {
                    MainActor.assumeIsolated { MenuLocalization.refresh() }
                }
            })
        }
        DispatchQueue.main.async { MenuLocalization.refresh() }
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        LanguageSettings.shared.refreshSystemLanguage()
        MenuLocalization.refresh()
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let model, !model.save(showNotice: false) {
            let alert = NSAlert()
            alert.messageText = L10n.text("tunneldeckapp.could_not_save_settings")
            alert.informativeText = model.persistenceError ?? L10n.text("tunneldeckapp.check_the_connection_settings_and_try_quitting_again")
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
            alert.messageText = L10n.text("tunneldeckapp.vpn_is_still_disconnecting")
            alert.informativeText = L10n.text("tunneldeckapp.wait_for_the_network_settings_to_be_restored_then")
            alert.runModal(); NSApp.reply(toApplicationShouldTerminate: false)
        }
        return .terminateLater
    }
}
