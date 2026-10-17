import TunnelLocalization
import Foundation
import Darwin
import SystemConfiguration
import TunnelCore

@MainActor enum XrayProbe {
    /// Exercise the actual outbound without installing TUN routes or changing DNS.
    static func check(configuration: XrayConfiguration, runtime: RuntimePaths, selectedOutbound: String? = nil,
                      log: @escaping (LocalizedMessage) -> Void) async throws {
        let session = try PrivateSession()
        defer { session.remove() }
        let port = try LoopbackPort.available()
        let file = session.directory.appendingPathComponent("xray-probe.json")
        if configuration.usesVisionCompatibilityTLS {
            log(L10n.message("xrayprobe.reality_vision_using_the_tunneldeck_compatibility_tls_profile"))
        }
        let store = SCDynamicStoreCreate(nil, "TunnelDeck-probe" as CFString, nil, nil)
        let primary = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) as? [String: Any] }
        let interface = primary?["PrimaryInterface"] as? String
        try PrivateSession.write(configuration.selectedProbeData(port: port, selected: selectedOutbound, physicalInterface: interface ?? ""), to: file)
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
            guard listening(port) else { throw VPNError(L10n.message("xrayprobe.xray_did_not_open_the_local_test_port_see")) }
            let curl = ProcessRunner()
            let response = try await curl.run("/usr/bin/curl", ["--disable", "--silent", "--show-error", "--fail",
                "--proxy", "socks5h://127.0.0.1:\(port)", "--noproxy", "", "--connect-timeout", "10",
                "--max-time", "20", "--output", "/dev/null", "https://example.com/"], timeout: 25)
            guard response.status == 0 else {
                log(.verbatim(response.stderr))
                throw VPNError(L10n.message("xrayprobe.xray_could_not_transfer_https_through_the_server_check"))
            }
            log(L10n.message("xrayprobe.xray_a_single_https_request_succeeded_checking_8_concurrent"))
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
            log(L10n.message("xrayprobe.xray_concurrent_https_requests_without_tun_8", [.init(successes)]))
            guard successes == 8 else { throw VPNError(L10n.message("xrayprobe.xray_a_single_request_succeeds_but_concurrent_connections_are", [.init(successes)])) }
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
