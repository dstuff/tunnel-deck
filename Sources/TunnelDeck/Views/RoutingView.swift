import TunnelLocalization
import SwiftUI
import AppKit
import UniformTypeIdentifiers
import TunnelCore

struct RoutingView: View {
    @Bindable var model: AppModel
    @Binding var selection: UUID?
    @Binding var compactEditor: Bool
    let wide: Bool
    let availableSize: CGSize
    let backTitle: String
    let onBack: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var imported: RoutingPolicy?
    @State private var showingImport = false
    @State private var showingCheck = false
    @State private var fileErrorContent: LocalizedMessage?
    private var fileError: String? { fileErrorContent?.resolve() }
    @FocusState private var listFocused: Bool
    @State private var keyboardSelectionID: UUID?

    private var editing: Bool {
        !wide && compactEditor && model.routing.rules.contains(where: { $0.id == selection })
    }
    private var selectedIndex: Int? { model.routing.rules.firstIndex { $0.id == selection } }
    private var sheetWidth: CGFloat { min(570, max(320, availableSize.width - 40)) }
    private var sheetHeight: CGFloat { min(540, max(280, availableSize.height - 40)) }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: editing ? L10n.text("routingruleeditor.rule", [.init((selectedIndex ?? 0) + 1)]) : L10n.text("window.routing"),
                         backTitle: editing ? L10n.text("window.routing") : backTitle, onBack: onBack) {
                if !editing {
                    HStack(spacing: 10) {
                        Button(L10n.text("routingview.import"), action: importFile)
                        Button(L10n.text("routingview.export"), action: exportFile).disabled(model.routingError != nil)
                    }
                }
            }
            if editing {
                ruleEditor
            } else {
                GeometryReader { geometry in
                  ScrollViewReader { scroll in
                    ScrollView {
                        VStack(alignment: .leading, spacing: wide ? 16 : 12) {
                            policyHeader
                            if wide {
                                HStack(alignment: .top, spacing: 0) {
                                    rulesPane
                                        .frame(width: (geometry.size.width - 52) * 0.43)
                                        .frame(minHeight: max(320, geometry.size.height - 140))
                                    Divider()
                                    ruleEditor
                                        .frame(maxWidth: .infinity)
                                }
                                .frame(minHeight: max(320, geometry.size.height - 140))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            } else {
                                rulesPane
                            }
                        }.padding(.horizontal, 26).padding(.bottom, 18)
                    }
                    .onChange(of: keyboardSelectionID) { _, id in
                        if let id { scroll.scrollTo(id, anchor: .center) }
                    }
                  }
                }
            }
            Divider()
            footer.padding(.horizontal, 26).padding(.vertical, 12)
        }
        .onAppear {
            if selection == nil { selection = model.routing.rules.first?.id }
            listFocused = !editing
        }
        .onChange(of: editing) { _, editing in listFocused = !editing }
        .onChange(of: model.routing.rules.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) {
                self.selection = ids.first
                compactEditor = false
            }
        }
        .sheet(isPresented: $showingCheck) {
            RoutingCheckView(model: model, width: sheetWidth, height: sheetHeight)
        }
        .sheet(isPresented: $showingImport) { importPreview }
        .alert(L10n.text("routingview.routing_file_error"), isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileErrorContent = nil } })) {
            Button(L10n.text("action.done"), role: .cancel) {}
        } message: { Text(fileError ?? "") }
    }

    private var policyHeader: some View {
        VStack(alignment: .leading, spacing: wide ? 12 : 10) {
            VStack(alignment: .leading, spacing: 4) {
                TextField(L10n.text("routingview.policy_name"), text: $model.routing.name)
                    .font(.title3.weight(.semibold)).textFieldStyle(.plain)
                    .accessibilityLabel(L10n.text("routingview.routing_policy_name"))
                Text(L10n.text("routingview.for_all_connections")).font(.callout).foregroundStyle(.secondary)
            }
            AdaptiveSettingRow(title: L10n.text("routingview.all_other_traffic")) {
                Picker(L10n.text("routingview.all_other_traffic"), selection: $model.routing.defaultAction) {
                    Text(L10n.text("routing.action.vpn")).tag(RoutingAction.vpn)
                    Text(L10n.text("routing.action.direct")).tag(RoutingAction.direct)
                }.labelsHidden()
            }
            .padding(.horizontal, 16).padding(.vertical, wide ? 12 : 10)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
        }
    }

    private var rulesPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("routingview.rules")).font(.title3.weight(.semibold))
                    Text(L10n.text("routingview.the_first_match_wins")).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: addRule) { Image(systemName: "plus").frame(width: 20, height: 20) }
                    .help(L10n.text("routingview.add_rule")).accessibilityLabel(L10n.text("routingview.add_rule"))
            }.padding(wide ? 16 : 0).padding(.vertical, wide ? 0 : 8)
            Divider()
            if model.routing.rules.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L10n.text("routingview.no_rules_yet")).font(.headline)
                    Text(L10n.text("routingview.all_traffic_add_sites_networks_or_countries_that_need", [.init(model.routing.defaultAction.title.lowercased())]))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Button(L10n.text("routingview.add_first_rule"), action: addRule)
                }.padding(.vertical, 22).padding(.horizontal, wide ? 18 : 0)
            } else {
                rulesList
            }
            if wide { Spacer(minLength: 16) }
            Button(L10n.text("routingview.check_address")) { showingCheck = true }
                .padding(.vertical, 16).padding(.horizontal, wide ? 18 : 0)
                .disabled(model.routingError != nil)
        }
    }

    @ViewBuilder private var ruleEditor: some View {
        if let index = selectedIndex, let binding = binding(for: model.routing.rules[index].id) {
            if wide {
                RoutingRuleEditor(rule: binding, number: index + 1) { deleteRule(binding.wrappedValue.id) }
            } else {
                ScrollView {
                    RoutingRuleEditor(rule: binding, number: index + 1, showsTitle: false) { deleteRule(binding.wrappedValue.id) }
                }
            }
        } else {
            VStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(L10n.text("routingview.select_a_rule")).font(.headline)
                Text(L10n.text("routingview.its_conditions_and_action_will_appear_here")).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, minHeight: 250)
        }
    }

    private var rulesList: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(model.routing.rules.enumerated()), id: \.element.id) { index, rule in
                row(rule, index: index).id(rule.id)
                if index < model.routing.rules.count - 1 { Divider().padding(.horizontal, wide ? 16 : 8) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($listFocused)
        .onMoveCommand { direction in
            guard direction == .up || direction == .down else { return }
            let rules = model.routing.rules
            guard !rules.isEmpty else { return }
            let index = rules.firstIndex { $0.id == selection }
            let next = direction == .down ? min((index ?? -1) + 1, rules.count - 1) : max((index ?? rules.count) - 1, 0)
            selection = rules[next].id
            keyboardSelectionID = selection
        }
        .onKeyPress(.return) {
            guard selection != nil else { return .ignored }
            compactEditor = true
            return .handled
        }
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) {
                saveStatus
                Spacer(minLength: 0)
                footerActions.fixedSize()
            }
            VStack(alignment: .leading, spacing: 12) {
                saveStatus
                HStack { Spacer(minLength: 0); footerActions }
            }
        }
    }

    private var saveStatus: some View {
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
            if model.persistenceError == nil {
                Text(model.savedRouting == model.routing ? L10n.text("routingview.settings_saved") : L10n.text("routingview.saving_settings"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.font(.callout).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var footerActions: some View {
        if model.persistenceError != nil {
            Button(L10n.text("sessionsummaryview.retry_saving")) { _ = model.save(showNotice: false) }
        }
        Button(L10n.text("routingview.apply_and_reconnect")) { model.applyRouting() }
            .buttonStyle(PrimaryConnectionButtonStyle()).disabled(!model.canApplyRouting)
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
            if !wide { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 17).padding(.vertical, wide ? 10 : 7)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .background(selection == rule.id ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(selection == rule.id ? Color.accentColor.opacity(0.5) : .clear))
        .padding(.horizontal, 5).padding(.vertical, wide ? 3 : 2)
        .onTapGesture { selection = rule.id; compactEditor = true; listFocused = true }
        .contextMenu {
            Button(L10n.text("routingview.move_up")) { move(rule.id, to: max(0, index - 1)) }.disabled(index == 0)
            Button(L10n.text("routingview.move_down")) { move(rule.id, to: min(model.routing.rules.count - 1, index + 1)) }.disabled(index == model.routing.rules.count - 1)
            Button(L10n.text("action.delete"), role: .destructive) { deleteRule(rule.id) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selection == rule.id ? [.isSelected] : [])
        .accessibilityAction { selection = rule.id; compactEditor = true; listFocused = true }
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
        let rule = RoutingRule(); model.routing.rules.append(rule); selection = rule.id; compactEditor = true
    }
    private func deleteRule(_ id: UUID) {
        guard let index = model.routing.rules.firstIndex(where: { $0.id == id }) else { return }
        model.routing.rules.remove(at: index)
        compactEditor = false
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
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(L10n.text("routingview.replace_the_current_policy")).font(.title2.weight(.semibold))
                    if let imported {
                        Text(imported.name).font(.headline)
                        Text(L10n.text("routingview.rules_all_other_traffic", [.init(L10n.message("routing.rule_count", [.init(imported.rules.count)])), .init(imported.defaultAction.title.lowercased())]))
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(imported.rules.enumerated()), id: \.element.id) { index, rule in
                                Text(L10n.text("routing.import_rule_summary", [.init(index + 1), .init(rule.match.displayValue), .init(rule.action.title), .init(rule.enabled ? "" : L10n.text("routing.disabled_suffix"))]))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Text(L10n.text("routingview.the_file_contains_routing_rules_only_connecting_and_reconnecting"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = model.persistenceError { Text(error).foregroundStyle(.red) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(26)
            }
            Divider()
            HStack {
                Spacer(minLength: 0)
                Button(L10n.text("action.cancel")) { showingImport = false }.keyboardShortcut(.cancelAction)
                if let imported {
                    Button(L10n.text("routingview.replace_rules")) {
                        if model.replaceRouting(imported) {
                            selection = imported.rules.first?.id
                            compactEditor = false
                            showingImport = false
                        }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding(20)
        }.frame(width: min(540, sheetWidth), height: sheetHeight)
    }
}
