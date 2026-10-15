import Foundation
import Darwin
import SystemConfiguration
import TunnelCore

final class NetworkConfiguration {
    let physicalInterface: String
    private let gateway4: String?
    private let gateway6: String?
    private var routes: [[String]] = []
    private var dnsStore: SCDynamicStore?
    private let dnsKey = "State:/Network/Service/TunnelDeck-" + UUID().uuidString + "/DNS"
    private let session: SecureSession

    init(session: SecureSession) throws {
        self.session = session
        let v4 = try tool("/sbin/route", ["-n", "get", "-inet", "default"], allowFailure: true)
        let v6 = try tool("/sbin/route", ["-n", "get", "-inet6", "default"], allowFailure: true)
        func value(_ key: String, in text: String) -> String? {
            text.components(separatedBy: .newlines).compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                return parts.count == 2 && parts[0] == key ? parts[1] : nil
            }.first
        }
        guard let iface = value("interface", in: v4) ?? value("interface", in: v6),
              iface.range(of: #"^[a-zA-Z]+[0-9]+$"#, options: .regularExpression) != nil else {
            throw VPNError("Не найден активный сетевой интерфейс.")
        }
        physicalInterface = iface
        gateway4 = value("gateway", in: v4); gateway6 = value("gateway", in: v6)
    }

    func protectEndpoints(_ hosts: [String]) throws {
        for host in Set(hosts) {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_DGRAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0 else { throw VPNError("Не удалось определить адрес VPN-сервера.") }
            defer { if let result { freeaddrinfo(result) } }
            var current = result
            while let entry = current {
                let info = entry.pointee
                var address = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(info.ai_addr, info.ai_addrlen, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: address), v6 = info.ai_family == AF_INET6
                    if let gateway = v6 ? gateway6 : gateway4, !gateway.hasPrefix("link#") {
                        try addRoute([v6 ? "-inet6" : "-inet", "-host", ip, gateway], tolerateExisting: true)
                    }
                }
                current = info.ai_next
            }
        }
    }

    func configure(interface: String, addresses: [String], mtu: Int, allowedIPs: [String], dns: [String]) throws {
        for address in addresses {
            let args = address.contains(":") ? [interface, "inet6", address, "alias"] :
                [interface, "inet", address, String(address.split(separator: "/")[0]), "alias"]
            try tool("/sbin/ifconfig", args)
        }
        try tool("/sbin/ifconfig", [interface, "mtu", String(mtu), "up"])
        if allowedIPs.contains(where: { $0.contains(":") }), !addresses.contains(where: { $0.contains(":") }) {
            // Darwin requires an IPv6 interface address for -interface routes.
            // IPv4-only profiles can still capture IPv6 with AllowedIPs = ::/0.
            // A link-local address initializes IPv6 without inventing a server-assigned address.
            try tool("/sbin/ifconfig", [interface, "inet6", "fe80::1/64", "alias"])
            session.emit(.log, "Для IPv6-маршрутов настроен локальный адрес туннеля.")
        }
        for cidr in Set(allowedIPs) {
            let prefixes = cidr == "0.0.0.0/0" ? ["0.0.0.0/1", "128.0.0.0/1"] :
                cidr == "::/0" ? ["::/1", "8000::/1"] : [cidr]
            for prefix in prefixes {
                try addRoute([prefix.contains(":") ? "-inet6" : "-inet", "-net", prefix, "-interface", interface])
            }
        }
        if !dns.isEmpty {
            guard let store = SCDynamicStoreCreate(nil, "TunnelDeck" as CFString, nil, nil) else { throw VPNError("Не удалось настроить DNS.") }
            let values: [String: Any] = ["ServerAddresses": dns, "SupplementalMatchDomains": [""],
                                         "SupplementalMatchOrders": [0], "SupplementalMatchDomainsNoSearch": 1]
            guard SCDynamicStoreAddTemporaryValue(store, dnsKey as CFString, values as CFDictionary) else { throw VPNError("macOS отклонила настройку DNS.") }
            dnsStore = store
        }
    }

    private func addRoute(_ args: [String], tolerateExisting: Bool = false) throws {
        let output: String
        do { output = try tool("/sbin/route", ["-q", "-n", "add"] + args) }
        catch {
            if tolerateExisting && error.localizedDescription.localizedCaseInsensitiveContains("File exists") { return }
            throw VPNError("Не удалось установить VPN-маршрут (\(args.joined(separator: " "))): " + error.localizedDescription)
        }
        // route prints kernel errors even when its exit status is zero.
        if output.localizedCaseInsensitiveContains("File exists") {
            if tolerateExisting { return }
            throw VPNError("Нужный маршрут уже используется другим подключением. Отключите его перед запуском TunnelDeck.")
        }
        if output.localizedCaseInsensitiveContains("not in table") || output.localizedCaseInsensitiveContains("unreachable") || output.localizedCaseInsensitiveContains("permission") {
            throw VPNError("Не удалось установить VPN-маршрут (\(args.joined(separator: " "))): " + output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        routes.append(args)
    }

    func restore() {
        if let dnsStore { _ = SCDynamicStoreRemoveValue(dnsStore, dnsKey as CFString) }
        dnsStore = nil
        for args in routes.reversed() { _ = try? tool("/sbin/route", ["-q", "-n", "delete"] + args, allowFailure: true) }
        routes.removeAll()
    }
    deinit { restore() }
}
