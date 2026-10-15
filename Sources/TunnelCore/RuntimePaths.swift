import Foundation

public struct RuntimePaths: Sendable {
    public let root: URL
    public init(root: URL) { self.root = root }
    public var xray: String { root.appendingPathComponent("xray/xray").path }
    public var socksTunnel: String { root.appendingPathComponent("bin/hev-socks5-tunnel").path }
    public var amnezia: String { root.appendingPathComponent("bin/amneziawg-go").path }
    public var awg: String { root.appendingPathComponent("bin/awg").path }
    public var openconnect: String? {
        ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public var vpncScript: String? {
        ["/opt/homebrew/etc/vpnc/vpnc-script", "/usr/local/etc/vpnc/vpnc-script"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    public func check(_ kind: VPNProtocol) throws {
        switch kind {
        case .openConnect:
            guard openconnect != nil, vpncScript != nil else { throw VPNError("OpenConnect не установлен. Выполните brew install openconnect.") }
        case .amneziaWG:
            guard FileManager.default.isExecutableFile(atPath: amnezia), FileManager.default.isExecutableFile(atPath: awg) else {
                throw VPNError("В сборке отсутствует движок AmneziaWG 3.1. Запустите script/prepare_runtimes.sh.")
            }
        case .xray:
            guard FileManager.default.isExecutableFile(atPath: xray), FileManager.default.isExecutableFile(atPath: socksTunnel) else {
                throw VPNError("В сборке отсутствует Xray или TUN-мост. Запустите script/prepare_runtimes.sh.")
            }
        }
    }
}
