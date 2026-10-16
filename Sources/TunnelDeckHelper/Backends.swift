import Foundation
import Darwin
import TunnelCore

func shellQuote(_ string: String) -> String { "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'" }

final class BackendRunner {
    let session: SecureSession
    let runtime: RuntimePaths
    let scratch: URL
    init(session: SecureSession, runtime: RuntimePaths) throws {
        self.session = session; self.runtime = runtime
        scratch = URL(fileURLWithPath: "/private/tmp/tunneldeck-root-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func run() throws {
        try runtime.check(session.request.profile.kind)
        try runtime.checkRouting()
        _ = try session.request.routing.validated()
        switch session.request.profile.kind {
        case .openConnect: try openConnect()
        case .amneziaWG: try amnezia()
        case .xray: try xray()
        }
    }
    func openConnect() throws {
        let request = session.request
        guard !request.cookie.isEmpty, !request.cookie.contains("\n"), !request.cookie.contains("\r") else { throw VPNError("Отсутствует cookie авторизации OpenConnect.") }
        let configuration = try OpenConnectConfiguration.make(profile: request.profile, secrets: request.secrets)
        let configURL = scratch.appendingPathComponent("openconnect.conf")
        try PrivateSession.write(Data(configuration.utf8), to: configURL)
        let network = try NetworkConfiguration(session: session)
        let endpoint = try VPNEndpoint(server: request.profile.server, camouflage: request.secrets.camouflage)
        if let host = URLComponents(string: endpoint.baseURL)?.host { try network.protectEndpoints([host]) }
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
        let callback = shellQuote(helper) + " --openconnect-network " + shellQuote(scratch.path)
        let child = try EngineProcess(executable: runtime.openconnect!, arguments: ["--config", configURL.path, "--cookie-on-stdin", "--verbose", "--script", callback, "--reconnect-timeout=30"], env: environment(runtime: runtime), input: request.cookie, session: session)
        var router: RoutingRuntime?
        defer { network.restore(); router?.stop(); child.stop() }
        let eventFile = scratch.appendingPathComponent("openconnect-network.json")
        var previous: UUID?, deadline = Date().addingTimeInterval(60)
        while !session.stopping() {
            guard child.process.isRunning else { throw VPNError("OpenConnect завершил соединение. Подробности в журнале.") }
            if let data = try? Data(contentsOf: eventFile), data.count <= 64_000,
               let event = try? JSONDecoder().decode(OpenConnectNetworkSettings.self, from: data), event.id != previous {
                previous = event.id
                switch event.reason {
                case "connect", "reconnect":
                    // The same baseline is retained across reconnects; no server script can install global routes.
                    network.restore(); router?.stop(); router = nil
                    if let gateway = event.gateway { try network.protectEndpoints([gateway]) }
                    try network.configure(interface: event.interface, addresses: event.addresses, mtu: event.mtu,
                                          allowedIPs: event.routes, dns: [], scoped: true)
                    try network.excludeFromVPN(event.excludedRoutes, interface: event.interface)
                    router = try RoutingRuntime(session: session, runtime: runtime, scratch: scratch, network: network,
                                                vpnInterface: event.interface, vpnDNS: event.dns, vpnAddresses: event.addresses)
                    session.emit(.connected, "ocserv: авторизация пройдена, общая маршрутизация настроена.")
                    deadline = .distantFuture
                case "attempt-reconnect":
                    session.emit(.configuring, "OpenConnect восстанавливает VPN-канал; правила остаются включены…")
                    deadline = Date().addingTimeInterval(60)
                case "disconnect": throw VPNError("OpenConnect закрыл VPN-канал.")
                default: break
                }
            }
            try router?.checkRunning()
            if Date() > deadline { throw VPNError("Сервер не завершил настройку туннеля за 60 секунд.") }
            usleep(250_000)
        }
    }
    func amnezia() throws {
        let config = try AmneziaConfiguration(session.request.secrets.configuration)
        let network = try NetworkConfiguration(session: session)
        let nameFile = scratch.appendingPathComponent("interface")
        let configFile = scratch.appendingPathComponent("awg.conf")
        try PrivateSession.write(Data(config.deviceConfiguration.utf8), to: configFile)
        var env = environment(runtime: runtime)
        env["WG_TUN_NAME_FILE"] = nameFile.path; env["LOG_LEVEL"] = "error"
        let child = try EngineProcess(executable: runtime.amnezia, arguments: ["-f", "utun"], env: env, session: session)
        var router: RoutingRuntime?
        defer { network.restore(); router?.stop(); child.stop() }
        var interface = ""
        for _ in 0..<100 {
            if session.stopping() { return }
            if let text = try? String(contentsOf: nameFile, encoding: .utf8) {
                interface = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if interface.range(of: #"\Autun[0-9]{1,4}\z"#, options: .regularExpression) != nil { break }
            }
            guard child.process.isRunning else { throw VPNError("Не удалось создать интерфейс AmneziaWG.") }
            usleep(100_000)
        }
        guard interface.range(of: #"\Autun[0-9]{1,4}\z"#, options: .regularExpression) != nil else { throw VPNError("AmneziaWG не сообщил имя интерфейса.") }
        try tool(runtime.awg, ["setconf", interface, configFile.path], env: env)
        try network.protectEndpoints(config.endpointHosts)
        // AllowedIPs retains peer selection/coverage; Table never disables the shared policy.
        try network.configure(interface: interface, addresses: config.addresses, mtu: config.mtu,
                              allowedIPs: config.allowedIPs, dns: [], scoped: true)
        router = try RoutingRuntime(session: session, runtime: runtime, scratch: scratch, network: network,
                                    vpnInterface: interface, vpnDNS: config.dns, vpnAddresses: config.addresses)
        session.emit(.networkReady, "AmneziaWG: общая маршрутизация настроена, ожидаем handshake…")
        var connected = false; let start = Date(); var lastCheck = Date.distantPast
        while !session.stopping() {
            guard child.process.isRunning else { throw VPNError("Движок AmneziaWG остановился.") }
            try router?.checkRunning()
            if Date().timeIntervalSince(lastCheck) > 2 {
                lastCheck = Date()
                let handshakes = try tool(runtime.awg, ["show", interface, "latest-handshakes"], env: env)
                let hasHandshake = handshakes.split(separator: "\n").contains { line in
                    guard let last = line.split(whereSeparator: { $0.isWhitespace }).last else { return false }
                    return (Int64(last) ?? 0) > 0
                }
                if hasHandshake && !connected { connected = true; session.emit(.connected, "AmneziaWG 3.1: получен handshake сервера.") }
            }
            if !connected && Date().timeIntervalSince(start) > 45 { throw VPNError("Нет handshake AmneziaWG. Проверьте ключи, параметры маскировки и доступность UDP.") }
            usleep(250_000)
        }
    }
    func xray() throws {
        let config = try XrayConfiguration(session.request.secrets.configuration)
        _ = try config.selectedOutboundTag(session.request.profile.xrayOutboundTag)
        if config.usesVisionCompatibilityTLS { session.emit(.log, "REALITY/Vision: используем TLS-профиль совместимости TunnelDeck.") }
        let network = try NetworkConfiguration(session: session)
        var router: RoutingRuntime?
        defer { network.restore(); router?.stop() }
        var resolved: [String: String] = [:]
        let endpointHosts = try config.endpointHosts(selected: session.request.profile.xrayOutboundTag)
        for host in endpointHosts where IPNetwork.address(host) == nil {
            var hints = addrinfo(); hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let entry = result else { throw VPNError("Не удалось определить адрес сервера Xray.") }
            defer { freeaddrinfo(result) }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 else { throw VPNError("Не удалось определить IP сервера Xray.") }
            resolved[host] = String(cString: text)
        }
        try network.protectEndpoints(endpointHosts.map { resolved[$0] ?? $0 })
        router = try RoutingRuntime(session: session, runtime: runtime, scratch: scratch, network: network,
                                    xray: config, resolvedHosts: resolved)
        session.emit(.networkReady, "Xray: общая маршрутизация настроена, проверяем передачу данных через VPN…")
        while !session.stopping() { try router?.checkRunning(); usleep(250_000) }
    }
    deinit { try? FileManager.default.removeItem(at: scratch) }
}
