import Observation
import Foundation

enum MainDestination: Equatable {
    case connections, settings, routing
}

/// Window-local navigation. Drafts remain in AppModel; changing layout never saves
/// or reconnects the VPN. Leaving routing flushes its existing autosave first.
@MainActor @Observable final class MainNavigation {
    private(set) var path: [MainDestination] = []
    var selectedRuleID: UUID?
    var compactRuleEditor = false
    private(set) var wideRouting = false
    @ObservationIgnored private let model: AppModel

    init(model: AppModel) { self.model = model }

    var destination: MainDestination { path.last ?? .connections }
    var showingRuleEditor: Bool {
        destination == .routing && !wideRouting && compactRuleEditor &&
        model.routing.rules.contains(where: { $0.id == selectedRuleID })
    }
    var canGoBack: Bool { !path.isEmpty }

    @discardableResult func open(_ destination: MainDestination) -> Bool {
        guard destination != self.destination else { return true }
        guard self.destination != .routing || model.save(showNotice: false) else { return false }
        switch destination {
        case .connections: path = []
        case .settings: path = [.settings]
        case .routing:
            path = self.destination == .settings ? [.settings, .routing] : [.routing]
        }
        return true
    }

    @discardableResult func goBack() -> Bool {
        if showingRuleEditor { compactRuleEditor = false; return true }
        guard canGoBack else { return false }
        guard destination != .routing || model.save(showNotice: false) else { return false }
        path.removeLast()
        return true
    }

    func updateWidth(_ width: CGFloat) {
        let wide = width >= 900
        if wideRouting && !wide && selectedRuleID != nil { compactRuleEditor = true }
        wideRouting = wide
    }
}
