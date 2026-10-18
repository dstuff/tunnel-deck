import TunnelLocalization
import SwiftUI
import TunnelCore

struct ProfileRowView: View {
    let profile: VPNProfile
    let model: AppModel
    let edit: () -> Void
    let delete: () -> Void

    private var state: ConnectionState { model.connection.state(for: profile.id) }
    private var isPending: Bool { model.switcher.targetProfile == profile.id }
    private var canDelete: Bool {
        model.canManageProfiles && model.connection.activeProfile != profile.id
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                identity
                Spacer(minLength: 12)
                connectionAction.fixedSize()
                actionsMenu
            }
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 16) {
                    identity
                    Spacer(minLength: 0)
                    actionsMenu
                }
                HStack { Spacer(minLength: 0); connectionAction }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(state == .connected ? Color.accentColor.opacity(0.09) : .clear,
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            if state == .connected {
                RoundedRectangle(cornerRadius: 12).strokeBorder(.tint.opacity(0.2))
            }
        }
        .contextMenu {
            Button(L10n.text("profilerowview.configure"), action: edit).disabled(!model.canManageProfiles)
            Button(L10n.text("profilerowview.delete"), role: .destructive, action: delete).disabled(!canDelete)
        }
        .accessibilityElement(children: .contain)
    }

    private var identity: some View {
        HStack(spacing: 18) {
            Image(systemName: profile.kind.symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(state == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 46, height: 46)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.name).font(.system(size: 16, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle)
                Text(profile.kind.title).font(.callout).foregroundStyle(.secondary)
            }
            .help(profile.name)
        }.frame(minWidth: 180, alignment: .leading)
    }

    @ViewBuilder private var connectionAction: some View {
            if state == .connected {
                Label(L10n.text("connection.state.connected"), systemImage: "circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .labelStyle(StatusDotLabelStyle())
            } else if state.busy || isPending {
                ProgressView().controlSize(.small)
                Text(isPending ? L10n.text("profilerowview.queued") : state.title)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button(actionTitle) { model.connectProfile(profile.id) }
                    .buttonStyle(SecondaryConnectionButtonStyle())
                    .disabled(!model.canConnectProfile)
            }
    }

    private var actionsMenu: some View {
            Menu {
                Button(L10n.text("profilerowview.configure"), systemImage: "slider.horizontal.3", action: edit)
                    .disabled(!model.canManageProfiles)
                Divider()
                Button(L10n.text("profilerowview.delete"), systemImage: "trash", role: .destructive, action: delete)
                    .disabled(!canDelete)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.6), in: Circle()).contentShape(Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help(L10n.text("profilerowview.actions_for_connection", [.init(profile.name)]))
            .accessibilityLabel(L10n.text("profilerowview.actions_for_connection_229", [.init(profile.name)]))
    }

    private var actionTitle: String {
        if state == .failed { return L10n.text("profilerowview.retry") }
        return model.connection.state == .connected ? L10n.text("profilerowview.switch") : L10n.text("action.connect")
    }
}

private struct StatusDotLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.font(.system(size: 8))
            configuration.title
        }
    }
}
