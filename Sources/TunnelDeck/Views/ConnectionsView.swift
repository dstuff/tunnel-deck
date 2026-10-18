import SwiftUI
import AppKit
import TunnelCore
import TunnelLocalization

struct ConnectionsView: View {
    @Bindable var model: AppModel
    let openSettings: () -> Void
    let openRouting: () -> Void
    @Environment(\.openWindow) private var openWindow
    @State private var profileToDelete: VPNProfile?

    var body: some View {
        VStack(spacing: 0) {
            Button(action: openRouting) {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.text("window.routing"))
                        Text(model.routing.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 12)
                    if model.routingPending {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            .help(L10n.text("contentview.changes_pending"))
                    }
                    Text(L10n.text("contentview.configure")).foregroundStyle(.tint).fixedSize()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 26).padding(.vertical, 12)
            }.buttonStyle(.plain).help(L10n.text("contentview.shared_rules_for_all_connections"))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("contentview.connections"))
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 20)
                    if model.profiles.isEmpty {
                        ContentUnavailableView(L10n.text("contentview.no_connections"), systemImage: "network",
                                               description: Text(L10n.text("contentview.add_a_connection_to_set_up_your_vpn")))
                            .frame(maxWidth: .infinity).padding(.vertical, 24)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.profiles) { profile in
                                ProfileRowView(profile: profile, model: model, edit: { edit(profile) },
                                               delete: { profileToDelete = profile })
                                if profile.id != model.profiles.last?.id { Divider().padding(.horizontal, 18) }
                            }
                        }
                    }
                }.padding(.horizontal, 18).padding(.bottom, 20)
            }
            HStack {
                Button(L10n.text("contentview.add_connection"), systemImage: "plus") { present("add-connection") }
                    .buttonStyle(PrimaryConnectionButtonStyle()).disabled(!model.canManageProfiles)
                Spacer(minLength: 0)
            }.padding(.horizontal, 26).padding(.vertical, 12)
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    footerButtons
                    Spacer(minLength: 0)
                    Text(L10n.text("contentview.one_connection_can_run_at_a_time")).font(.caption).fixedSize()
                }
                HStack { footerButtons; Spacer(minLength: 0) }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(.horizontal, 26).padding(.vertical, 14)
        }
        .alert(L10n.text("contentview.delete_connection"), isPresented: Binding(
            get: { profileToDelete != nil }, set: { if !$0 { profileToDelete = nil } }
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

    @ViewBuilder private var footerButtons: some View {
        Button(L10n.text("window.diagnostics"), systemImage: "waveform.path.ecg") { present("diagnostics") }.fixedSize()
        Button(L10n.text("window.settings"), systemImage: "gearshape", action: openSettings).fixedSize()
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
