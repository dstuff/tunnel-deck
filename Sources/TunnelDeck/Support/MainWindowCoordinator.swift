import AppKit
import SwiftUI

/// Commands can originate in auxiliary windows or the menu bar. Register actual
/// main windows instead of finding them by their localized visible title.
@MainActor final class MainWindowCoordinator {
    private struct Entry {
        weak var window: NSWindow?
        weak var navigation: MainNavigation?
    }
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var pending: MainDestination?
    private var openingMainWindow = false

    func register(_ window: NSWindow, navigation: MainNavigation) {
        entries[ObjectIdentifier(window)] = Entry(window: window, navigation: navigation)
        openingMainWindow = false
        if let pending {
            self.pending = nil
            navigation.open(pending)
        }
    }

    func unregister(_ window: NSWindow) { entries.removeValue(forKey: ObjectIdentifier(window)) }

    func present(_ destination: MainDestination? = nil, openWindow: () -> Void) {
        entries = entries.filter { $0.value.window != nil && $0.value.navigation != nil }
        NSApp.activate(ignoringOtherApps: true)
        let entry = NSApp.orderedWindows.compactMap { entries[ObjectIdentifier($0)] }.first
            ?? entries.values.first { $0.window?.isMiniaturized == true }
        if let entry, let window = entry.window, let navigation = entry.navigation {
            if let destination { navigation.open(destination) }
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            if let destination { pending = destination }
            guard !openingMainWindow else { return }
            openingMainWindow = true
            openWindow()
        }
    }
}

struct MainWindowRegistration: NSViewRepresentable {
    let coordinator: MainWindowCoordinator
    let navigation: MainNavigation

    func makeNSView(context: Context) -> RegistrationView {
        RegistrationView(coordinator: coordinator, navigation: navigation)
    }
    func updateNSView(_ view: RegistrationView, context: Context) { view.registerWindow() }
    static func dismantleNSView(_ view: RegistrationView, coordinator: ()) { view.detach() }

    final class RegistrationView: NSView {
        let coordinator: MainWindowCoordinator
        let navigation: MainNavigation
        private weak var registeredWindow: NSWindow?
        private var closeObserver: NSObjectProtocol?

        init(coordinator: MainWindowCoordinator, navigation: MainNavigation) {
            self.coordinator = coordinator
            self.navigation = navigation
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); registerWindow() }

        func registerWindow() {
            guard let window, registeredWindow !== window else { return }
            detach()
            registeredWindow = window
            coordinator.register(window, navigation: navigation)
            closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                                  object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.detach() }
            }
        }
        func detach() {
            if let registeredWindow { coordinator.unregister(registeredWindow) }
            registeredWindow = nil
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }
    }
}

private struct MainNavigationKey: FocusedValueKey { typealias Value = MainNavigation }
extension FocusedValues {
    var mainNavigation: MainNavigation? {
        get { self[MainNavigationKey.self] }
        set { self[MainNavigationKey.self] = newValue }
    }
}
