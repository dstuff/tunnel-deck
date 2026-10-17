import TunnelLocalization
import SwiftUI
import AppKit
import TunnelCore

struct SessionSummaryView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    private var connection: ConnectionController { model.connection }
    private var profile: VPNProfile? {
        let id = connection.activeProfile ?? connection.statusProfile ?? model.selection
        return model.profiles.first { $0.id == id }
    }
    private var error: String? {
        model.persistenceError ?? model.switcher.errorMessage ?? connection.errorMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        ConnectionStatusIndicator(state: connection.state).scaleEffect(1.35)
                        statusTitle.font(.system(size: 19, weight: .semibold)).lineLimit(1)
                    }
                    if let date = connection.connectedAt {
                        TimelineView(.periodic(from: date, by: 1)) { context in
                            Text(Duration.seconds(max(0, Int(context.date.timeIntervalSince(date))))
                                .formatted(.time(pattern: .hourMinuteSecond(padHourToLength: 2))))
                                .monospacedDigit().font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.leading, 17)
                    } else {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).padding(.leading, 17)
                    }
                }
                Spacer(minLength: 16)
                Button(actionTitle, action: performAction)
                    .buttonStyle(PrimaryConnectionButtonStyle())
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled((connection.state == .disconnecting && !model.switcher.isSwitching) ||
                              (!model.hasSelectedProfile && !model.canManageProfiles))
            }
            if let error {
                HStack(alignment: .top, spacing: 16) {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    Spacer(minLength: 0)
                    if model.persistenceError != nil {
                        Button(L10n.text("sessionsummaryview.retry_saving")) { _ = model.save(showNotice: false) }
                            .disabled(!model.canManageProfiles)
                    } else if connection.state == .failed {
                        Button(L10n.text("sessionsummaryview.fix")) {
                            let id = profile?.id ?? model.draft.id
                            model.select(id)
                            if model.draft.id == id {
                                NSApp.activate(ignoringOtherApps: true)
                                openWindow(id: "profile-editor")
                            }
                        }.disabled(!model.canManageProfiles)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }

    private var statusTitle: Text {
        if connection.state == .connected && !model.switcher.isSwitching {
            let name = profile?.name ?? "VPN"
            var text = AttributedString(L10n.text("session.connected_profile", [.init(name)]))
            text.foregroundColor = .green
            if let range = text.range(of: name, options: .backwards) { text[range].foregroundColor = .primary }
            return Text(text)
        }
        return Text(title)
    }

    private var title: String {
        if model.switcher.isSwitching { return L10n.text("sessionsummaryview.switching_connection") }
        if connection.state == .connected { return L10n.text("session.connected_profile", [.init(profile?.name ?? "VPN")]) }
        if connection.state == .idle { return L10n.text("sessionsummaryview.vpn_is_off") }
        return connection.state.title
    }

    private var subtitle: String {
        if let id = model.switcher.targetProfile,
           let target = model.profiles.first(where: { $0.id == id }) {
            return L10n.text("sessionsummaryview.restoring_the_network_before_connecting_to", [.init(target.name)])
        }
        if connection.state == .idle {
            return model.hasSelectedProfile ? model.draft.name : L10n.text("sessionsummaryview.add_your_first_connection")
        }
        return profile?.name ?? L10n.text("sessionsummaryview.select_a_connection_below")
    }

    private var actionTitle: String {
        if model.switcher.isSwitching { return L10n.text("action.cancel_operation") }
        switch connection.state {
        case .connected: return L10n.text("action.disconnect")
        case .disconnecting: return L10n.text("sessionsummaryview.disconnecting")
        default:
            if connection.locked { return L10n.text("action.cancel_operation") }
            return model.hasSelectedProfile ? L10n.text("action.connect") : L10n.text("contentview.add_connection")
        }
    }

    private func performAction() {
        if connection.locked || model.switcher.isSwitching {
            model.disconnect()
        } else if !model.hasSelectedProfile {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "add-connection")
        } else {
            model.connectProfile(connection.state == .failed ? (profile?.id ?? model.draft.id) : model.draft.id)
        }
    }
}
