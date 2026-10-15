import Foundation

/// Only TunnelDeck's generated loopback bridge settings reach the root-run engine.
public struct SocksTunnelConfiguration {
    public static let mtu = 4064
    public static let ipv4Address = "198.18.0.1"
    public static let ipv6Address = "fd00:1234:ffff::10"
    public static let addresses = [ipv4Address + "/24", ipv6Address + "/64"]
    public static let dns = ["1.1.1.1", "8.8.8.8"]

    private let interface: String
    private let socksPort: UInt16

    public init(interface: String, socksPort: UInt16) throws {
        guard interface.range(of: #"\Autun[0-9]{1,4}\z"#, options: .regularExpression) != nil,
              socksPort != 0 else { throw VPNError("Некорректные параметры локального TUN-моста.") }
        self.interface = interface
        self.socksPort = socksPort
    }

    public var data: Data {
        Data("""
        tunnel:
          name: '\(interface)'
          mtu: \(Self.mtu)
          multi-queue: false
          ipv4: '\(Self.ipv4Address)'
          ipv6: '\(Self.ipv6Address)'
          icmp: 'off'
        socks5:
          address: '127.0.0.1'
          port: \(socksPort)
          udp: 'udp'
          udp-address: '127.0.0.1'
          pipeline: false
        misc:
          max-session-count: 2048
          connect-timeout: 10000
          tcp-read-write-timeout: 300000
          udp-read-write-timeout: 60000
          log-file: stderr
          log-level: warn

        """.utf8)
    }
}
