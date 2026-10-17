import TunnelLocalization
import Foundation
import Darwin
import TunnelCore

/// Owns the common packet path; backend runners own the VPN transport and network transaction.
final class RoutingRuntime {
    private var router: EngineProcess?
    private var bridge: EngineProcess?
    private let session: SecureSession
    let info: RoutingRuntimeInfo
    let interface: String

    init(session: SecureSession, runtime: RuntimePaths, scratch: URL, network: NetworkConfiguration,
         vpnInterface: String? = nil, vpnDNS: [String] = [], vpnAddresses: [String]? = nil, xray: XrayConfiguration? = nil,
         resolvedHosts: [String: String] = [:]) throws {
        self.session = session
        guard let name = (300...999).map({ "utun\($0)" }).first(where: { $0.withCString { if_nametoindex($0) } == 0 }) else {
            throw VPNError(L10n.message("routingruntime.no_interface_is_available_for_shared_routing"))
        }
        interface = name
        var ports = Set<UInt16>()
        func nextPort() throws -> UInt16 {
            for _ in 0..<20 { let value = try LoopbackPort.available(); if ports.insert(value).inserted { return value } }
            throw VPNError(L10n.message("routingruntime.could_not_allocate_router_ports"))
        }
        let trafficPort = try nextPort()
        info = try RoutingRuntimeInfo(probePort: nextPort(), dnsPort: nextPort())
        let systemProbePort = try nextPort()
        let config = try RoutingConfiguration.make(policy: session.request.routing, trafficPort: trafficPort,
            probePort: info.probePort, dnsPort: info.dnsPort, physicalInterface: network.physicalInterface,
            vpnInterface: vpnInterface, vpnDNS: vpnDNS, directDNS: network.physicalDNS, vpnAddresses: vpnAddresses, xray: xray,
            selectedOutbound: session.request.profile.xrayOutboundTag, resolvedHosts: resolvedHosts, systemProbePort: systemProbePort)
        let file = scratch.appendingPathComponent("router.json")
        let bridgeFile = scratch.appendingPathComponent("routing-tunnel.yml")
        try PrivateSession.write(config, to: file)
        try PrivateSession.write(SocksTunnelConfiguration(interface: name, socksPort: trafficPort).data, to: bridgeFile)
        var env = environment(runtime: runtime)
        env["XRAY_LOCATION_ASSET"] = runtime.geoIP.path
        let cache = "/private/var/run/tunneldeck-dns-\(session.request.userID)"
        if mkdir(cache, 0o700) != 0 && errno != EEXIST { throw VPNError(L10n.message("routingruntime.could_not_create_the_router_cache")) }
        let directoryFD = open(cache, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw VPNError(L10n.message("routingruntime.invalid_router_cache_directory")) }
        defer { close(directoryFD) }
        var cacheInfo = stat()
        guard fstat(directoryFD, &cacheInfo) == 0, cacheInfo.st_uid == 0, cacheInfo.st_mode & 0o077 == 0 else { throw VPNError(L10n.message("routingruntime.invalid_router_cache_permissions")) }
        for suffix in ["v4", "v6"] {
            var info = stat()
            if fstatat(directoryFD, "fake.\(suffix)", &info, AT_SYMLINK_NOFOLLOW) == 0 {
                guard info.st_uid == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
                    throw VPNError(L10n.message("routingruntime.invalid_router_cache_file"))
                }
            } else if errno != ENOENT { throw VPNError(L10n.message("routingruntime.could_not_verify_the_router_cache")) }
        }
        env["TUNNELDECK_FAKE_DNS_CACHE"] = cache + "/fake"
        do {
            _ = try tool(runtime.xray, ["run", "-test", "-config", file.path], env: env)
            router = try EngineProcess(executable: runtime.xray, arguments: ["run", "-config", file.path], env: env, session: session)
            var ready = false
            for _ in 0..<100 {
                if session.stopping() { throw CancellationError() }
                try checkRunning(expectBridge: false)
                if Self.listenerReady(trafficPort), Self.listenerReady(info.probePort), Self.listenerReady(info.dnsPort), Self.listenerReady(systemProbePort) { ready = true; break }
                usleep(100_000)
            }
            guard ready else { throw VPNError(L10n.message("routingruntime.the_router_did_not_start_its_local_listeners_within")) }
            bridge = try EngineProcess(executable: runtime.socksTunnel, arguments: [bridgeFile.path], env: env, session: session)
            ready = false
            for _ in 0..<100 {
                if session.stopping() { throw CancellationError() }
                try checkRunning()
                if Self.interfaceReady(name) { ready = true; break }
                usleep(100_000)
            }
            guard ready else { throw VPNError(L10n.message("routingruntime.the_tun_bridge_did_not_configure_its_interface_within")) }
            try network.configure(interface: name, addresses: SocksTunnelConfiguration.addresses, mtu: SocksTunnelConfiguration.mtu,
                allowedIPs: ["0.0.0.0/0", "::/0"], dns: [RoutingConfiguration.resolverAddress])
            network.flushDNSCache()
            session.routingReady(info)
        } catch { stop(); throw error }
    }

    func checkRunning(expectBridge: Bool = true) throws {
        guard router?.process.isRunning == true else { throw VPNError(L10n.message("routingruntime.the_shared_router_stopped_see_diagnostics_for_details")) }
        if expectBridge, bridge?.process.isRunning != true { throw VPNError(L10n.message("routingruntime.the_shared_tun_bridge_stopped")) }
    }
    func stop() { bridge?.stop(); bridge = nil; router?.stop(); router = nil }
    deinit { stop() }

    private static func listenerReady(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1"); address.sin_port = port.bigEndian
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
    }
    private static func interfaceReady(_ name: String) -> Bool {
        var entries: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&entries) == 0 else { return false }; defer { if let entries { freeifaddrs(entries) } }
        var entry = entries, found4 = false, found6 = false
        while let current = entry {
            let info = current.pointee
            if String(cString: info.ifa_name) == name, info.ifa_flags & UInt32(IFF_UP) != 0, let address = info.ifa_addr,
               address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 {
                var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address, socklen_t(address.pointee.sa_len), &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0 {
                    found4 = found4 || String(cString: text) == SocksTunnelConfiguration.ipv4Address
                    found6 = found6 || String(cString: text) == SocksTunnelConfiguration.ipv6Address
                }
            }
            entry = info.ifa_next
        }
        return found4 && found6
    }
}
