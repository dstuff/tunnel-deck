import SwiftUI
import AppKit
import TunnelCore
import TunnelLocalization

struct SettingsView: View {
    let model: AppModel
    @Bindable var language: LanguageSettings
    let onBack: () -> Void
    let openRouting: () -> Void
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: L10n.text("window.settings"), backTitle: L10n.text("contentview.connections"), onBack: onBack) { EmptyView() }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    section(L10n.text("settings.general")) {
                        AdaptiveSettingRow(title: L10n.text("settings.language")) {
                            Picker(L10n.text("settings.language"), selection: $language.selection) {
                                Text(L10n.text("language.system")).tag(AppLanguage.system)
                                Text(L10n.text("language.russian")).tag(AppLanguage.russian)
                                Text(L10n.text("language.english_us")).tag(AppLanguage.englishUS)
                            }.labelsHidden()
                        }.padding(.vertical, 8)
                    }
                    section(L10n.text("window.routing")) {
                        Button(action: openRouting) {
                            HStack(spacing: 16) {
                                Image(systemName: "arrow.triangle.branch").font(.title2).foregroundStyle(.tint)
                                    .frame(width: 38, height: 38).background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(model.routing.name).fontWeight(.semibold)
                                    Text(L10n.text("settingsview.one_policy_applies_to_openconnect_amneziawg_and_xray"))
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }.contentShape(Rectangle()).padding(.vertical, 8)
                        }.buttonStyle(.plain)
                    }
                    section(L10n.text("settingsview.network_modules")) {
                        VStack(spacing: 0) {
                            ForEach(VPNProtocol.allCases) { kind in
                                HStack(spacing: 14) {
                                    Image(systemName: kind.symbol).foregroundStyle(.secondary)
                                        .frame(width: 26, height: 26).background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                                    moduleTitle(kind)
                                    Spacer(minLength: 12)
                                    if (try? model.connection.runtime.check(kind)) != nil {
                                        Label(L10n.text("settingsview.ready"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                                    } else {
                                        Label(L10n.text("settingsview.not_found"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                                    }
                                }.padding(.vertical, 4)
                                if kind != VPNProtocol.allCases.last { Divider() }
                            }
                        }
                    }
                    Text(L10n.text("settings.local_storage"))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 26).padding(.top, 8).padding(.bottom, 16)
                .frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack {
                    diagnostics
                    Spacer(minLength: 20)
                    autosaveText.fixedSize()
                }
                VStack(alignment: .leading, spacing: 8) { diagnostics; autosaveText }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 26).padding(.vertical, 14)
        }
    }

    private func moduleTitle(_ kind: VPNProtocol) -> some View {
        let details: (name: String, version: String)
        switch kind {
        case .openConnect: details = ("OpenConnect", "9.21")
        case .amneziaWG: details = ("AmneziaWG", "3.1.20260828")
        case .xray: details = ("Xray", "26.3.27 + TunnelDeck.4")
        }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(details.name)
            Text(details.version).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var autosaveText: some View {
        Text(L10n.text("settings.autosave")).font(.caption).foregroundStyle(.secondary)
    }
    private var diagnostics: some View {
        Button(L10n.text("window.diagnostics"), systemImage: "waveform.path.ecg") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow(id: "diagnostics")
        }.buttonStyle(.borderless).foregroundStyle(.secondary).fixedSize()
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
            Divider()
            content()
        }
    }
}
