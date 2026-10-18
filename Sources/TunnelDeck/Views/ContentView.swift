import SwiftUI
import TunnelLocalization

struct ContentView: View {
    let model: AppModel
    let language: LanguageSettings
    let windows: MainWindowCoordinator
    @State private var navigation: MainNavigation

    init(model: AppModel, language: LanguageSettings, windows: MainWindowCoordinator) {
        self.model = model
        self.language = language
        self.windows = windows
        _navigation = State(initialValue: MainNavigation(model: model))
    }

    var body: some View {
        @Bindable var navigation = navigation
        GeometryReader { geometry in
            VStack(spacing: 0) {
                SessionSummaryView(model: model)
                    .padding(.horizontal, 26).padding(.vertical, 14)
                Divider()
                switch navigation.destination {
                case .connections:
                    ConnectionsView(model: model,
                                    openSettings: { navigation.open(.settings) },
                                    openRouting: { navigation.open(.routing) })
                case .settings:
                    SettingsView(model: model, language: language,
                                 onBack: { navigation.goBack() },
                                 openRouting: { navigation.open(.routing) })
                case .routing:
                    RoutingView(model: model, selection: $navigation.selectedRuleID,
                                compactEditor: $navigation.compactRuleEditor,
                                wide: navigation.wideRouting, availableSize: geometry.size,
                                backTitle: navigation.path.count > 1 ? L10n.text("window.settings") : L10n.text("contentview.connections"),
                                onBack: { navigation.goBack() })
                }
            }
            .onChange(of: geometry.size.width, initial: true) { _, width in navigation.updateWidth(width) }
        }
        .frame(minWidth: 520, minHeight: 480)
        .navigationTitle("TunnelDeck")
        .focusedSceneValue(\.mainNavigation, navigation)
        .background(MainWindowRegistration(coordinator: windows, navigation: navigation).frame(width: 0, height: 0))
        .onAppear {
            if CommandLine.arguments.contains("--routing-preview") { navigation.open(.routing) }
        }
    }
}
