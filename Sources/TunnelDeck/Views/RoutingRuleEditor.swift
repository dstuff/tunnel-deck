import TunnelLocalization
import SwiftUI
import TunnelCore

struct RoutingRuleEditor: View {
    @Binding var rule: RoutingRule
    let number: Int
    let remove: () -> Void
    private enum Category: String, CaseIterable {
        case site, network, country
        var title: String {
            switch self {
            case .site: return L10n.text("routing.category.site")
            case .network: return L10n.text("routing.match.network")
            case .country: return L10n.text("routing.category.country")
            }
        }
    }
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
            ($0, L10n.language.locale.localizedString(forRegionCode: $0) ?? $0)
        }.sorted { $0.1.compare($1.1, options: [.numeric, .caseInsensitive], locale: L10n.language.locale) == .orderedAscending }
    }
    private var validationError: String? {
        do { _ = try rule.match.normalized(); return nil } catch { return error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.text("routingruleeditor.rule", [.init(number)])).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("routingruleeditor.what_to_match")).foregroundStyle(.secondary)
                Picker(L10n.text("routingruleeditor.what_to_match"), selection: category) {
                    ForEach(Category.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: 9) {
                switch rule.match.type {
                case .domain, .domainSuffix:
                    Text(L10n.text("routing.category.site")).foregroundStyle(.secondary)
                    TextField(L10n.text("routingruleeditor.example_org_or_https_example_org_page"), text: $rule.match.value)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityLabel(L10n.text("routingruleeditor.website_address"))
                    Toggle(L10n.text("routingruleeditor.include_subdomains"), isOn: Binding(get: { rule.match.type == .domainSuffix },
                        set: { rule.match.type = $0 ? .domainSuffix : .domain }))
                        .toggleStyle(.checkbox)
                    if rule.match.value.contains("://"), let value = try? rule.match.normalized() {
                        Text(L10n.text("routingruleeditor.the_rule_applies_to_the_entire_site_regardless_of", [.init(value.value)]))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                case .ipCIDR:
                    Text(L10n.text("routingruleeditor.ip_address_or_subnet")).foregroundStyle(.secondary)
                    TextField(L10n.text("routingruleeditor.10_20_0_0_16_or_2001_db8_32"), text: $rule.match.value)
                        .textFieldStyle(.roundedBorder).autocorrectionDisabled().accessibilityLabel(L10n.text("routingruleeditor.ip_address_or_subnet"))
                case .country:
                    Text(L10n.text("routing.match.country")).foregroundStyle(.secondary)
                    Picker(L10n.text("routing.match.country"), selection: $rule.match.value) {
                        ForEach(countries, id: \.0) { Text($0.1).tag($0.0) }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
                }
                if let validationError {
                    Label(validationError, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                Text(L10n.text("routingruleeditor.action")).foregroundStyle(.secondary)
                Picker(L10n.text("routingruleeditor.action"), selection: $rule.action) {
                    ForEach(RoutingAction.allCases) { Text($0.title).tag($0) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            if rule.match.type == .country {
                Text(L10n.text("routingruleeditor.the_country_is_determined_by_the_website_ip_address"))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help(L10n.text("routingruleeditor.the_domain_suffix_and_website_language_do_not_affect"))
            }
            HStack(spacing: 10) {
                Toggle(L10n.text("routingruleeditor.rule_enabled"), isOn: $rule.enabled).toggleStyle(.switch).labelsHidden()
                Text(L10n.text("routingruleeditor.rule_enabled"))
            }
            Spacer(minLength: 0)
            Divider()
            Button(role: .destructive, action: remove) { Text(L10n.text("routingruleeditor.delete_rule")).foregroundStyle(.red) }
        }
        .controlSize(.regular).padding(20)
    }
}
