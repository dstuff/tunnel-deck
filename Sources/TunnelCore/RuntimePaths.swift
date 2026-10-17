import TunnelLocalization
import Foundation

public struct RuntimePaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var xray: String { root.appendingPathComponent("xray/xray").path }
    public var socksTunnel: String { root.appendingPathComponent("bin/hev-socks5-tunnel").path }
    public var amnezia: String { root.appendingPathComponent("bin/amneziawg-go").path }
    public var awg: String { root.appendingPathComponent("bin/awg").path }
    public var geoIP: URL { root.appendingPathComponent("geoip") }
    public func checkRouting() throws {
        guard FileManager.default.isExecutableFile(atPath: xray), FileManager.default.isExecutableFile(atPath: socksTunnel),
              FileManager.default.fileExists(atPath: geoIP.appendingPathComponent("geoip.dat").path),
              FileManager.default.fileExists(atPath: geoIP.appendingPathComponent("countries.bin").path) else {
            throw VPNError(L10n.message("runtimepaths.the_app_is_missing_the_shared_router_or_country"))
        }
    }
    public var openconnect: String? {
        let path = root.appendingPathComponent("bin/openconnect").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    public var vpncScript: String? {
        let path = root.appendingPathComponent("openconnect/vpnc-script").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }
    public func check(_ kind: VPNProtocol) throws {
        switch kind {
        case .openConnect:
            guard openconnect != nil, vpncScript != nil else {
                throw VPNError(L10n.message("runtimepaths.the_app_is_missing_openconnect_or_its_network_script"))
            }
        case .amneziaWG:
            guard FileManager.default.isExecutableFile(atPath: amnezia), FileManager.default.isExecutableFile(atPath: awg) else {
                throw VPNError(L10n.message("runtimepaths.the_amneziawg_3_1_engine_is_missing_run_script"))
            }
        case .xray:
            guard FileManager.default.isExecutableFile(atPath: xray), FileManager.default.isExecutableFile(atPath: socksTunnel) else {
                throw VPNError(L10n.message("runtimepaths.xray_or_the_tun_bridge_is_missing_run_script"))
            }
        }
    }
}
