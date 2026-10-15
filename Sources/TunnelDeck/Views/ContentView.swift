import SwiftUI
import TunnelCore

struct ContentView: View {
    @Bindable var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selection) {
                    ForEach(model.profiles) { profile in
                        Label {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).lineLimit(1)
                                HStack(spacing: 6) {
                                    ConnectionStatusIndicator(state: model.connection.state(for: profile.id))
                                    Text(profile.kind.title).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: { Image(systemName: profile.kind.symbol) }
                        .tag(profile.id)
                    }
                }
                .listStyle(.sidebar)
                .disabled(model.connection.locked)
                .onChange(of: model.selection) { _, id in model.select(id) }
                HStack {
                    Menu { ForEach(VPNProtocol.allCases) { kind in Button(kind.title) { model.add(kind) } } }
                    label: { Image(systemName: "plus").frame(width: 24) }
                    .menuStyle(.borderlessButton).fixedSize()
                    Button { model.deleteSelected() } label: { Image(systemName: "minus") }
                        .buttonStyle(.borderless).help("Удалить профиль")
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
                }
                .padding(14).disabled(model.connection.locked)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 225, max: 290)
            .navigationTitle("Подключения")
        } detail: {
            VStack(spacing: 0) {
                ProfileEditor(model: model)
                Divider()
                LogView(connection: model.connection)
                    .frame(minHeight: 150, idealHeight: 210, maxHeight: 270)
            }
            .navigationTitle(model.draft.name)
            .toolbar {
                ToolbarItem {
                    Button("Сохранить", systemImage: "square.and.arrow.down") { _ = model.save() }
                        .disabled(model.connection.locked).keyboardShortcut("s", modifiers: .command)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 690)
    }
}
