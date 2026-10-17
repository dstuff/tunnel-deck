import TunnelLocalization
import Foundation

/// Only allowlisted numeric network metadata crosses the OpenConnect script boundary.
public struct OpenConnectNetworkSettings: Codable, Equatable, Sendable {
    public let id: UUID
    public let reason: String
    public var interface: String
    public var addresses: [String]
    public var dns: [String]
    public var routes: [String]
    public var excludedRoutes: [String]
    public var gateway: String?
    public var mtu: Int

    public init(environment env: [String: String]) throws {
        id = UUID(); reason = env["reason"] ?? ""
        guard ["connect", "reconnect", "attempt-reconnect", "disconnect", "pre-init"].contains(reason) else { throw VPNError(L10n.message("openconnectnetworksettings.unknown_openconnect_network_event")) }
        interface = env["TUNDEV"] ?? ""
        addresses = []; dns = []; routes = []; excludedRoutes = []; gateway = nil; mtu = 1400
        guard reason == "connect" || reason == "reconnect" else { return }
        guard interface.range(of: #"\Autun[0-9]{1,4}\z"#, options: .regularExpression) != nil else { throw VPNError(L10n.message("openconnectnetworksettings.openconnect_provided_an_invalid_interface_name")) }
        if let ip = env["INTERNAL_IP4_ADDRESS"], !ip.isEmpty {
            guard IPNetwork.address(ip)?.count == 4 else { throw VPNError(L10n.message("openconnectnetworksettings.invalid_openconnect_ipv4_address")) }
            let prefix = try env["INTERNAL_IP4_NETMASK"].map { try IPNetwork.prefixLength(netmask: $0) } ?? 32
            addresses.append("\(ip)/\(prefix)")
        }
        if let ip = env["INTERNAL_IP6_ADDRESS"], !ip.isEmpty {
            let mask = env["INTERNAL_IP6_NETMASK"]?.split(separator: "/").last.flatMap { Int($0) } ?? 128
            guard IPNetwork.address(ip)?.count == 16, (0...128).contains(mask) else { throw VPNError(L10n.message("openconnectnetworksettings.invalid_openconnect_ipv6_address")) }
            addresses.append("\(ip)/\(mask)")
        }
        guard !addresses.isEmpty else { throw VPNError(L10n.message("openconnectnetworksettings.openconnect_did_not_provide_an_interface_address")) }
        if let value = env["INTERNAL_IP4_MTU"] {
            guard let n = Int(value), (576...9000).contains(n) else { throw VPNError(L10n.message("openconnectnetworksettings.invalid_openconnect_mtu")) }
            mtu = n
        }
        dns = (env["INTERNAL_IP4_DNS"] ?? "").split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard dns.count <= 16, dns.allSatisfy({ IPNetwork.address($0) != nil }) else { throw VPNError(L10n.message("openconnectnetworksettings.openconnect_provided_invalid_dns_servers")) }
        if let ip = env["VPNGATEWAY"], IPNetwork.address(ip) != nil { gateway = ip }
        func parse(_ name: String, ipv6: Bool) throws -> [String] {
            guard let raw = env[name] else { return [] }
            guard let count = Int(raw), (0...256).contains(count) else { throw VPNError(L10n.message("openconnectnetworksettings.too_many_openconnect_routes")) }
            return try (0..<count).map { index in
                let key = "\(name)_\(index)_"
                guard let address = env[key + "ADDR"], let prefix = env[key + "MASKLEN"],
                      IPNetwork.address(address)?.count == (ipv6 ? 16 : 4) else { throw VPNError(L10n.message("openconnectnetworksettings.invalid_openconnect_route")) }
                return try IPNetwork(address + "/" + prefix).cidr
            }
        }
        routes = try parse("CISCO_SPLIT_INC", ipv6: false) + parse("CISCO_IPV6_SPLIT_INC", ipv6: true)
        if env["CISCO_SPLIT_INC"] == nil, addresses.contains(where: { !$0.contains(":") }) { routes.append("0.0.0.0/0") }
        if env["CISCO_IPV6_SPLIT_INC"] == nil, addresses.contains(where: { $0.contains(":") }) { routes.append("::/0") }
        excludedRoutes = try parse("CISCO_SPLIT_EXC", ipv6: false) + parse("CISCO_IPV6_SPLIT_EXC", ipv6: true)
    }
}
