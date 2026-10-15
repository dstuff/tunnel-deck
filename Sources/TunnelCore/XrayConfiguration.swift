import Foundation

public struct XrayConfiguration {
    private let configuration: [String: Any]
    public let displayName: String?

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.utf8.count < 256_000 else { throw VPNError("Конфигурация Xray слишком большая.") }
        if text.hasPrefix("vless://") || text.hasPrefix("trojan://") {
            let imported = try Self.importLink(text)
            configuration = ["outbounds": [imported.outbound]]; displayName = imported.name
        } else {
            guard let data = text.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw VPNError("Вставьте JSON Xray либо ссылку VLESS/Trojan.")
            }
            configuration = json["protocol"] != nil ? ["outbounds": [json]] : json
            displayName = nil
        }
        guard let outbounds = configuration["outbounds"] as? [[String: Any]], !outbounds.isEmpty else {
            throw VPNError("В конфигурации Xray отсутствуют outbounds.")
        }
        let supported = Set(["vless", "vmess", "trojan", "shadowsocks", "socks", "http", "freedom", "blackhole", "dns", "wireguard", "hysteria"])
        for outbound in outbounds {
            guard let p = outbound["protocol"] as? String, supported.contains(p) else { throw VPNError("Неподдерживаемый тип outbound в Xray.") }
        }
        try Self.rejectFileAccess(configuration)
    }

    public var endpointHosts: [String] {
        (configuration["outbounds"] as? [[String: Any]] ?? []).flatMap { outbound -> [String] in
            let settings = outbound["settings"] as? [String: Any] ?? [:]
            return ["vnext", "servers"].flatMap { key in
                (settings[key] as? [[String: Any]] ?? []).compactMap { $0["address"] as? String }
            }
        }
    }

    public func endpointRouteAddresses(resolvedHosts: [String: String]) -> [String] {
        // Literal IP endpoints need the same tunnel bypass as resolved hostnames.
        endpointHosts.map { resolvedHosts[$0] ?? $0 }
    }

    public var usesShadowrocketVisionTLS: Bool {
        (configuration["outbounds"] as? [[String: Any]] ?? []).contains(where: Self.isShadowrocketVision)
    }

    private static func isShadowrocketVision(_ outbound: [String: Any]) -> Bool {
        guard outbound["protocol"] as? String == "vless",
              let stream = outbound["streamSettings"] as? [String: Any],
              stream["security"] as? String == "reality" else { return false }
        let reality = stream["realitySettings"] as? [String: Any] ?? [:]
        let preset = reality["fingerprint"] as? String ?? ""
        guard ["", "chrome", "safari", "safari15_5", "shadowrocket_safari15_5"].contains(preset) else { return false }
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

    public func proxyData(port: UInt16, physicalInterface: String, resolvedHosts: [String: String]) throws -> Data {
        try data(physicalInterface: physicalInterface, resolvedHosts: resolvedHosts, probePort: port, socksUDP: true)
    }

    public func data(tunnelInterface: String? = nil, physicalInterface: String? = nil, resolvedHosts: [String: String] = [:], probePort: UInt16? = nil, socksUDP: Bool = false) throws -> Data {
        var result: [String: Any] = ["log": ["loglevel": "warning"]]
        for key in ["outbounds", "routing", "dns", "policy"] { result[key] = configuration[key] }
        result["outbounds"] = (configuration["outbounds"] as? [[String: Any]] ?? []).map { original in
            guard Self.isShadowrocketVision(original) else { return original }
            var outbound = original
            var stream = outbound["streamSettings"] as? [String: Any] ?? [:]
            var reality = stream["realitySettings"] as? [String: Any] ?? [:]
            // The pinned core patch recreates the observed Safari15_5 settings:
            // ordinary X25519, no ALPN, and a single RSA-PSS/SHA384 entry.
            reality["fingerprint"] = "shadowrocket_safari15_5"
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
                if forbidden.contains(key.lowercased()) { throw VPNError("Xray: внешние файлы и скрипты в импортированной конфигурации не поддерживаются.") }
                try rejectFileAccess(value)
            }
        } else if let array = value as? [Any] { for value in array { try rejectFileAccess(value) } }
    }

    private static func importLink(_ input: String) throws -> (outbound: [String: Any], name: String?) {
        guard let c = URLComponents(string: input), let scheme = c.scheme, let identity = c.user,
              !identity.isEmpty, let host = c.host, !host.isEmpty, let port = c.port,
              (1...65535).contains(port), c.password == nil else { throw VPNError("Неполная ссылка Xray: нужны ключ, сервер и порт.") }
        var q: [String: String] = [:]
        for item in c.queryItems ?? [] { q[item.name] = item.value ?? "" }
        if q["allowInsecure"] == "1" || q["allowInsecure"] == "true" {
            throw VPNError("Ссылка отключает проверку TLS. Нужна конфигурация с действительным сертификатом.")
        }
        let network = q["type"] ?? "tcp"
        guard ["tcp", "raw", "ws", "grpc", "xhttp", "httpupgrade"].contains(network) else {
            throw VPNError("Этот транспорт ссылки пока не импортируется. Используйте JSON Xray.")
        }
        let security = q["security"] ?? (scheme == "trojan" ? "tls" : "none")
        var stream: [String: Any] = ["network": network == "tcp" ? "raw" : network, "security": security]
        let sni = q["sni"] ?? q["peer"] ?? host
        switch security {
        case "reality":
            guard let key = q["pbk"], !key.isEmpty, network != "ws", network != "httpupgrade" else {
                throw VPNError("Проверьте публичный ключ и транспорт REALITY.")
            }
            stream["realitySettings"] = ["serverName": sni, "fingerprint": q["fp"] ?? "chrome", "publicKey": key,
                                          "shortId": q["sid"] ?? "", "spiderX": q["spx"] ?? "/"]
        case "tls":
            var tls: [String: Any] = ["serverName": sni, "fingerprint": q["fp"] ?? "chrome", "allowInsecure": false]
            if let alpn = q["alpn"], !alpn.isEmpty { tls["alpn"] = alpn.split(separator: ",").map(String.init) }
            stream["tlsSettings"] = tls
        case "none": break
        default: throw VPNError("Неизвестная защита транспорта Xray.")
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
