import TunnelLocalization
import SwiftUI
import AppKit
import TunnelCore

struct ContentView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var profileToDelete: VPNProfile?

    var body: some View {
        VStack(spacing: 0) {
            SessionSummaryView(model: model)
                .padding(.horizontal, 28).padding(.vertical, 16)
            Divider()
            Button { present("routing") } label: {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    Text(L10n.text("window.routing"))
                    Text(model.routing.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 12)
                    if model.routingPending { Text(L10n.text("contentview.changes_pending")).font(.caption).foregroundStyle(.orange) }
                    Text(L10n.text("contentview.configure")).foregroundStyle(.tint)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 28).padding(.vertical, 13)
            }.buttonStyle(.plain).help(L10n.text("contentview.shared_rules_for_all_connections"))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("contentview.connections"))
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 24)
                    if model.profiles.isEmpty {
                        ContentUnavailableView(L10n.text("contentview.no_connections"), systemImage: "network",
                                               description: Text(L10n.text("contentview.add_a_connection_to_set_up_your_vpn")))
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.profiles) { profile in
                                ProfileRowView(profile: profile, model: model,
                                               edit: { edit(profile) },
                                               delete: { profileToDelete = profile })
                                if profile.id != model.profiles.last?.id {
                                    Divider().padding(.leading, 78).padding(.trailing, 12)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 18).padding(.bottom, 22)
            }
            HStack {
                Button { present("add-connection") } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                        Text(L10n.text("contentview.add_connection"))
                    }.fixedSize()
                }
                .buttonStyle(PrimaryConnectionButtonStyle())
                .disabled(!model.canManageProfiles)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            Divider()
            HStack {
                Button(L10n.text("window.diagnostics"), systemImage: "waveform.path.ecg") { present("diagnostics") }
                Spacer(minLength: 12)
                Text(L10n.text("contentview.one_connection_can_run_at_a_time"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                SettingsLink { Label(L10n.text("window.settings"), systemImage: "gearshape") }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle("TunnelDeck")
        .onAppear { if CommandLine.arguments.contains("--routing-preview") { present("routing") } }
        .alert(L10n.text("contentview.delete_connection"), isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        ), presenting: profileToDelete) { profile in
            Button(L10n.text("action.cancel"), role: .cancel) {}
            Button(L10n.text("action.delete"), role: .destructive) {
                model.select(profile.id)
                if model.draft.id == profile.id { model.deleteSelected() }
            }
        } message: { profile in
            Text(L10n.text("contentview.and_its_saved_secrets_will_be_deleted", [.init(profile.name)]))
        }
    }

    private func edit(_ profile: VPNProfile) {
        guard model.canManageProfiles else { return }
        model.select(profile.id)
        if model.draft.id == profile.id { present("profile-editor") }
    }

    private func present(_ id: String) {
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
