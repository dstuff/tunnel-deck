import SwiftUI
import AppKit
import TunnelCore

struct AddConnectionView: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var imported: ConnectionImport?
    @State private var name = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connectImmediately = false
    @State private var filename: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Новое подключение").font(.title2.weight(.semibold))
                Text(imported == nil ? "Вставьте ссылку или адрес сервера, выберите файл или перетащите его в окно." : "Проверьте название и добавьте подключение в список.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let imported {
                Form {
                    LabeledContent("Протокол", value: imported.kind.title)
                    TextField("Название", text: $name)
                    if imported.kind == .openConnect {
                        TextField("Пользователь", text: $username).autocorrectionDisabled()
                        SecureField("Пароль", text: $password)
                    }
                    Toggle("Подключиться сразу", isOn: $connectImmediately)
                }
                .formStyle(.grouped)
                Text("Все данные подключения будут сохранены локально. Доступность сервера проверяется при подключении.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Ссылка, конфигурация или адрес сервера").font(.callout.weight(.medium))
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(minHeight: 140)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel("Ссылка, конфигурация или адрес сервера")
                    Text("OpenConnect · AmneziaWG .conf · Xray JSON · VLESS / Trojan")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Выбрать файл…", systemImage: "doc.badge.plus", action: chooseFile)
                        if let filename { Text(filename).foregroundStyle(.secondary).lineLimit(1) }
                    }
                }
            }
            if let error = error ?? model.persistenceError {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack {
                Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction)
                if imported != nil { Button("Назад") { imported = nil; error = nil } }
                Spacer()
                Button(imported == nil ? "Продолжить" : "Добавить", action: advance)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(!model.canManageProfiles || (imported == nil && input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
            .controlSize(.large)
        }
        .padding(26).frame(width: 560, height: 470)
        .dropDestination(for: URL.self) { urls, _ in
            guard urls.count == 1, let url = urls.first, url.isFileURL else { return false }
            loadFile(url)
            return true
        }
        .onDisappear {
            input = ""; imported = nil; name = ""; username = ""; password = ""
            filename = nil; error = nil; connectImmediately = false
        }
    }

    private func advance() {
        error = nil
        if let imported {
            if model.importConnection(imported, name: name, username: username, password: password) {
                if connectImmediately { model.connectProfile(model.draft.id) }
                dismiss()
            }
        } else {
            do {
                let result = try ConnectionImport(input)
                imported = result
                if name.isEmpty { name = filename ?? result.suggestedName }
            } catch { self.error = error.localizedDescription }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Выберите конфигурацию подключения"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadFile(url) }
    }

    private func loadFile(_ url: URL) {
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 256_000 else {
                throw VPNError("Файл слишком большой.")
            }
            input = try String(contentsOf: url, encoding: .utf8)
            filename = url.deletingPathExtension().lastPathComponent
            imported = nil
            name = ""
            advance()
        } catch { self.error = error.localizedDescription }
    }
}
