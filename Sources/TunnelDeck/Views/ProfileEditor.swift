import TunnelLocalization
import SwiftUI
import TunnelCore

struct ProfileEditor: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    private var state: ConnectionState { model.connection.state(for: model.draft.id) }
    var body: some View {
        Group {
            if model.hasSelectedProfile {
                editor
            } else {
                ContentUnavailableView(L10n.text("profileeditor.no_connection_selected"), systemImage: "network",
                                       description: Text(L10n.text("profileeditor.add_a_connection_in_the_main_tunneldeck_window")))
            }
        }
        .frame(minWidth: 600, minHeight: 580)
    }

    private var editor: some View {
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
                    TextField(L10n.text("addconnectionview.name"), text: $model.draft.name)
                    if model.draft.kind == .openConnect {
                        TextField(L10n.text("profileeditor.server_address"), text: $model.openConnectAddress, prompt: Text(L10n.text("profileeditor.https_vpn_example_com_443_secret")))
                            .autocorrectionDisabled()
                            .help(L10n.text("profileeditor.the_full_https_address_including_and_the_camouflage_secret"))
                        TextField(L10n.text("addconnectionview.username"), text: $model.draft.username).autocorrectionDisabled()
                        SecureField(L10n.text("addconnectionview.password"), text: $model.secrets.password)
                    } else {
                        HStack {
                            Text(model.draft.kind == .amneziaWG ? L10n.text("profileeditor.conf_configuration") : L10n.text("profileeditor.json_or_vless_trojan_link"))
                            Spacer()
                            Button(L10n.text("profileeditor.open_file"), systemImage: "doc.badge.plus") { model.importConfiguration() }
                        }
                        TextEditor(text: $model.secrets.configuration)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 140, maxHeight: 190)
                            .scrollContentBackground(.hidden)
                            .padding(6).background(.background, in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator.opacity(0.6)))
                        if model.draft.kind == .xray, let config = try? XrayConfiguration(model.secrets.configuration), config.outboundChoices.count > 1 {
                            Picker(L10n.text("profileeditor.primary_server"), selection: $model.draft.xrayOutboundTag) {
                                Text(L10n.text("profileeditor.choose_a_server")).tag(nil as String?)
                                ForEach(config.outboundChoices) { choice in Text(choice.title).tag(choice.tag as String?) }
                            }
                        }
                        Text(model.draft.kind == .amneziaWG ? L10n.text("profileeditor.awg_3_1_parameters_are_saved_in_full_allowedips") : L10n.text("profileeditor.the_original_json_is_saved_when_connecting_routing_dns"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if model.draft.kind == .openConnect {
                    Section {
                        DisclosureGroup(L10n.text("profileeditor.advanced_settings")) {
                            TextField(L10n.text("profileeditor.authentication_group"), text: $model.draft.authGroup)
                            TextField(L10n.text("profileeditor.certificate_fingerprint"), text: $model.draft.certificatePin, prompt: Text(L10n.text("profileeditor.optional_pin_sha256")))
                            Toggle(L10n.text("profileeditor.tcp_only_no_dtls"), isOn: $model.draft.disableDTLS)
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
                    Button(L10n.text("action.check"), systemImage: "stethoscope") { model.check() }
                        .disabled(model.connection.locked || model.switcher.isSwitching)
                    Spacer()
                    Button(L10n.text("action.done")) {
                        if model.save(showNotice: false) { dismiss() }
                    }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                }.controlSize(.large)
                Text(model.connection.activeProfile == model.draft.id ? L10n.text("profileeditor.all_data_is_saved_locally_changes_apply_to_the") : L10n.text("profileeditor.all_data_including_passwords_and_configurations_is_saved_locally"))
                    .font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 26).padding(.bottom, 20)
        }
    }
}
