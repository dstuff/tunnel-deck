import TunnelLocalization
import Foundation
import Darwin

public struct AmneziaConfiguration: Sendable {
    public let deviceConfiguration: String
    public let addresses: [String]
    public let dns: [String]
    public let allowedIPs: [String]
    public let endpointHosts: [String]
    public let mtu: Int
    public let routesEnabled: Bool

    public init(_ text: String) throws {
        guard text.utf8.count < 256_000 else { throw VPNError(L10n.message("amneziaconfiguration.the_awg_configuration_is_too_large")) }
        var section = "", stripped: [String] = [], addresses: [String] = [], dns: [String] = []
        var allowed: [String] = [], endpoints: [String] = [], fields: [String: String] = [:]
        var peers = 0, peerHasKey = false, privateKey = false, mtu = 1420, routes = true
        let interfaceFields = Set(["privatekey", "listenport", "fwmark", "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4", "i1", "i2", "i3", "i4", "i5", "headerprotectionkey", "contentpaddingaddition", "rekeyaftertime", "rekeytimeout", "rejectaftertime", "keepalivetimeout", "maxhandshakeattempts", "randomtrailers", "disablecookies"])
        let peerFields = Set(["publickey", "presharedkey", "endpoint", "allowedips", "persistentkeepalive"])
        for raw in text.components(separatedBy: .newlines) {
            let line = String(raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]).trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == "[Interface]" || line == "[Peer]" {
                if section == "[Peer]" && !peerHasKey { throw VPNError(L10n.message("amneziaconfiguration.a_peer_is_missing_publickey")) }
                section = line
                if section == "[Peer]" { peers += 1; peerHasKey = false }
                stripped.append(line); continue
            }
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { throw VPNError(L10n.message("amneziaconfiguration.invalid_awg_configuration_line")) }
            let key = pair[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = pair[1].trimmingCharacters(in: .whitespaces)
            guard !value.contains("\0"), !section.isEmpty else { throw VPNError(L10n.message("amneziaconfiguration.invalid_awg_configuration")) }
            if ["preup", "postup", "predown", "postdown", "saveconfig"].contains(key) {
                throw VPNError(L10n.message("amneziaconfiguration.configurations_with_preup_postup_predown_postdown_commands_or_saveconfig"))
            }
            if section == "[Interface]" {
                switch key {
                case "address": addresses += Self.list(value); continue
                case "dns": dns += Self.list(value); continue
                case "mtu":
                    guard let n = Int(value), (1280...9000).contains(n) else { throw VPNError(L10n.message("amneziaconfiguration.mtu_must_be_between_1280_and_9000")) }
                    mtu = n; continue
                case "table":
                    guard ["auto", "off"].contains(value) else { throw VPNError(L10n.message("amneziaconfiguration.table_auto_and_table_off_are_supported")) }
                    routes = value != "off"; continue
                default:
                    guard interfaceFields.contains(key) else { throw VPNError(L10n.message("amneziaconfiguration.unknown_awg_field", [.init(key)])) }
                    fields[key] = value
                    if key == "privatekey" { privateKey = Self.validKey(value) }
                }
            } else {
                guard peerFields.contains(key) else { throw VPNError(L10n.message("amneziaconfiguration.unknown_peer_field", [.init(key)])) }
                if key == "publickey" { peerHasKey = Self.validKey(value) }
                if key == "presharedkey" && !Self.validKey(value) { throw VPNError(L10n.message("amneziaconfiguration.presharedkey_must_contain_a_32_byte_key")) }
                if key == "allowedips" { allowed += Self.list(value) }
                if key == "endpoint" {
                    guard let parts = URLComponents(string: "udp://" + value), let host = parts.host,
                          let port = parts.port, (1...65535).contains(port), parts.user == nil,
                          parts.path.isEmpty, parts.query == nil, parts.fragment == nil else { throw VPNError(L10n.message("amneziaconfiguration.check_the_peer_endpoint")) }
                    endpoints.append(host)
                }
            }
            stripped.append(line)
        }
        guard privateKey, peers > 0, peerHasKey, !addresses.isEmpty, !endpoints.isEmpty else {
            throw VPNError(L10n.message("amneziaconfiguration.awg_requires_privatekey_address_and_a_peer_with_publickey"))
        }
        guard (addresses + allowed).allSatisfy(Self.validCIDR), dns.allSatisfy(Self.validIP) else {
            throw VPNError(L10n.message("amneziaconfiguration.check_the_ip_addresses_prefixes_and_dns_in_the"))
        }
        if let key = fields["headerprotectionkey"], key != "(off)", !key.isEmpty {
            guard Self.validKey(key) else { throw VPNError(L10n.message("amneziaconfiguration.headerprotectionkey_must_contain_a_32_byte_key")) }
            for s in ["s1", "s2", "s3", "s4"] {
                guard let n = Int(fields[s] ?? ""), n >= 12 else { throw VPNError(L10n.message("amneziaconfiguration.with_headerprotectionkey_s1_s4_must_be_at_least_12")) }
            }
        }
        self.deviceConfiguration = stripped.joined(separator: "\n") + "\n"
        self.addresses = addresses; self.dns = dns; self.allowedIPs = allowed
        self.endpointHosts = endpoints; self.mtu = mtu; self.routesEnabled = routes
    }
    public static func validIP(_ value: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, value, &v4) == 1 || inet_pton(AF_INET6, value, &v6) == 1
    }
    public static func validCIDR(_ value: String) -> Bool {
        let p = value.split(separator: "/", omittingEmptySubsequences: false)
        guard p.count == 2, validIP(String(p[0])), let bits = Int(p[1]) else { return false }
        return (0...(p[0].contains(":") ? 128 : 32)).contains(bits)
    }
    static func validKey(_ value: String) -> Bool { Data(base64Encoded: value)?.count == 32 }
    static func list(_ text: String) -> [String] { text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
}
