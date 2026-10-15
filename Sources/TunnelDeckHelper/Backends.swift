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
        let ready = scratch.appendingPathComponent("network-ready")
        let script = scratch.appendingPathComponent("network.sh")
        let body = """
        #!/bin/sh
        \(shellQuote(runtime.vpncScript!))
        result=$?
        if [ "$result" -eq 0 ]; then
          case "$reason" in
            connect|reconnect) /usr/bin/touch \(shellQuote(ready.path)) ;;
            disconnect) /bin/rm -f \(shellQuote(ready.path)) ;;
          esac
        fi
        exit "$result"
        """
        try PrivateSession.write(Data(body.utf8), to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let child = try EngineProcess(executable: runtime.openconnect!, arguments: ["--config", configURL.path, "--cookie-on-stdin", "--verbose", "--script", shellQuote(script.path), "--reconnect-timeout=30"], env: environment(runtime: runtime), input: request.cookie, session: session)
        defer { child.stop() }
        let start = Date(); var connected = false
        while !session.stopping() {
            guard child.process.isRunning else { throw VPNError("OpenConnect завершил соединение. Подробности в журнале.") }
            let configured = FileManager.default.fileExists(atPath: ready.path)
            if configured && !connected { connected = true; session.emit(.connected, "ocserv: авторизация пройдена, сеть настроена.") }
            if !configured && connected { connected = false; session.emit(.configuring, "OpenConnect восстанавливает соединение…") }
            if !connected && Date().timeIntervalSince(start) > 60 { throw VPNError("Сервер не завершил настройку туннеля за 60 секунд.") }
            usleep(250_000)
        }
    }
    func amnezia() throws {
        let config = try AmneziaConfiguration(session.request.secrets.configuration)
        let network = try NetworkConfiguration(session: session)
        defer { network.restore() }
        let nameFile = scratch.appendingPathComponent("interface")
        let configFile = scratch.appendingPathComponent("awg.conf")
        try PrivateSession.write(Data(config.deviceConfiguration.utf8), to: configFile)
        var env = environment(runtime: runtime)
        env["WG_TUN_NAME_FILE"] = nameFile.path
        env["LOG_LEVEL"] = "error"
        let child = try EngineProcess(executable: runtime.amnezia, arguments: ["-f", "utun"], env: env, session: session)
        defer { child.stop() }
        var interface = ""
        for _ in 0..<100 {
            if session.stopping() { return }
            if let text = try? String(contentsOf: nameFile, encoding: .utf8) {
                interface = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if interface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil { break }
            }
            guard child.process.isRunning else { throw VPNError("Не удалось создать интерфейс AmneziaWG.") }
            usleep(100_000)
        }
        guard interface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil else { throw VPNError("AmneziaWG не сообщил имя интерфейса.") }
        try tool(runtime.awg, ["setconf", interface, configFile.path], env: env)
        try network.protectEndpoints(config.endpointHosts)
        try network.configure(interface: interface, addresses: config.addresses, mtu: config.mtu,
                              allowedIPs: config.routesEnabled ? config.allowedIPs : [], dns: config.dns)
        session.emit(.networkReady, "AmneziaWG: сеть настроена, ожидаем handshake…")
        var connected = false; let start = Date(); var lastCheck = Date.distantPast
        while !session.stopping() {
            guard child.process.isRunning else { throw VPNError("Движок AmneziaWG остановился.") }
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
        if config.usesShadowrocketVisionTLS {
            session.emit(.log, "REALITY/Vision: используем TLS-профиль совместимости с Shadowrocket.")
        }
        let network = try NetworkConfiguration(session: session)
        var xrayChild: EngineProcess?
        var tunnelChild: EngineProcess?
        defer {
            // Restore capture routes and DNS while both packet paths still exist.
            network.restore()
            tunnelChild?.stop()
            xrayChild?.stop()
        }
        let candidates: [String] = (300...999).map { "utun\($0)" }
        guard let interface = candidates.first(where: { name in name.withCString { if_nametoindex($0) } == 0 }) else { throw VPNError("Нет свободного TUN-интерфейса.") }
        var resolved: [String: String] = [:]
        for host in config.endpointHosts where !AmneziaConfiguration.validIP(host) {
            var hints = addrinfo(); hints.ai_family = AF_INET; hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &result) == 0, let entry = result else { throw VPNError("Не удалось определить адрес сервера Xray.") }
            var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST)
            freeaddrinfo(result)
            guard status == 0 else { throw VPNError("Не удалось определить IP сервера Xray.") }
            resolved[host] = String(cString: text)
        }
        let file = scratch.appendingPathComponent("xray.json")
        let socksPort = try LoopbackPort.available()
        try PrivateSession.write(config.proxyData(port: socksPort, physicalInterface: network.physicalInterface,
                                                 resolvedHosts: resolved), to: file)
        let tunnelFile = scratch.appendingPathComponent("socks-tunnel.yml")
        let tunnelConfig = try SocksTunnelConfiguration(interface: interface, socksPort: socksPort)
        try PrivateSession.write(tunnelConfig.data, to: tunnelFile)
        try network.protectEndpoints(config.endpointRouteAddresses(resolvedHosts: resolved))
        let child = try EngineProcess(executable: runtime.xray, arguments: ["run", "-config", file.path],
                                      env: environment(runtime: runtime), session: session)
        xrayChild = child
        func socksIsReady() -> Bool {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { close(fd) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = socksPort.bigEndian
            return withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
            }
        }
        var socksReady = false
        for _ in 0..<100 {
            if session.stopping() { return }
            guard child.process.isRunning else { throw VPNError("Xray не смог запустить локальный прокси. Проверьте журнал.") }
            if socksIsReady() { socksReady = true; break }
            usleep(100_000)
        }
        guard socksReady else { throw VPNError("Xray не открыл локальный прокси за 10 секунд.") }
        func probe(_ stage: String) {
            session.emit(.log, "Xray: проверяем сервер \(stage)…")
            do {
                try tool("/usr/bin/curl", ["--disable", "--silent", "--show-error", "--fail", "--proxy",
                    "socks5h://127.0.0.1:\(socksPort)", "--noproxy", "", "--connect-timeout", "3", "--max-time", "5",
                    "--output", "/dev/null", "https://example.com/"])
                session.emit(.log, "Xray: HTTPS \(stage) работает.")
            } catch {
                // Readiness is decided by the application's HTTPS check through TUN.
                // One unstable transport probe must not abort a working packet path.
                session.emit(.log, "Xray: контрольный SOCKS-запрос \(stage) не прошёл: " + error.localizedDescription)
            }
        }
        probe("до установки маршрутов")
        if session.stopping() { return }
        let tunnel = try EngineProcess(executable: runtime.socksTunnel, arguments: [tunnelFile.path],
                                       env: environment(runtime: runtime), session: session)
        tunnelChild = tunnel
        func tunnelIsReady() -> Bool {
            var entries: UnsafeMutablePointer<ifaddrs>?
            guard getifaddrs(&entries) == 0 else { return false }
            defer { if let entries { freeifaddrs(entries) } }
            var entry = entries
            var ipv4 = false, ipv6 = false
            while let current = entry {
                let info = current.pointee
                if String(cString: info.ifa_name) == interface, info.ifa_flags & UInt32(IFF_UP) != 0,
                   let address = info.ifa_addr, address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 {
                    var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: text)
                        ipv4 = ipv4 || ip == SocksTunnelConfiguration.ipv4Address
                        ipv6 = ipv6 || ip == SocksTunnelConfiguration.ipv6Address
                    }
                }
                entry = info.ifa_next
            }
            return ipv4 && ipv6
        }
        var tunnelReady = false
        for _ in 0..<100 {
            if session.stopping() { return }
            guard child.process.isRunning else { throw VPNError("Движок Xray остановился.") }
            guard tunnel.process.isRunning else { throw VPNError("TUN-мост не смог настроить интерфейс. Проверьте журнал.") }
            if tunnelIsReady() { tunnelReady = true; break }
            usleep(100_000)
        }
        guard tunnelReady else { throw VPNError("TUN-мост не настроил интерфейс за 10 секунд.") }
        try network.configure(interface: interface, addresses: SocksTunnelConfiguration.addresses,
                              mtu: SocksTunnelConfiguration.mtu, allowedIPs: ["0.0.0.0/0", "::/0"], dns: SocksTunnelConfiguration.dns)
        if session.stopping() { return }
        guard child.process.isRunning, tunnel.process.isRunning else { throw VPNError("Движок Xray или TUN-мост остановился.") }
        session.emit(.networkReady, "Xray: маршруты настроены, проверяем передачу данных…")
        while !session.stopping() {
            guard child.process.isRunning else { throw VPNError("Движок Xray остановился.") }
            guard tunnel.process.isRunning else { throw VPNError("TUN-мост остановился.") }
            usleep(250_000)
        }
    }
    deinit { try? FileManager.default.removeItem(at: scratch) }
}
