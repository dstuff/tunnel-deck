import TunnelLocalization
import Foundation
import TunnelCore

extension AppModel {
    static func applicationModel() -> AppModel {
        #if DEBUG
        if CommandLine.arguments.contains("--design-preview") {
            return DesignPreview.makeModel()
        }
        #endif
        return AppModel()
    }
}

#if DEBUG
/// Isolated presentation fixtures: temporary profile file, no helper or VPN traffic.
@MainActor private enum DesignPreview {
    static func makeModel() -> AppModel {
        let profiles = [VPNProfile(name: L10n.text("designpreview.personal"), kind: .xray),
                        VPNProfile(name: L10n.text("designpreview.work"), kind: .openConnect),
                        VPNProfile(name: L10n.text("designpreview.backup"), kind: .amneziaWG)]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TunnelDeck-Design-\(UUID().uuidString)")
        let store = ProfileStore(file: directory.appendingPathComponent("profiles.json"))
        var routing = RoutingPolicy()
        routing.rules = [RoutingRule(match: .init(type: .domainSuffix, value: "ads.example.net"), action: .block),
                         RoutingRule(match: .init(type: .domainSuffix, value: "example.org"), action: .vpn),
                         RoutingRule(match: .init(type: .country, value: "RU"), action: .direct)]
        do { try store.save(.init(profiles: profiles, selectedProfile: profiles[0].id, routing: routing)) }
        catch { preconditionFailure("Cannot initialize isolated design preview") }
        let model = AppModel(profileStore: store, arguments: [])
        model.connection.prepareDesignPreview(profile: profiles[0].id)
        model.connection.append(L10n.message("connectioncontroller.interface_preview_no_network_checks_were_performed"))
        return model
    }
}

#endif
