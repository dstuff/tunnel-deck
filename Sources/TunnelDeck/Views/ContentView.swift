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
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(.secondary)
                    Text("Маршрутизация")
                    Text(model.routing.name).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 12)
                    if model.routingPending { Text("Есть изменения").font(.caption).foregroundStyle(.orange) }
                    Text("Настроить").foregroundStyle(.blue)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle()).padding(.horizontal, 28).padding(.vertical, 13)
            }.buttonStyle(.plain).help("Общие правила для всех подключений")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Подключения")
                        .font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 10).padding(.top, 24)
                    if model.profiles.isEmpty {
                        ContentUnavailableView("Нет подключений", systemImage: "network",
                                               description: Text("Добавьте подключение, чтобы настроить VPN."))
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
                        Text("Добавить подключение")
                    }.fixedSize()
                }
                .buttonStyle(PrimaryConnectionButtonStyle())
                .disabled(!model.canManageProfiles)
                Spacer()
            }
            .padding(.horizontal, 28).padding(.vertical, 16)
            Divider()
            HStack {
                Button("Диагностика", systemImage: "waveform.path.ecg") { present("diagnostics") }
                Spacer(minLength: 12)
                Text("Одновременно работает одно подключение")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                SettingsLink { Label("Настройки", systemImage: "gearshape") }
            }
            .buttonStyle(.borderless).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.vertical, 16)
        }
        .frame(minWidth: 720, minHeight: 480)
        .tint(.blue)
        .navigationTitle("TunnelDeck")
        .onAppear { if CommandLine.arguments.contains("--routing-preview") { present("routing") } }
        .alert("Удалить подключение?", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        ), presenting: profileToDelete) { profile in
            Button("Отмена", role: .cancel) {}
            Button("Удалить", role: .destructive) {
                model.select(profile.id)
                if model.draft.id == profile.id { model.deleteSelected() }
            }
        } message: { profile in
            Text("«\(profile.name)» и сохранённые для него секреты будут удалены.")
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
