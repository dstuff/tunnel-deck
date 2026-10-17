import TunnelLocalization
import SwiftUI
import TunnelCore

struct SettingsView: View {
    let connection: ConnectionController
    @Bindable var language: LanguageSettings
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section(L10n.text("settings.general")) {
                Picker(L10n.text("settings.language"), selection: $language.selection) {
                    Text(L10n.text("language.system")).tag(AppLanguage.system)
                    Text(L10n.text("language.russian")).tag(AppLanguage.russian)
                    Text(L10n.text("language.english_us")).tag(AppLanguage.englishUS)
                }
            }
            Section(L10n.text("window.routing")) {
                Button(L10n.text("settingsview.configure_shared_rules")) { openWindow(id: "routing") }
                Text(L10n.text("settingsview.one_policy_applies_to_openconnect_amneziawg_and_xray")).foregroundStyle(.secondary)
            }
            Section(L10n.text("settingsview.network_modules")) {
                ForEach(VPNProtocol.allCases) { kind in
                    LabeledContent(kind.title) {
                        if (try? connection.runtime.check(kind)) != nil {
                            Label(L10n.text("settingsview.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else { Label(L10n.text("settingsview.not_found"), systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                }
            }
            Section {
                Text("OpenConnect 9.21 · AmneziaWG 3.1.20260828 · Xray 26.3.27 + TunnelDeck.4")
                Text(L10n.text("settingsview.all_connection_data_including_passwords_and_configurations_is_automatically"))
                    .foregroundStyle(.secondary)
            }.font(.callout)
        }.formStyle(.grouped).frame(width: 520, height: 520)
    }
}
