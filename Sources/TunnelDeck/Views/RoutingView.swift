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
    @State private var fileError: String?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Название схемы", text: $model.routing.name)
                        .font(.system(size: 25, weight: .semibold)).textFieldStyle(.plain)
                        .accessibilityLabel("Название схемы маршрутизации")
                    Text("Для всех подключений").foregroundStyle(.secondary)
                }
                HStack {
                    Text("Остальной интернет").fontWeight(.medium)
                    Spacer()
                    Picker("Остальной интернет", selection: $model.routing.defaultAction) {
                        Text("Через VPN").tag(RoutingAction.vpn)
                        Text("Без VPN").tag(RoutingAction.direct)
                    }.labelsHidden().frame(width: 200)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator.opacity(0.6)))
            }.padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 14)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Правила").font(.title3.weight(.semibold))
                            Text("Срабатывает первое совпадение").font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button { addRule() } label: { Image(systemName: "plus").frame(width: 20, height: 20) }
                            .help("Добавить правило").accessibilityLabel("Добавить правило")
                    }.padding(.horizontal, 20).padding(.vertical, 14)
                    Divider().padding(.horizontal, 20)
                    if model.routing.rules.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Пока нет правил").font(.headline)
                            Text("Весь интернет: \(model.routing.defaultAction.title.lowercased()). Добавьте сайты, сети или страны, для которых нужен другой маршрут.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Button("Добавить первое правило", action: addRule)
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
                    Button("Проверить адрес…") { showingCheck = true }
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
                        Text("Выберите правило").font(.headline)
                        Text("Здесь появятся его условия и действие.").foregroundStyle(.secondary)
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
            Button("Импортировать…") { importFile() }
            Button("Экспортировать…") { exportFile() }.disabled(model.routingError != nil)
        }
        .onAppear { if selection == nil { selection = model.routing.rules.first?.id }; listFocused = true }
        .onChange(of: model.routing.rules.map(\.id)) { _, ids in if !ids.contains(selection ?? UUID()) { selection = ids.first } }
        .sheet(isPresented: $showingCheck) { RoutingCheckView(model: model) }
        .sheet(isPresented: $showingImport) { importPreview }
        .alert("Ошибка файла маршрутизации", isPresented: Binding(get: { fileError != nil }, set: { if !$0 { fileError = nil } })) {
            Button("Готово", role: .cancel) {}
        } message: { Text(fileError ?? "") }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if let error = model.persistenceError ?? model.routingError ?? model.switcher.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red).lineLimit(3)
                } else if model.switcher.isSwitching {
                    Label("Применяем правила…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                } else if model.routingPending {
                    Label("Есть неприменённые изменения", systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(colorScheme == .dark ? Color.orange : Color(red: 0.58, green: 0.30, blue: 0.02))
                } else {
                    Label(model.connection.activeRouting == nil ? "Правила применятся при подключении" : "Правила применены", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
                Text(model.savedRouting == model.routing ? "Настройки сохранены" : "Сохраняем настройки…").font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
            Spacer(minLength: 8)
            Button("Применить и переподключить") { model.applyRouting() }
                .buttonStyle(PrimaryConnectionButtonStyle()).disabled(!model.canApplyRouting)
            Button("Готово") { if model.save(showNotice: false) { dismiss() } }
                .buttonStyle(SecondaryConnectionButtonStyle())
        }
    }

    private func row(_ rule: RoutingRule, index: Int) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary).font(.caption)
            Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
            VStack(alignment: .leading, spacing: 5) {
                Text((try? rule.match.normalized().displayValue) ?? (rule.match.value.isEmpty ? "Новое правило" : rule.match.value))
                    .fontWeight(.medium).lineLimit(1)
                Text(rule.enabled ? rule.action.title : "Выключено").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Menu {
                Button("Поднять") { move(rule.id, to: max(0, index - 1)) }.disabled(index == 0)
                Button("Опустить") { move(rule.id, to: min(model.routing.rules.count - 1, index + 1)) }.disabled(index == model.routing.rules.count - 1)
                Divider()
                Button(rule.enabled ? "Выключить" : "Включить") { if let value = binding(for: rule.id) { value.wrappedValue.enabled.toggle() } }
                Button("Удалить", role: .destructive) { deleteRule(rule.id) }
            } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 24)
                .accessibilityLabel("Действия с правилом \(index + 1)")
        }
        .padding(.horizontal, 17).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        .background(selection == rule.id ? Color.blue.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection == rule.id ? Color.blue.opacity(0.5) : .clear))
        .padding(.horizontal, 5).padding(.vertical, 3)
        .onTapGesture { selection = rule.id; listFocused = true }
        .contextMenu {
            Button("Поднять") { move(rule.id, to: max(0, index - 1)) }.disabled(index == 0)
            Button("Опустить") { move(rule.id, to: min(model.routing.rules.count - 1, index + 1)) }.disabled(index == model.routing.rules.count - 1)
            Button("Удалить", role: .destructive) { deleteRule(rule.id) }
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
        guard model.routing.rules.count < RoutingPolicy.maximumRules else { fileError = "Достигнут предел: 1000 правил."; return }
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
        panel.title = "Импортировать маршрутизацию TunnelDeck"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            imported = try RoutingPolicy.importFile(file.read(upToCount: RoutingPolicy.maximumFileSize + 1) ?? Data())
            showingImport = true
        } catch { fileError = error.localizedDescription }
    }
    private func exportFile() {
        do {
            let data = try model.routing.exportFile()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "Мои правила.tunneldeck-routing"
            panel.title = "Экспортировать маршрутизацию"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
        } catch { fileError = error.localizedDescription }
    }
    private var importPreview: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Заменить текущую схему?").font(.title2.weight(.semibold))
            if let imported {
                Text(imported.name).font(.headline)
                Text("Правил: \(imported.rules.count). Остальной интернет: \(imported.defaultAction.title.lowercased()).")
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(imported.rules.enumerated()), id: \.element.id) { index, rule in
                            Text("\(index + 1). \(rule.match.displayValue) → \(rule.action.title)\(rule.enabled ? "" : " · выключено")")
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
                Text("Файл содержит только маршрутизацию. Подключение и переподключение не запускаются автоматически.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Отмена") { showingImport = false }.keyboardShortcut(.cancelAction)
                    Button("Заменить правила") {
                        if model.replaceRouting(imported) { selection = imported.rules.first?.id; showingImport = false }
                    }.buttonStyle(.borderedProminent)
                }
            }
            if let error = model.persistenceError { Text(error).foregroundStyle(.red) }
        }.padding(26).frame(width: 540)
    }
}
