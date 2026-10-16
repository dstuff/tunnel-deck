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
                        Button("Повторить сохранение") { _ = model.save(showNotice: false) }
                            .disabled(!model.canManageProfiles)
                    } else if connection.state == .failed {
                        Button("Исправить") {
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
            return Text("Подключено: ").foregroundColor(.green) + Text(profile?.name ?? "VPN")
        }
        return Text(title)
    }

    private var title: String {
        if model.switcher.isSwitching { return "Переключаем подключение" }
        if connection.state == .connected { return "Подключено: \(profile?.name ?? "VPN")" }
        if connection.state == .idle { return "VPN отключён" }
        return connection.state.title
    }

    private var subtitle: String {
        if let id = model.switcher.targetProfile,
           let target = model.profiles.first(where: { $0.id == id }) {
            return "Восстанавливаем сеть перед подключением «\(target.name)»"
        }
        if connection.state == .idle {
            return model.hasSelectedProfile ? model.draft.name : "Добавьте первое подключение"
        }
        return profile?.name ?? "Выберите подключение ниже"
    }

    private var actionTitle: String {
        if model.switcher.isSwitching { return "Отменить" }
        switch connection.state {
        case .connected: return "Отключить"
        case .disconnecting: return "Отключаем…"
        default:
            if connection.locked { return "Отменить" }
            return model.hasSelectedProfile ? "Подключить" : "Добавить подключение"
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
