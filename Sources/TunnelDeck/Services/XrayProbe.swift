import Foundation
import Darwin
import SystemConfiguration
import TunnelCore

@MainActor enum XrayProbe {
    /// Exercise the actual outbound without installing TUN routes or changing DNS.
    static func check(configuration: XrayConfiguration, runtime: RuntimePaths,
                      log: @escaping (String) -> Void) async throws {
        let session = try PrivateSession()
        defer { session.remove() }
        let port = try LoopbackPort.available()
        let file = session.directory.appendingPathComponent("xray-probe.json")
        if configuration.usesShadowrocketVisionTLS {
            log("REALITY/Vision: используем TLS-профиль совместимости с Shadowrocket.")
        }
        let store = SCDynamicStoreCreate(nil, "TunnelDeck-probe" as CFString, nil, nil)
        let primary = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let interface = primary?["PrimaryInterface"] as? String
        try PrivateSession.write(configuration.probeData(port: port, physicalInterface: interface), to: file)
        let engine = ProcessRunner()
        let task = Task {
            try await engine.run(runtime.xray, ["run", "-config", file.path], timeout: 35, logStandardOutput: true, log: log)
        }
        do {
            for _ in 0..<50 {
                try Task.checkCancellation()
                if listening(port) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard listening(port) else { throw VPNError("Xray не открыл локальный порт проверки. См. журнал.") }
            let curl = ProcessRunner()
            let response = try await curl.run("/usr/bin/curl", ["--disable", "--silent", "--show-error", "--fail",
                "--proxy", "socks5h://127.0.0.1:\(port)", "--noproxy", "", "--connect-timeout", "10",
                "--max-time", "20", "--output", "/dev/null", "https://example.com/"], timeout: 25)
            guard response.status == 0 else {
                log(response.stderr)
                throw VPNError("Xray: не удалось передать HTTPS через сервер. Проверьте доступность сервера и настройки исходящего подключения; подробности в журнале.")
            }
            log("Xray: одиночный HTTPS-запрос прошёл. Проверяем 8 одновременных запросов…")
            let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
                for _ in 0..<8 {
                    group.addTask { @MainActor in
                        let runner = ProcessRunner()
                        let output = try? await runner.run("/usr/bin/curl", ["--disable", "--silent", "--show-error", "--fail",
                            "--proxy", "socks5h://127.0.0.1:\(port)", "--noproxy", "", "--connect-timeout", "8",
                            "--max-time", "12", "--output", "/dev/null", "https://example.com/"], timeout: 15)
                        return output?.status == 0
                    }
                }
                var count = 0
                for await success in group { if success { count += 1 } }
                return count
            }
            log("Xray: одновременные HTTPS-запросы без TUN: \(successes)/8.")
            guard successes == 8 else { throw VPNError("Xray: одиночный запрос проходит, но параллельные соединения нестабильны (\(successes)/8). Системные маршруты в этой проверке не менялись.") }
        } catch {
            task.cancel(); engine.cancel()
            _ = await task.result
            throw error
        }
        task.cancel(); engine.cancel()
        _ = await task.result
    }

    private static func listening(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
