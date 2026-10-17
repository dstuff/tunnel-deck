import TunnelLocalization
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
    @State private var errorContent: LocalizedMessage?
    private var error: String? { errorContent?.resolve() }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.text("connection.new")).font(.title2.weight(.semibold))
                Text(imported == nil ? L10n.text("addconnectionview.paste_a_link_or_server_address_choose_a_file") : L10n.text("addconnectionview.review_the_name_and_add_the_connection_to_the"))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let imported {
                Form {
                    LabeledContent(L10n.text("addconnectionview.protocol"), value: imported.kind.title)
                    TextField(L10n.text("addconnectionview.name"), text: $name)
                    if imported.kind == .openConnect {
                        TextField(L10n.text("addconnectionview.username"), text: $username).autocorrectionDisabled()
                        SecureField(L10n.text("addconnectionview.password"), text: $password)
                    }
                    Toggle(L10n.text("addconnectionview.connect_immediately"), isOn: $connectImmediately)
                }
                .formStyle(.grouped)
                Text(L10n.text("addconnectionview.all_connection_data_will_be_saved_locally_server_availability"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.text("addconnectionview.link_configuration_or_server_address")).font(.callout.weight(.medium))
                    TextEditor(text: $input)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .padding(10).frame(minHeight: 140)
                        .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator))
                        .accessibilityLabel(L10n.text("addconnectionview.link_configuration_or_server_address"))
                    Text("OpenConnect · AmneziaWG .conf · Xray JSON · VLESS / Trojan")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(L10n.text("addconnectionview.choose_file"), systemImage: "doc.badge.plus", action: chooseFile)
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
                Button(L10n.text("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                if imported != nil { Button(L10n.text("addconnectionview.back")) { imported = nil; errorContent = nil } }
                Spacer()
                Button(imported == nil ? L10n.text("addconnectionview.continue") : L10n.text("action.add"), action: advance)
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
            filename = nil; errorContent = nil; connectImmediately = false
        }
    }

    private func advance() {
        errorContent = nil
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
            } catch { self.errorContent = error.localizedMessage }
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = L10n.text("addconnectionview.choose_a_connection_configuration")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { loadFile(url) }
    }

    private func loadFile(_ url: URL) {
        do {
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 256_000 else {
                throw VPNError(L10n.message("appmodel.the_file_is_too_large"))
            }
            input = try String(contentsOf: url, encoding: .utf8)
            filename = url.deletingPathExtension().lastPathComponent
            imported = nil
            name = ""
            advance()
        } catch { self.errorContent = error.localizedMessage }
    }
}
