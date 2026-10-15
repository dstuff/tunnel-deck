import XCTest
@testable import TunnelCore

final class SocksTunnelConfigurationTests: XCTestCase {
    func testGeneratedBridgeUsesLoopbackUDPAndMatchingTunnelAddresses() throws {
        let config = try SocksTunnelConfiguration(interface: "utun500", socksPort: 49152)
        let yaml = String(decoding: config.data, as: UTF8.self)
        XCTAssertTrue(yaml.contains("name: 'utun500'\n"))
        XCTAssertTrue(yaml.contains("mtu: 4064\n"))
        XCTAssertTrue(yaml.contains("ipv4: '198.18.0.1'\n"))
        XCTAssertTrue(yaml.contains("ipv6: 'fd00:1234:ffff::10'\n"))
        XCTAssertTrue(yaml.contains("address: '127.0.0.1'\n"))
        XCTAssertTrue(yaml.contains("port: 49152\n"))
        XCTAssertTrue(yaml.contains("udp: 'udp'\n"))
        XCTAssertTrue(yaml.contains("udp-address: '127.0.0.1'\n"))
        XCTAssertFalse(yaml.contains("mapdns"))
        XCTAssertFalse(yaml.contains("script"))
        XCTAssertFalse(yaml.contains("pid-file"))
        XCTAssertEqual(SocksTunnelConfiguration.addresses, ["198.18.0.1/24", "fd00:1234:ffff::10/64"])
        XCTAssertEqual(SocksTunnelConfiguration.dns, ["1.1.1.1", "8.8.8.8"])
    }

    func testRootRunConfigurationRejectsInterfaceAndYAMLInjection() {
        for interface in ["utun", "en0", "utun500\npost-up-script: /tmp/run", "utun500\n", "utun500\r", "utun500'", "utun-1", "utun12345"] {
            XCTAssertThrowsError(try SocksTunnelConfiguration(interface: interface, socksPort: 1080))
        }
        XCTAssertThrowsError(try SocksTunnelConfiguration(interface: "utun500", socksPort: 0))
    }

    func testXrayRuntimeRequiresBothProtocolEngineAndPacketBridge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("tunneldeck-runtime-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("xray"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("bin"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = RuntimePaths(root: root)
        try Data().write(to: URL(fileURLWithPath: paths.xray))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.xray)
        XCTAssertThrowsError(try paths.check(.xray))
        try Data().write(to: URL(fileURLWithPath: paths.socksTunnel))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.socksTunnel)
        XCTAssertThrowsError(try paths.check(.xray))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.socksTunnel)
        XCTAssertNoThrow(try paths.check(.xray))
    }
}
