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
        HStack(spacing: 26) {
            Image(systemName: profile.kind.symbol)
                .font(.system(size: 24, weight: .regular))
                .foregroundStyle(state == .connected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 46, height: 46)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(profile.name).font(.system(size: 16, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                Text(profile.kind.title).font(.callout).foregroundStyle(.secondary)
            }
            .help(profile.name)
            Spacer(minLength: 16)
            if state == .connected {
                Label("Подключено", systemImage: "circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .labelStyle(StatusDotLabelStyle())
            } else if state.busy || isPending {
                ProgressView().controlSize(.small)
                Text(isPending ? "В очереди" : state.title)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Button(actionTitle) { model.connectProfile(profile.id) }
                    .buttonStyle(SecondaryConnectionButtonStyle())
                    .disabled(!model.canConnectProfile)
            }
            Menu {
                Button("Настроить…", systemImage: "slider.horizontal.3", action: edit)
                    .disabled(!model.canManageProfiles)
                Divider()
                Button("Удалить…", systemImage: "trash", role: .destructive, action: delete)
                    .disabled(!canDelete)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)
                    .background(.quaternary.opacity(0.6), in: Circle()).contentShape(Circle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Действия с подключением «\(profile.name)»")
            .accessibilityLabel("Действия с подключением \(profile.name)")
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
            Button("Настроить…", action: edit).disabled(!model.canManageProfiles)
            Button("Удалить…", role: .destructive, action: delete).disabled(!canDelete)
        }
        .accessibilityElement(children: .contain)
    }

    private var actionTitle: String {
        if state == .failed { return "Повторить" }
        return model.connection.state == .connected ? "Переключиться" : "Подключить"
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
