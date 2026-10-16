import SwiftUI
import TunnelCore

struct SettingsView: View {
    let connection: ConnectionController
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Form {
            Section("Маршрутизация") {
                Button("Настроить общие правила…") { openWindow(id: "routing") }
                Text("Одна схема применяется к OpenConnect, AmneziaWG и Xray.").foregroundStyle(.secondary)
            }
            Section("Сетевые модули") {
                ForEach(VPNProtocol.allCases) { kind in
                    LabeledContent(kind.title) {
                        if (try? connection.runtime.check(kind)) != nil {
                            Label("Готов", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else { Label("Не найден", systemImage: "exclamationmark.circle").foregroundStyle(.orange) }
                    }
                }
            }
            Section {
                Text("OpenConnect 9.21 · AmneziaWG 3.1.20260828 · Xray 26.3.27 + TunnelDeck.4")
                Text("Все данные подключений, включая пароли и конфигурации, автоматически сохраняются локально на этом Mac. Одновременно работает одно подключение.")
                    .foregroundStyle(.secondary)
            }.font(.callout)
        }.formStyle(.grouped).frame(width: 490, height: 420)
    }
}
