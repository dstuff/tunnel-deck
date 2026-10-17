import TunnelLocalization
import Foundation

public enum RoutingAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case vpn, direct, block
    public var id: String { rawValue }
    public var title: String { switch self { case .vpn: return L10n.text("routing.action.vpn"); case .direct: return L10n.text("routing.action.direct"); case .block: return L10n.text("routing.action.block") } }
    public var outboundTag: String { "td-" + rawValue }
    public var symbol: String { switch self { case .vpn: return "lock.shield"; case .direct: return "globe"; case .block: return "nosign" } }
}

public enum RoutingMatchType: String, Codable, CaseIterable, Identifiable, Sendable {
    case domain, domainSuffix, ipCIDR, country
    public var id: String { rawValue }
    public var title: String { switch self { case .domain: return L10n.text("routingpolicy.exact_domain"); case .domainSuffix: return L10n.text("routingpolicy.site_and_subdomains"); case .ipCIDR: return L10n.text("routing.match.network"); case .country: return L10n.text("routing.match.country") } }
    public var symbol: String { switch self { case .domain, .domainSuffix: return "globe"; case .ipCIDR: return "network"; case .country: return "flag" } }
}

public struct RoutingMatch: Codable, Equatable, Sendable {
    // Country tags present in the pinned DB-IP Lite data. ZZ is unknown, never a user-selectable country.
    public static let countryCodes = Set("AD AE AF AG AI AL AM AO AQ AR AS AT AU AW AX AZ BA BB BD BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BV BW BY BZ CA CC CD CF CG CH CI CK CL CM CN CO CR CU CV CW CX CY CZ DE DJ DK DM DO DZ EC EE EG EH ER ES ET FI FJ FK FM FO FR GA GB GD GE GF GG GH GI GL GM GN GP GQ GR GS GT GU GW GY HK HM HN HR HT HU ID IE IL IM IN IO IQ IR IS IT JE JM JO JP KE KG KH KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD ME MF MG MH MK ML MM MN MO MP MQ MR MS MT MU MV MW MX MY MZ NA NC NE NF NG NI NL NO NP NR NU NZ OM PA PE PF PG PH PK PL PM PN PR PS PT PW PY QA RE RO RS RU RW SA SB SC SD SE SG SH SI SJ SK SL SM SN SO SR SS ST SV SX SY SZ TC TD TF TG TH TJ TK TL TM TN TO TR TT TV TW TZ UA UG UM US UY UZ VA VC VE VG VI VN VU WF WS XK YE YT ZA ZM ZW".split(separator: " ").map(String.init))
    public var type: RoutingMatchType
    public var value: String
    public init(type: RoutingMatchType = .domainSuffix, value: String = "") { self.type = type; self.value = value }

    public func normalized() throws -> RoutingMatch {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 1024 else { throw VPNError(L10n.message("routingpolicy.the_rule_condition_is_too_long")) }
        switch type {
        case .domain, .domainSuffix: value = try Self.domain(value)
        case .ipCIDR: value = try IPNetwork(value).cidr
        case .country:
            value = value.uppercased()
            guard Self.countryCodes.contains(value) else { throw VPNError(L10n.message("routingpolicy.choose_a_country_from_the_list")) }
        }
        return .init(type: type, value: value)
    }

    public static func domain(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("://") {
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, let host = url.host else { throw VPNError(L10n.message("routingpolicy.paste_a_domain_or_an_http_s_website_address")) }
            value = host
        }
        value = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Foundation's URL host serialisation normalises internationalised domains to ASCII.
        guard let url = URL(string: "https://" + value + "/"), let host = url.host, IPNetwork.address(host) == nil,
              !value.contains(where: { $0.isWhitespace || "/:@?#*\\".contains($0) }), !value.isEmpty else {
            throw VPNError(L10n.message("routingpolicy.enter_a_website_domain_such_as_example_org_for"))
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw VPNError(L10n.message("routingpolicy.invalid_website_domain")) }
        return host
    }

    public var displayValue: String {
        displayMessage.resolve()
    }
    public var displayMessage: LocalizedMessage {
        type == .country ? L10n.message("routing.country_name", [.region(value.uppercased())]) : .verbatim(value)
    }
}

public struct RoutingRule: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var match: RoutingMatch
    public var action: RoutingAction
    public var enabled: Bool
    public init(id: UUID = UUID(), match: RoutingMatch = .init(), action: RoutingAction = .vpn, enabled: Bool = true) {
        self.id = id; self.match = match; self.action = action; self.enabled = enabled
    }
    private enum CodingKeys: String, CodingKey { case id, match, action, enabled }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        match = try c.decode(RoutingMatch.self, forKey: .match)
        action = try c.decode(RoutingAction.self, forKey: .action)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}

public struct RoutingPolicy: Codable, Equatable, Sendable {
    public static let maximumFileSize = 128_000
    public static let maximumRules = 1000
    public var format = "tunneldeck-routing"
    public var version = 1
    public var name = L10n.text("routing.default_name")
    public var defaultAction: RoutingAction = .vpn
    public var rules: [RoutingRule] = []
    public init() {}

    public func validated() throws -> RoutingPolicy {
        guard format == "tunneldeck-routing", version == 1 else { throw VPNError(L10n.message("routingpolicy.this_routing_format_is_not_supported_a_tunneldeck_version")) }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200 else { throw VPNError(L10n.message("routingpolicy.enter_a_policy_name_of_up_to_200_bytes")) }
        guard defaultAction != .block else { throw VPNError(L10n.message("routingpolicy.for_all_other_traffic_choose_through_vpn_or_without")) }
        guard rules.count <= Self.maximumRules, Set(rules.map(\.id)).count == rules.count else { throw VPNError(L10n.message("routingpolicy.too_many_rules_or_duplicate_identifiers")) }
        var policy = self
        for index in rules.indices {
            do { policy.rules[index].match = try rules[index].match.normalized() }
            catch { throw VPNError(L10n.message("routingpolicy.rule", [.init(index + 1), .init(error.localizedMessage)])) }
        }
        guard try JSONEncoder().encode(policy).count <= Self.maximumFileSize else { throw VPNError(L10n.message("routingpolicy.the_routing_policy_is_too_large")) }
        return policy
    }

    public static func importFile(_ data: Data) throws -> RoutingPolicy {
        guard data.count <= maximumFileSize else { throw VPNError(L10n.message("routingpolicy.the_routing_file_exceeds_128_kb")) }
        // A share file is an allowlisted public document, never a profile/engine dump.
        func check(_ object: [String: Any], allowed: Set<String>) throws {
            guard Set(object.keys).isSubset(of: allowed) else { throw VPNError(L10n.message("routingpolicy.the_file_contains_unsupported_fields_nothing_was_imported")) }
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VPNError(L10n.message("routingpolicy.a_tunneldeck_routing_json_file_is_required")) }
            try check(root, allowed: ["format", "version", "name", "defaultAction", "rules"])
            for rule in root["rules"] as? [[String: Any]] ?? [] {
                try check(rule, allowed: ["id", "match", "action", "enabled"])
                if let match = rule["match"] as? [String: Any] { try check(match, allowed: ["type", "value"]) }
            }
            return try JSONDecoder().decode(RoutingPolicy.self, from: data).validated()
        } catch let error as VPNError { throw error }
        catch { throw VPNError(L10n.message("routingpolicy.the_routing_file_is_damaged_or_contains_unsupported_conditions")) }
    }

    public func exportFile() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(validated())
        guard data.count <= Self.maximumFileSize else { throw VPNError(L10n.message("routingpolicy.the_routing_file_exceeds_128_kb")) }
        return data
    }

    public struct Decision: Equatable, Sendable {
        public let action: RoutingAction
        public let ruleIndex: Int?
        public let matchedIP: String?
    }
    public func decision(domain: String?, addresses: [String], country: (String) -> String?) throws -> Decision {
        let policy = try validated()
        let host = try domain.map { try RoutingMatch.domain($0) }
        for (index, rule) in policy.rules.enumerated() where rule.enabled {
            var matchedIP: String?
            let matches: Bool
            switch rule.match.type {
            case .domain: matches = host == rule.match.value
            case .domainSuffix: matches = host == rule.match.value || host?.hasSuffix("." + rule.match.value) == true
            case .ipCIDR:
                let network = try IPNetwork(rule.match.value)
                matchedIP = addresses.first(where: network.contains); matches = matchedIP != nil
            case .country:
                matchedIP = addresses.first { country($0) == rule.match.value }; matches = matchedIP != nil
            }
            if matches { return Decision(action: rule.action, ruleIndex: index, matchedIP: matchedIP) }
        }
        return Decision(action: policy.defaultAction, ruleIndex: nil, matchedIP: nil)
    }
}

public struct RoutingRuntimeInfo: Codable, Equatable, Sendable {
    public var probePort: UInt16
    public var dnsPort: UInt16
    public init(probePort: UInt16, dnsPort: UInt16) { self.probePort = probePort; self.dnsPort = dnsPort }
}
