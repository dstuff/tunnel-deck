import Foundation

/// One compiler and one ordered rule list for all transports. No user engine JSON is merged into routing.
public enum RoutingConfiguration {
    public static let fakeIPv4Pool = "198.19.0.0/16"
    public static let fakeIPv6Pool = "2001:2::/48"
    public static let resolverAddress = "198.18.0.2"
    // Reserved TCP/443 on td-traffic; keep the runtime dispatcher exception in sync.
    public static let systemProbeAddress = "198.18.0.3"

    public static func make(policy input: RoutingPolicy, trafficPort: UInt16, probePort: UInt16, dnsPort: UInt16,
                            physicalInterface: String, vpnInterface: String? = nil,
                            vpnDNS: [String] = [], directDNS: [String] = [], vpnAddresses: [String]? = nil, xray: XrayConfiguration? = nil,
                            selectedOutbound: String? = nil, resolvedHosts: [String: String] = [:], systemProbePort: UInt16? = nil) throws -> Data {
        let policy = try input.validated()
        let ports = [trafficPort, probePort, dnsPort] + (systemProbePort.map { [$0] } ?? [])
        guard !ports.contains(0), Set(ports).count == ports.count else { throw VPNError("Некорректные локальные порты маршрутизатора.") }
        func checkInterface(_ name: String) throws {
            guard name.range(of: #"\A[a-zA-Z][a-zA-Z0-9]{0,19}\z"#, options: .regularExpression) != nil else { throw VPNError("Некорректный сетевой интерфейс.") }
        }
        try checkInterface(physicalInterface)
        func freedom(_ tag: String, _ interface: String, strategy: String = "UseIP") -> [String: Any] {
            ["tag": tag, "protocol": "freedom", "settings": ["domainStrategy": strategy],
             "streamSettings": ["sockopt": ["interface": interface]]]
        }
        var outbounds: [[String: Any]]
        if let vpnInterface {
            try checkInterface(vpnInterface)
            var strategy = "UseIP"
            if let vpnAddresses {
                let addresses = try vpnAddresses.map(IPNetwork.init)
                let ipv4 = addresses.contains { $0.bytes.count == 4 }
                let ipv6 = addresses.contains { $0.bytes.count == 16 && !($0.bytes[0] == 0xfe && $0.bytes[1] & 0xc0 == 0x80) }
                // AllowedIPs = ::/0 and an automatic link-local address do not
                // supply a usable IPv6 source to an IPv4-only native VPN.
                if ipv4 && !ipv6 { strategy = "ForceIPv4" }
                if ipv6 && !ipv4 { strategy = "ForceIPv6" }
            }
            outbounds = [freedom("td-vpn", vpnInterface, strategy: strategy)]
        }
        else if let xray { outbounds = try xray.routedOutbounds(selected: selectedOutbound, physicalInterface: physicalInterface, resolvedHosts: resolvedHosts) }
        else { throw VPNError("Для маршрутизации не задан VPN-канал.") }
        let remoteResolvers = vpnDNS.filter { IPNetwork.address($0) != nil }
        let localResolvers = directDNS.filter { IPNetwork.address($0) != nil && $0 != resolverAddress }
        let remote = remoteResolvers.isEmpty ? ["1.1.1.1", "8.8.8.8"] : remoteResolvers
        let local = localResolvers.isEmpty ? ["1.1.1.1", "8.8.8.8"] : localResolvers
        let defaultResolvers = policy.defaultAction == .vpn ? remote : local
        outbounds += [freedom("td-direct", physicalInterface), ["tag": "td-block", "protocol": "blackhole"],
                      ["tag": "td-dns-out", "protocol": "dns", "settings": ["address": defaultResolvers[0], "port": 53, "network": "tcp", "nonIPQuery": "skip"],
                       "streamSettings": ["sockopt": ["dialerProxy": policy.defaultAction.outboundTag]]]]
        func socks(_ port: UInt16, _ tag: String) -> [String: Any] {
            ["tag": tag, "listen": "127.0.0.1", "port": Int(port), "protocol": "socks",
             "settings": ["auth": "noauth", "udp": true, "ip": "127.0.0.1"]]
        }
        var traffic = socks(trafficPort, "td-traffic")
        // Chrome may use cached IPs or DoH instead of the system's FakeDNS.
        // Recover visible web names for routing while retaining real target IPs.
        // Xray gives a known FakeDNS identity priority over payload Host/SNI.
        traffic["sniffing"] = ["enabled": true, "destOverride": ["fakedns", "http", "tls", "quic"],
                               "metadataOnly": false, "routeOnly": true]
        var inbounds: [[String: Any]] = [traffic, socks(probePort, "td-probe"),
            ["tag": "td-dns-real", "listen": "127.0.0.1", "port": Int(dnsPort), "protocol": "dokodemo-door",
             "settings": ["address": defaultResolvers[0], "port": 53, "network": "tcp,udp"]]]
        func route(_ tag: String, _ outbound: String) -> [String: Any] { ["type": "field", "inboundTag": [tag], "outboundTag": outbound] }
        var rules = [route("td-probe", "td-vpn"), route("td-dns-real", "td-dns-out"),
                     ["type": "field", "inboundTag": ["td-traffic"], "port": "53", "outboundTag": "td-dns-out"],
                     route("td-dns-vpn", "td-vpn"), route("td-dns-direct", "td-direct")]
        if let systemProbePort {
            inbounds.append(["tag": "td-system-probe", "listen": "127.0.0.1", "port": Int(systemProbePort), "protocol": "dokodemo-door",
                             "settings": ["address": "example.com", "port": 443, "network": "tcp"]])
            outbounds.append(["tag": "td-probe-bridge", "protocol": "freedom", "settings": ["redirect": "127.0.0.1:\(systemProbePort)"],
                              "streamSettings": ["sockopt": ["interface": "lo0"]]])
            rules.insert(route("td-system-probe", "td-vpn"), at: 0)
            rules.insert(["type": "field", "inboundTag": ["td-traffic"], "ip": [systemProbeAddress + "/32"], "port": "443", "outboundTag": "td-probe-bridge"], at: 1)
        }
        for rule in policy.rules where rule.enabled {
            var compiled: [String: Any] = ["type": "field", "inboundTag": ["td-traffic"], "outboundTag": rule.action.outboundTag,
                                            "ruleTag": "td-rule-" + rule.id.uuidString]
            switch rule.match.type {
            // DNS wire names recovered from FakeDNS include the root dot.
            // Xray's routing matcher treats it literally, unlike its DNS matcher.
            case .domain: compiled["domain"] = ["full:" + rule.match.value, "full:" + rule.match.value + "."]
            case .domainSuffix: compiled["domain"] = ["domain:" + rule.match.value, "domain:" + rule.match.value + "."]
            case .ipCIDR: compiled["ip"] = [rule.match.value]
            case .country: compiled["ip"] = ["geoip:" + rule.match.value.lowercased()]
            }
            rules.append(compiled)
        }
        rules.append(route("td-traffic", policy.defaultAction.outboundTag))
        // Fake answers are used only for client queries. Internal country/freedom resolution skips FakeDNS.
        var servers: [[String: Any]] = [["address": "fakedns"]]
        for action in [RoutingAction.direct, .vpn] {
            let domains = policy.rules.filter { $0.enabled && $0.action == action && [.domain, .domainSuffix].contains($0.match.type) }
                .map { ($0.match.type == .domain ? "full:" : "domain:") + $0.match.value }
            if !domains.isEmpty {
                for address in action == .vpn ? remote : local {
                    let host = address.contains(":") ? "[\(address)]" : address
                    servers.append(["address": "tcp://\(host):53", "domains": domains, "skipFallback": true, "tag": "td-dns-" + action.rawValue])
                }
            }
        }
        for address in defaultResolvers {
            let host = address.contains(":") ? "[\(address)]" : address
            servers.append(["address": "tcp://\(host):53", "tag": "td-dns-" + policy.defaultAction.rawValue])
        }
        let result: [String: Any] = ["log": ["loglevel": "warning", "access": "none"], "inbounds": inbounds, "outbounds": outbounds,
            "routing": ["domainStrategy": "IPOnDemand", "rules": rules],
            "dns": ["servers": servers, "disableFallbackIfMatch": true],
            "fakedns": [["ipPool": fakeIPv4Pool, "poolSize": 32768], ["ipPool": fakeIPv6Pool, "poolSize": 32768]]]
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }
}
