import SwiftUI
import TunnelCore

struct RoutingRuleEditor: View {
    @Binding var rule: RoutingRule
    let number: Int
    let remove: () -> Void
    private enum Category: String, CaseIterable { case site = "Сайт", network = "IP или сеть", country = "Страна" }
    private var category: Binding<Category> {
        Binding(get: {
            switch rule.match.type { case .domain, .domainSuffix: return .site; case .ipCIDR: return .network; case .country: return .country }
        }, set: { value in
            let previous = rule.match.type
            let type: RoutingMatchType = value == .site ? .domainSuffix : value == .network ? .ipCIDR : .country
            guard previous != type, !(value == .site && previous == .domain) else { return }
            rule.match = .init(type: type, value: type == .country ? "RU" : "")
        })
    }
    private var countries: [(String, String)] {
        RoutingMatch.countryCodes.map {
            ($0, Locale(identifier: "ru_RU").localizedString(forRegionCode: $0) ?? $0)
        }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }
    }
    private var validationError: String? {
        do { _ = try rule.match.normalized(); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Правило \(number)").font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 9) {
                Text("Что проверяем").foregroundStyle(.secondary)
                Picker("Что проверяем", selection: category) {
                    ForEach(Category.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 9) {
                switch rule.match.type {
                case .domain, .domainSuffix:
                    Text("Сайт").foregroundStyle(.secondary)
                    TextField("example.org или https://example.org/page", text: $rule.match.value)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityLabel("Адрес сайта")
                    Toggle("Включая поддомены", isOn: Binding(get: { rule.match.type == .domainSuffix },
                        set: { rule.match.type = $0 ? .domainSuffix : .domain }))
                        .toggleStyle(.checkbox)
                    if rule.match.value.contains("://"), let value = try? rule.match.normalized() {
                        Text("Правило относится ко всему сайту \(value.value), независимо от страницы.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .ipCIDR:
                    Text("IP-адрес или подсеть").foregroundStyle(.secondary)
                    TextField("10.20.0.0/16 или 2001:db8::/32", text: $rule.match.value)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityLabel("IP-адрес или подсеть")
                case .country:
                    Text("Страна IP-адреса").foregroundStyle(.secondary)
                    Picker("Страна IP-адреса", selection: $rule.match.value) {
                        ForEach(countries, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text("Что делать").foregroundStyle(.secondary)
                Picker("Что делать", selection: $rule.action) {
                    ForEach(RoutingAction.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            if rule.match.type == .country {
                Text("Страна определяется по IP-адресу сайта.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Доменная зона и язык сайта на страну IP-адреса не влияют.")
            }
            HStack(spacing: 10) {
                Toggle("Правило включено", isOn: $rule.enabled).toggleStyle(.switch).labelsHidden()
                Text("Правило включено")
            }
            Spacer(minLength: 0)
            Divider()
            Button(role: .destructive, action: remove) { Text("Удалить правило").foregroundStyle(.red) }
        }
        .controlSize(.regular).padding(20)
    }
}
