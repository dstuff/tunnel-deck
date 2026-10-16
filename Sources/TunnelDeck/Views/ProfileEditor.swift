import SwiftUI
import TunnelCore

struct ProfileEditor: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var state: ConnectionState { model.connection.state(for: model.draft.id) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Image(systemName: model.draft.kind.symbol)
                    .font(.system(size: 28, weight: .light)).foregroundStyle(.tint)
                    .frame(width: 52, height: 52).background(.quaternary, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.draft.kind.title).font(.title2.weight(.semibold))
                    HStack(spacing: 6) {
                        ConnectionStatusIndicator(state: state)
                        Text(state.title).font(.callout).foregroundStyle(.secondary)
                        if state.busy { ProgressView().controlSize(.small) }
                    }
                }
                Spacer()
                if model.connection.activeProfile == model.draft.id, let date = model.connection.connectedAt {
                    TimelineView(.periodic(from: date, by: 1)) { context in
                        Text(Duration.seconds(Int(context.date.timeIntervalSince(date))).formatted(.time(pattern: .hourMinuteSecond)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 26).padding(.top, 24).padding(.bottom, 14)

            Form {
                Section {
                    TextField("Название", text: $model.draft.name)
                    if model.draft.kind == .openConnect {
                        TextField("Адрес сервера", text: $model.openConnectAddress, prompt: Text("https://vpn.example.com:443/?секрет"))
                            .autocorrectionDisabled()
                            .help("Полный HTTPS-адрес вместе с ? и camouflage-секретом, если он используется.")
                        TextField("Пользователь", text: $model.draft.username).autocorrectionDisabled()
                        SecureField("Пароль", text: $model.secrets.password)
                    } else {
                        HStack {
                            Text(model.draft.kind == .amneziaWG ? "Конфигурация .conf" : "JSON или ссылка VLESS / Trojan")
                            Spacer()
                            Button("Открыть файл…", systemImage: "doc.badge.plus") { model.importConfiguration() }
                        }
                        TextEditor(text: $model.secrets.configuration)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 140, maxHeight: 190)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.6)))
                        if model.draft.kind == .xray, let config = try? XrayConfiguration(model.secrets.configuration), config.outboundChoices.count > 1 {
                            Picker("Основной сервер", selection: $model.draft.xrayOutboundTag) {
                                Text("Выберите сервер").tag(nil as String?)
                                ForEach(config.outboundChoices) { choice in Text(choice.title).tag(choice.tag as String?) }
                            }
                        }
                        Text(model.draft.kind == .amneziaWG ? "Параметры AWG 3.1 сохраняются целиком. AllowedIPs определяет доступные через сервер сети; общие правила задаются в «Маршрутизации»." : "Исходный JSON сохраняется. При подключении routing, dns и входящие заменяются общей схемой TunnelDeck; выбранный сервер и его цепочка используются для действия «Через VPN».")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.draft.kind == .openConnect {
                    Section {
                        DisclosureGroup("Дополнительные настройки") {
                            TextField("Группа авторизации", text: $model.draft.authGroup)
                            TextField("Отпечаток сертификата", text: $model.draft.certificatePin, prompt: Text("Необязательно, pin-sha256:…"))
                            Toggle("Только TCP, без DTLS", isOn: $model.draft.disableDTLS)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(!model.canManageProfiles)

            VStack(alignment: .leading, spacing: 10) {
                if let error = model.persistenceError ?? (model.connection.statusProfile == model.draft.id ? model.connection.errorMessage : nil) {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                        .font(.callout).textSelection(.enabled).lineLimit(4)
                } else if model.connection.statusProfile == model.draft.id, let result = model.connection.checkResult {
                    Label(result, systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.callout)
                } else if let notice = model.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Проверить", systemImage: "stethoscope") { model.check() }
                        .disabled(model.connection.locked || model.switcher.isSwitching)
                    Spacer()
                    Button("Готово") {
                        if model.save(showNotice: false) { dismiss() }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.controlSize(.large)
                Text(model.connection.activeProfile == model.draft.id ? "Все данные сохраняются локально. Изменения применятся при следующем подключении." : "Все данные, включая пароли и конфигурации, сохраняются локально автоматически.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 26).padding(.bottom, 20)
        }
        .frame(minWidth: 600, minHeight: 580)
    }
}
