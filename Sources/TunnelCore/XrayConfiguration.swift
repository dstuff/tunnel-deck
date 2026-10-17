import TunnelLocalization
import Foundation

public struct XrayConfiguration {
    private let configuration: [String: Any]
    public let displayName: String?

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count < 256_000 else { throw VPNError(L10n.message("xrayconfiguration.the_xray_configuration_is_too_large")) }
        if text.hasPrefix("vless://") || text.hasPrefix("trojan://") {
            let imported = try Self.importLink(text)
            configuration = ["outbounds": [imported.outbound]]; displayName = imported.name
        } else {
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VPNError(L10n.message("xrayconfiguration.paste_xray_json_or_a_vless_trojan_link"))
            }
            configuration = json["protocol"] != nil ? ["outbounds": [json]] : json
            displayName = nil
        }
        guard let outbounds = configuration["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw VPNError(L10n.message("xrayconfiguration.the_xray_configuration_has_no_outbounds"))
        }
        let supported = Set(["vless", "vmess", "trojan", "shadowsocks", "socks", "http", "freedom", "blackhole", "dns", "wireguard", "hysteria"])
        for outbound in outbounds {
            guard let p = outbound["protocol"] as? String, supported.contains(p) else { throw VPNError(L10n.message("xrayconfiguration.unsupported_xray_outbound_type")) }
        }
        try Self.rejectFileAccess(configuration)
    }

    public var endpointHosts: [String] {
        Self.endpointHosts(in: configuration["outbounds"] as? [[String: Any]] ?? [])
    }

    /// Bootstrap only the chosen chain; an unused server must not prevent connection.
    public func endpointHosts(selected: String?) throws -> [String] {
        Self.endpointHosts(in: try routedOutbounds(selected: selected, physicalInterface: "", resolvedHosts: [:]))
    }

    private static func endpointHosts(in outbounds: [[String: Any]]) -> [String] {
        outbounds.flatMap { outbound -> [String] in
            let settings = outbound["settings"] as? [String: Any] ?? [:]
            var hosts = ["vnext", "servers"].flatMap { key in
                (settings[key] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
            }
            if outbound["protocol"] as? String == "hysteria", let host = settings["address"] as? String { hosts.append(host) }
            if outbound["protocol"] as? String == "wireguard" {
                hosts += (settings["peers"] as? [[String: Any]] ?? []).compactMap { peer in
                    guard let endpoint = peer["endpoint"] as? String else { return nil }
                    return URLComponents(string: "udp://" + endpoint)?.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                }
            }
            return hosts
        }
    }

    public struct OutboundChoice: Identifiable, Equatable, Sendable {
        public let tag: String
        public let title: String
        public var id: String { tag }
    }
    public var outboundChoices: [OutboundChoice] {
        (configuration["outbounds"] as? [[String: Any]] ?? []).enumerated().compactMap { index, item in
            guard let proto = item["protocol"] as? String, !["freedom", "blackhole", "dns"].contains(proto) else { return nil }
            let tag = item["tag"] as? String ?? "outbound-\(index + 1)"
            return .init(tag: tag, title: "\(tag) · \(proto)")
        }
    }
    public func selectedOutboundTag(_ selected: String?) throws -> String {
        if let selected, outboundChoices.contains(where: { $0.tag == selected }) { return selected }
        guard outboundChoices.count == 1, let only = outboundChoices.first else {
            throw VPNError(outboundChoices.isEmpty ? L10n.message("xrayconfiguration.xray_has_no_server_connection_for_the_through_vpn") : L10n.message("xrayconfiguration.the_configuration_has_multiple_xray_servers_choose_the_primary"))
        }
        return only.tag
    }

    /// Extract only the chosen transport and its explicit dialer dependencies. Imported routing never runs here.
    public func routedOutbounds(selected: String?, physicalInterface: String, resolvedHosts: [String: String]) throws -> [[String: Any]] {
        let selected = try selectedOutboundTag(selected)
        let generated = try JSONSerialization.jsonObject(with: proxyData(port: 1, physicalInterface: physicalInterface, resolvedHosts: resolvedHosts)) as! [String: Any]
        let source = generated["outbounds"] as! [[String: Any]]
        let tags = source.enumerated().map { $0.element["tag"] as? String ?? "outbound-\($0.offset + 1)" }
        guard Set(tags).count == tags.count else { throw VPNError(L10n.message("xrayconfiguration.xray_outbound_names_must_be_unique")) }
        var included = Set<Int>(), visiting = Set<Int>()
        func dependency(_ item: [String: Any]) -> String? {
            let stream = item["streamSettings"] as? [String: Any] ?? [:]
            return (stream["sockopt"] as? [String: Any])?["dialerProxy"] as? String ?? (item["proxySettings"] as? [String: Any])?["tag"] as? String
        }
        func visit(_ tag: String) throws {
            guard let index = tags.firstIndex(of: tag), !visiting.contains(index) else { throw VPNError(L10n.message("xrayconfiguration.the_xray_chain_contains_a_cycle_or_an_unknown")) }
            if included.contains(index) { return }
            visiting.insert(index)
            if let next = dependency(source[index]), !next.isEmpty { try visit(next) }
            visiting.remove(index); included.insert(index)
        }
        try visit(selected)
        let mapped = Dictionary(uniqueKeysWithValues: included.map { (tags[$0], tags[$0] == selected ? "td-vpn" : "td-source-\($0)") })
        return included.sorted().map { index in
            var item = source[index]
            item["tag"] = mapped[tags[index]]!
            var stream = item["streamSettings"] as? [String: Any] ?? [:]
            var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
            if let tag = sockopt["dialerProxy"] as? String { sockopt["dialerProxy"] = mapped[tag] }
            else { sockopt["interface"] = physicalInterface }
            if var proxy = item["proxySettings"] as? [String: Any], let tag = proxy["tag"] as? String { proxy["tag"] = mapped[tag]; item["proxySettings"] = proxy }
            stream["sockopt"] = sockopt; item["streamSettings"] = stream
            var settings = item["settings"] as? [String: Any] ?? [:]
            if let host = settings["address"] as? String, let ip = resolvedHosts[host] {
                settings["address"] = ip
                let key = stream["security"] as? String == "reality" ? "realitySettings" : "tlsSettings"
                var tls = stream[key] as? [String: Any] ?? [:]
                if (tls["serverName"] as? String ?? "").isEmpty { tls["serverName"] = host }
                stream[key] = tls; item["streamSettings"] = stream
            }
            if let peers = settings["peers"] as? [[String: Any]] {
                settings["peers"] = peers.map { original -> [String: Any] in
                    var peer = original
                    if let endpoint = peer["endpoint"] as? String, let c = URLComponents(string: "udp://" + endpoint),
                       let host = c.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), let ip = resolvedHosts[host], let port = c.port {
                        peer["endpoint"] = (ip.contains(":") ? "[\(ip)]" : ip) + ":\(port)"
                    }
                    return peer
                }
            }
            item["settings"] = settings
            return item
        }
    }

    public func endpointRouteAddresses(resolvedHosts: [String: String]) -> [String] {
        // Literal IP endpoints need the same tunnel bypass as resolved hostnames.
        endpointHosts.map { resolvedHosts[$0] ?? $0 }
    }

    public var usesVisionCompatibilityTLS: Bool {
        (configuration["outbounds"] as? [[String: Any]] ?? []).contains(where: Self.isVisionCompatibility)
    }

    private static func isVisionCompatibility(_ outbound: [String: Any]) -> Bool {
        guard outbound["protocol"] as? String == "vless",
              let stream = outbound["streamSettings"] as? [String: Any],
              stream["security"] as? String == "reality" else { return false }
        let reality = stream["realitySettings"] as? [String: Any] ?? [:]
        let preset = reality["fingerprint"] as? String ?? ""
        guard ["", "chrome", "safari", "safari15_5", "tunneldeck_safari15_5"].contains(preset) else { return false }
        let settings = outbound["settings"] as? [String: Any] ?? [:]
        return (settings["vnext"] as? [[String: Any]] ?? []).contains { server in
            (server["users"] as? [[String: Any]] ?? []).contains {
                ($0["flow"] as? String ?? "").hasPrefix("xtls-rprx-vision")
            }
        }
    }

    public func probeData(port: UInt16, physicalInterface: String? = nil) throws -> Data {
        try data(physicalInterface: physicalInterface, probePort: port)
    }
    public func selectedProbeData(port: UInt16, selected: String?, physicalInterface: String = "") throws -> Data {
        let result: [String: Any] = ["log": ["loglevel": "warning", "access": "none"],
            "inbounds": [["tag": "td-probe", "listen": "127.0.0.1", "port": Int(port), "protocol": "socks", "settings": ["auth": "noauth"]]],
            "outbounds": try routedOutbounds(selected: selected, physicalInterface: physicalInterface, resolvedHosts: [:]),
            "routing": ["rules": [["type": "field", "inboundTag": ["td-probe"], "outboundTag": "td-vpn"]]]]
        return try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
    }

    public func proxyData(port: UInt16, physicalInterface: String, resolvedHosts: [String: String]) throws -> Data {
        try data(physicalInterface: physicalInterface, resolvedHosts: resolvedHosts, probePort: port, socksUDP: true)
    }

    public func data(tunnelInterface: String? = nil, physicalInterface: String? = nil, resolvedHosts: [String: String] = [:], probePort: UInt16? = nil, socksUDP: Bool = false) throws -> Data {
        var result: [String: Any] = ["log": ["loglevel": "warning"]]
        for key in ["outbounds", "routing", "dns", "policy"] { result[key] = configuration[key] }
        result["outbounds"] = (configuration["outbounds"] as? [[String: Any]] ?? []).map { original in
            guard Self.isVisionCompatibility(original) else { return original }
            var outbound = original
            var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
            var reality = stream["realitySettings"] as? [String: Any] ?? [:]
            // The pinned core patch recreates the observed Safari15_5 settings:
            // ordinary X25519, no ALPN, and a single RSA-PSS/SHA384 entry.
            reality["fingerprint"] = "tunneldeck_safari15_5"
            stream["realitySettings"] = reality; outbound["streamSettings"] = stream
            return outbound
        }
        if let physicalInterface {
            result["outbounds"] = (result["outbounds"] as? [[String: Any]] ?? []).map { outbound in
                var outbound = outbound
                var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
                var sockopt = stream["sockopt"] as? [String: Any] ?? [:]
                var settings = outbound["settings"] as? [String: Any] ?? [:]
                let routedServers = ["vnext", "servers"].flatMap { settings[$0] as? [[String: Any]] ?? [] }
                    .compactMap { $0["address"] as? String }
                if routedServers.isEmpty {
                    // Direct outbounds still need to escape the default TUN routes.
                    sockopt["interface"] = physicalInterface
                }
                for key in ["vnext", "servers"] {
                    if let servers = settings[key] as? [[String: Any]] {
                        settings[key] = servers.map { server -> [String: Any] in
                            var server = server
                            if let original = server["address"] as? String, let ip = resolvedHosts[original] {
                                server["address"] = ip
                                let securityKey = stream["security"] as? String == "reality" ? "realitySettings" : "tlsSettings"
                                if stream["security"] as? String != "none" {
                                    var tls = stream[securityKey] as? [String: Any] ?? [:]
                                    if (tls["serverName"] as? String ?? "").isEmpty { tls["serverName"] = original }
                                    stream[securityKey] = tls
                                }
                            }
                            return server
                        }
                    }
                }
                outbound["settings"] = settings
                stream["sockopt"] = sockopt; outbound["streamSettings"] = stream
                return outbound
            }
        }
        if let tunnelInterface {
            result["log"] = ["loglevel": "info", "access": "none"]
            result["inbounds"] = [["tag": "tunneldeck", "protocol": "tun", "settings": ["name": tunnelInterface, "mtu": 1400]]]
        } else { result["inbounds"] = [] as [String] }
        if let probePort {
            result["log"] = ["loglevel": socksUDP ? "warning" : "info", "access": "none"]
            var inbounds = result["inbounds"] as? [[String: Any]] ?? []
            let probeTag = tunnelInterface == nil ? "tunneldeck" : "tunneldeck-probe"
            inbounds.append(["tag": probeTag, "listen": "127.0.0.1", "port": Int(probePort),
                             "protocol": "socks", "settings": ["auth": "noauth", "udp": socksUDP, "ip": "127.0.0.1"]])
            result["inbounds"] = inbounds
            if tunnelInterface != nil, var routing = result["routing"] as? [String: Any],
               let rules = routing["rules"] as? [[String: Any]] {
                routing["rules"] = rules.map { rule in
                    var rule = rule
                    if var tags = rule["inboundTag"] as? [String], tags.contains("tunneldeck") {
                        tags.append(probeTag); rule["inboundTag"] = tags
                    }
                    return rule
                }
                result["routing"] = routing
            }
        }
        return try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    }

    private static func rejectFileAccess(_ value: Any) throws {
        if let dictionary = value as? [String: Any] {
            let forbidden = Set(["certificatefile", "keyfile", "masterkeylog", "keylog", "lua", "luascript", "file", "filename"])
            for (key, value) in dictionary {
                if forbidden.contains(key.lowercased()) { throw VPNError(L10n.message("xrayconfiguration.xray_external_files_and_scripts_in_imported_configurations_are")) }
                try rejectFileAccess(value)
            }
        } else if let array = value as? [Any] { for value in array { try rejectFileAccess(value) } }
    }

    private static func importLink(_ input: String) throws -> (outbound: [String: Any], name: String?) {
        guard let c = URLComponents(string: input), let scheme = c.scheme, let identity = c.user,
              !identity.isEmpty, let host = c.host, !host.isEmpty, let port = c.port,
              (1...65535).contains(port), c.password == nil else { throw VPNError(L10n.message("xrayconfiguration.incomplete_xray_link_a_key_server_and_port_are")) }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value ?? "" }
        if q["allowInsecure"] == "1" || q["allowInsecure"] == "true" {
            throw VPNError(L10n.message("xrayconfiguration.the_link_disables_tls_verification_use_a_configuration_with"))
        }
        let network = q["type"] ?? "tcp"
        guard ["tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade"].contains(network) else {
            throw VPNError(L10n.message("xrayconfiguration.this_link_transport_cannot_be_imported_yet_use_xray"))
        }
        let security = q["security"] ?? (scheme == "trojan" ? "tls" : "none")
        var stream: [String: Any] = ["network": network == "tcp" ? "raw" : network, "security": security]
        let sni = q["sni"] ?? q["peer"] ?? host
        switch security {
        case "reality":
            guard let key = q["pbk"], !key.isEmpty, network != "ws", network != "httpupgrade" else {
                throw VPNError(L10n.message("xrayconfiguration.check_the_reality_public_key_and_transport"))
            }
            stream["realitySettings"] = ["serverName": sni, "fingerprint": q["fp"] ?? "chrome", "publicKey": key,
                                          "shortId": q["sid"] ?? "", "spiderX": q["spx"] ?? "/"]
        case "tls":
            var tls: [String: Any] = ["serverName": sni, "fingerprint": q["fp"] ?? "chrome", "allowInsecure": false]
            if let alpn = q["alpn"], !alpn.isEmpty { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            stream["tlsSettings"] = tls
        case "none": break
        default: throw VPNError(L10n.message("xrayconfiguration.unknown_xray_transport_security"))
        }
        switch network {
        case "ws": stream["wsSettings"] = ["path": q["path"] ?? "/", "headers": ["Host": q["host"] ?? sni]]
        case "grpc": stream["grpcSettings"] = ["serviceName": q["serviceName"] ?? "", "multiMode": q["mode"] == "multi"]
        case "xhttp": stream["xhttpSettings"] = ["path": q["path"] ?? "/", "host": q["host"] ?? "", "mode": q["mode"] ?? "auto"]
        case "httpupgrade": stream["httpupgradeSettings"] = ["path": q["path"] ?? "/", "host": q["host"] ?? sni]
        default: break
        }
        let settings: [String: Any]
        if scheme == "vless" {
            var user: [String: Any] = ["id": identity, "encryption": q["encryption"] ?? "none"]
            if let flow = q["flow"], !flow.isEmpty { user["flow"] = flow }
            settings = ["vnext": [["address": host, "port": port, "users": [user]]]]
        } else { settings = ["servers": [["address": host, "port": port, "password": identity]]] }
        return (["tag": "proxy", "protocol": scheme, "settings": settings, "streamSettings": stream], c.fragment?.removingPercentEncoding)
    }
}
