import TunnelLocalization
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TunnelCore

struct RoutingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: UUID?
    @State private var imported: RoutingPolicy?
    @State private var showingImport = false
    @State private var showingCheck = false
    @State private var fileErrorContent: LocalizedMessage?
    private var fileError: String? { fileErrorContent?.resolve() }
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField(L10n.text("routingview.policy_name"), text: $model.routing.name)
                        .font(.system(size: 25, weight: .semibold)).textFieldStyle(.plain)
                        .accessibilityLabel(L10n.text("routingview.routing_policy_name"))
                    Text(L10n.text("routingview.for_all_connections")).foregroundStyle(.secondary)
                }
                HStack {
                    Text(L10n.text("routingview.all_other_traffic")).fontWeight(.medium)
                    Spacer()
                    Picker(L10n.text("routingview.all_other_traffic"), selection: $model.routing.defaultAction) {
                        Text(L10n.text("routing.action.vpn")).tag(RoutingAction.vpn)
                        Text(L10n.text("routing.action.direct")).tag(RoutingAction.direct)
                    }.labelsHidden().frame(width: 200)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
            }.padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 14)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(L10n.text("routingview.rules")).font(.title3.weight(.semibold))
                            Text(L10n.text("routingview.the_first_match_wins")).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button { addRule() } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                            .help(L10n.text("routingview.add_rule")).accessibilityLabel(L10n.text("routingview.add_rule"))
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                    Divider().padding(.horizontal, 20)
                    if model.routing.rules.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("routingview.no_rules_yet")).font(.headline)
                            Text(L10n.text("routingview.all_traffic_add_sites_networks_or_countries_that_need", [.init(model.routing.defaultAction.title.lowercased())]))
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button(L10n.text("routingview.add_first_rule"), action: addRule)
                        }.padding(22)
                        Spacer()
                    } else {
                        List(selection: $selection) {
                            ForEach(Array(model.routing.rules.enumerated()), id: \.element.id) { index, rule in
                                VStack(spacing: 0) {
                                    row(rule, index: index)
                                    if index < model.routing.rules.count - 1 { Divider().padding(.horizontal, 20) }
                                }
                                .tag(rule.id).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                        .listStyle(.plain).scrollContentBackground(.hidden)
                        .focused($listFocused)
                    }
                    Button(L10n.text("routingview.check_address")) { showingCheck = true }
                        .padding(20).disabled(model.routingError != nil)
                }.frame(minWidth: 360, maxWidth: .infinity)

                Divider()

                if let index = model.routing.rules.firstIndex(where: { $0.id == selection }), let binding = binding(for: model.routing.rules[index].id) {
                    GeometryReader { geometry in
                        ScrollView {
                            RoutingRuleEditor(rule: binding, number: index + 1) { deleteRule(binding.wrappedValue.id) }
                                .frame(minHeight: geometry.size.height)
                        }
                    }.frame(minWidth: 360, maxWidth: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "slider.horizontal.3").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(L10n.text("routingview.select_a_rule")).font(.headline)
                        Text(L10n.text("routingview.its_conditions_and_action_will_appear_here")).foregroundStyle(.secondary)
                    }.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 26).padding(.bottom, 18)

            Divider()
            footer.padding(.horizontal, 26).padding(.vertical, 17)
        }
        .frame(minWidth: 850, minHeight: 620)
        .toolbar {
            Button(L10n.text("routingview.import")) { importFile() }
            Button(L10n.text("routingview.export")) { exportFile() }.disabled(model.routingError != nil)
        }
        .onAppear { if selection == nil { selection = model.routing.rules.first?.id }; listFocused = true }
        .onChange(of: model.routing.rules.map(\.id)) { _, ids in if !ids.contains(selection ?? UUID()) { selection = ids.first } }
        .sheet(isPresented: $showingCheck) { RoutingCheckView(model: model) }
        .sheet(isPresented: $showingImport) { importPreview }
        .alert(L10n.text("routingview.routing_file_error"), isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileErrorContent = nil } })) {
            Button(L10n.text("action.done"), role: .cancel) {}
        } message: { Text(fileError ?? "") }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let error = model.persistenceError ?? model.routingError ?? model.switcher.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).lineLimit(3)
                } else if model.switcher.isSwitching {
                    Label(L10n.text("routingview.applying_rules"), systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                } else if model.routingPending {
                    Label(L10n.text("routingview.unapplied_changes"), systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(colorScheme == .dark ? Color.orange : Color(red: 0.58, green: 0.30, blue: 0.02))
                } else {
                    Label(model.connection.activeRouting == nil ? L10n.text("routingview.rules_apply_when_connecting") : L10n.text("routingview.rules_applied"), systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(model.savedRouting == model.routing ? L10n.text("routingview.settings_saved") : L10n.text("routingview.saving_settings")).font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
            Spacer(minLength: 8)
            Button(L10n.text("routingview.apply_and_reconnect")) { model.applyRouting() }
                .buttonStyle(PrimaryConnectionButtonStyle()).disabled(!model.canApplyRouting)
            Button(L10n.text("action.done")) { if model.save(showNotice: false) { dismiss() } }
                .buttonStyle(SecondaryConnectionButtonStyle())
        }
    }

    private func row(_ rule: RoutingRule, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.caption)
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text((try? rule.match.normalized().displayValue) ?? (rule.match.value.isEmpty ? L10n.text("routingview.new_rule") : rule.match.value))
                    .fontWeight(.medium).lineLimit(1)
                Text(rule.enabled ? rule.action.title : L10n.text("routing.disabled")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button(L10n.text("routingview.move_up")) { move(rule.id, to: max(0, index - 1)) }.disabled(index == 0)
                Button(L10n.text("routingview.move_down")) { move(rule.id, to: min(model.routing.rules.count - 1, index + 1)) }.disabled(index == model.routing.rules.count - 1)
                Divider()
                Button(rule.enabled ? L10n.text("routingview.disable") : L10n.text("routingview.enable")) { if let value = binding(for: rule.id) { value.wrappedValue.enabled.toggle() } }
                Button(L10n.text("action.delete"), role: .destructive) { deleteRule(rule.id) }
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24)
                .accessibilityLabel(L10n.text("routingview.actions_for_rule", [.init(index + 1)]))
        }
        .padding(.horizontal, 17).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .background(selection == rule.id ? Color.blue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection == rule.id ? Color.blue.opacity(0.5) : .clear))
        .padding(.horizontal, 5).padding(.vertical, 3)
        .onTapGesture { selection = rule.id; listFocused = true }
        .contextMenu {
            Button(L10n.text("routingview.move_up")) { move(rule.id, to: max(0, index - 1)) }.disabled(index == 0)
            Button(L10n.text("routingview.move_down")) { move(rule.id, to: min(model.routing.rules.count - 1, index + 1)) }.disabled(index == model.routing.rules.count - 1)
            Button(L10n.text("action.delete"), role: .destructive) { deleteRule(rule.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selection == rule.id ? [.isSelected] : [])
        .draggable(rule.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let text = items.first, let id = UUID(uuidString: text), model.routing.rules.contains(where: { $0.id == id }) else { return false }
            move(id, to: index); return true
        }
    }
    private func binding(for id: UUID) -> Binding<RoutingRule>? {
        guard model.routing.rules.contains(where: { $0.id == id }) else { return nil }
        return Binding(get: { model.routing.rules.first(where: { $0.id == id }) ?? RoutingRule(id: id) }, set: { value in
            if let index = model.routing.rules.firstIndex(where: { $0.id == id }) { model.routing.rules[index] = value }
        })
    }
    private func addRule() {
        guard model.routing.rules.count < RoutingPolicy.maximumRules else { fileErrorContent = L10n.message("routingview.the_limit_of_1_000_rules_has_been_reached"); return }
        let rule = RoutingRule(); model.routing.rules.append(rule); selection = rule.id
    }
    private func deleteRule(_ id: UUID) {
        guard let index = model.routing.rules.firstIndex(where: { $0.id == id }) else { return }
        model.routing.rules.remove(at: index)
        selection = model.routing.rules.isEmpty ? nil : model.routing.rules[min(index, model.routing.rules.count - 1)].id
    }
    private func move(_ id: UUID, to target: Int) {
        guard let index = model.routing.rules.firstIndex(where: { $0.id == id }), index != target else { return }
        let rule = model.routing.rules.remove(at: index); model.routing.rules.insert(rule, at: target); selection = id
    }
    private func importFile() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = L10n.text("routingview.import_tunneldeck_routing")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            imported = try RoutingPolicy.importFile(file.read(upToCount: RoutingPolicy.maximumFileSize + 1) ?? Data())
            showingImport = true
        } catch { fileErrorContent = error.localizedMessage }
    }
    private func exportFile() {
        do {
            let data = try model.routing.exportFile()
            let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("routingview.my_rules_tunneldeck_routing")
            panel.title = L10n.text("routingview.export_routing")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { fileErrorContent = error.localizedMessage }
    }
    private var importPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.text("routingview.replace_the_current_policy")).font(.title2.weight(.semibold))
            if let imported {
                Text(imported.name).font(.headline)
                Text(L10n.text("routingview.rules_all_other_traffic", [.init(L10n.message("routing.rule_count", [.init(imported.rules.count)])), .init(imported.defaultAction.title.lowercased())]))
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(imported.rules.enumerated()), id: \.element.id) { index, rule in
                            Text(L10n.text("routing.import_rule_summary", [.init(index + 1), .init(rule.match.displayValue), .init(rule.action.title), .init(rule.enabled ? "" : L10n.text("routing.disabled_suffix"))]))
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                Text(L10n.text("routingview.the_file_contains_routing_rules_only_connecting_and_reconnecting"))
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button(L10n.text("action.cancel")) { showingImport = false }.keyboardShortcut(.cancelAction)
                    Button(L10n.text("routingview.replace_rules")) {
                        if model.replaceRouting(imported) { selection = imported.rules.first?.id; showingImport = false }
                    }.buttonStyle(.borderedProminent)
                }
            }
            if let error = model.persistenceError { Text(error).foregroundStyle(.red) }
        }.padding(26).frame(width: 540)
    }
}
