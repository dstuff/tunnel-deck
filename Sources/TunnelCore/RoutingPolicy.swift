import Foundation

public enum RoutingAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case vpn, direct, block
    public var id: String { rawValue }
    public var title: String { switch self { case .vpn: return "Через VPN"; case .direct: return "Без VPN"; case .block: return "Блокировать" } }
    public var outboundTag: String { "td-" + rawValue }
    public var symbol: String { switch self { case .vpn: return "lock.shield"; case .direct: return "globe"; case .block: return "nosign" } }
}

public enum RoutingMatchType: String, Codable, CaseIterable, Identifiable, Sendable {
    case domain, domainSuffix, ipCIDR, country
    public var id: String { rawValue }
    public var title: String { switch self { case .domain: return "Точный домен"; case .domainSuffix: return "Сайт и поддомены"; case .ipCIDR: return "IP или сеть"; case .country: return "Страна IP-адреса" } }
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
        guard value.utf8.count <= 1024 else { throw VPNError("Условие правила слишком длинное.") }
        switch type {
        case .domain, .domainSuffix: value = try Self.domain(value)
        case .ipCIDR: value = try IPNetwork(value).cidr
        case .country:
            value = value.uppercased()
            guard Self.countryCodes.contains(value) else { throw VPNError("Выберите страну из списка.") }
        }
        return .init(type: type, value: value)
    }

    public static func domain(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.contains("://") {
            guard let url = URLComponents(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.user == nil, url.password == nil, let host = url.host else { throw VPNError("Вставьте домен или HTTP(S)-адрес сайта.") }
            value = host
        }
        value = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        // Foundation's URL host serialisation normalises internationalised domains to ASCII.
        guard let url = URL(string: "https://" + value + "/"), let host = url.host, IPNetwork.address(host) == nil,
              !value.contains(where: { $0.isWhitespace || "/:@?#*\\".contains($0) }), !value.isEmpty else {
            throw VPNError("Введите домен сайта, например example.org. Для IP выберите «IP или сеть».")
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.allSatisfy({ label in
            !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-" &&
            label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }) else { throw VPNError("Некорректное имя сайта.") }
        return host
    }

    public var displayValue: String {
        type == .country ? Locale(identifier: "ru_RU").localizedString(forRegionCode: value.uppercased()) ?? value : value
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
    public var name = "Мои правила"
    public var defaultAction: RoutingAction = .vpn
    public var rules: [RoutingRule] = []
    public init() {}

    public func validated() throws -> RoutingPolicy {
        guard format == "tunneldeck-routing", version == 1 else { throw VPNError("Этот формат маршрутизации не поддерживается. Нужен файл TunnelDeck версии 1.") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 200 else { throw VPNError("Укажите название схемы длиной до 200 байт.") }
        guard defaultAction != .block else { throw VPNError("Для остального интернета выберите «Через VPN» или «Без VPN».") }
        guard rules.count <= Self.maximumRules, Set(rules.map(\.id)).count == rules.count else { throw VPNError("Слишком много правил или повторяющиеся идентификаторы.") }
        var policy = self
        for index in rules.indices {
            do { policy.rules[index].match = try rules[index].match.normalized() }
            catch { throw VPNError("Правило \(index + 1): \(error.localizedDescription)") }
        }
        guard try JSONEncoder().encode(policy).count <= Self.maximumFileSize else { throw VPNError("Схема маршрутизации слишком большая.") }
        return policy
    }

    public static func importFile(_ data: Data) throws -> RoutingPolicy {
        guard data.count <= maximumFileSize else { throw VPNError("Файл маршрутизации превышает 128 КБ.") }
        // A share file is an allowlisted public document, never a profile/engine dump.
        func check(_ object: [String: Any], allowed: Set<String>) throws {
            guard Set(object.keys).isSubset(of: allowed) else { throw VPNError("В файле есть неподдерживаемые поля. Импорт отменён целиком.") }
        }
        do {
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw VPNError("Нужен JSON-файл маршрутизации TunnelDeck.") }
            try check(root, allowed: ["format", "version", "name", "defaultAction", "rules"])
            for rule in root["rules"] as? [[String: Any]] ?? [] {
                try check(rule, allowed: ["id", "match", "action", "enabled"])
                if let match = rule["match"] as? [String: Any] { try check(match, allowed: ["type", "value"]) }
            }
            return try JSONDecoder().decode(RoutingPolicy.self, from: data).validated()
        } catch let error as VPNError { throw error }
        catch { throw VPNError("Файл маршрутизации повреждён или содержит неподдерживаемые условия и действия.") }
    }

    public func exportFile() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(validated())
        guard data.count <= Self.maximumFileSize else { throw VPNError("Файл маршрутизации превышает 128 КБ.") }
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
