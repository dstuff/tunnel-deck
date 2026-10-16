import XCTest
@testable import TunnelCore

final class ConfigurationTests: XCTestCase {
    func testCamouflageSurvivesInitialURLAndDoesNotBecomeAuthGroup() throws {
        let p = VPNProfile(server: "https://vpn.example:443/login?opaque%2Fsecret", username: "vpn", authGroup: "staff")
        let config = try OpenConnectConfiguration.make(profile: p, secrets: ProfileSecrets())
        XCTAssertTrue(config.contains("server=https://vpn.example:443/login?opaque%2Fsecret\n"))
        XCTAssertTrue(config.contains("authgroup=staff\n"))
        XCTAssertFalse(config.contains("passwd"))
        let e = try VPNEndpoint(server: p.server)
        XCTAssertEqual(e.baseURL, "https://vpn.example:443/login")
        XCTAssertEqual(e.secret, "opaque%2Fsecret")
    }
    func testConflictingSecretsAndConfigurationInjectionAreRejected() {
        XCTAssertThrowsError(try VPNEndpoint(server: "https://vpn.example/?one", camouflage: "two"))
        XCTAssertThrowsError(try VPNEndpoint(server: "https://vpn.example/", camouflage: "bad\nscript=/tmp/evil"))
        XCTAssertThrowsError(try VPNEndpoint(server: "http://vpn.example/"))
        var profile = VPNProfile(server: "https://vpn.example/", username: "vpn\nscript=/tmp/evil")
        XCTAssertThrowsError(try OpenConnectConfiguration.make(profile: profile, secrets: ProfileSecrets()))
        profile.username = "vpn"; profile.certificatePin = "anything"
        XCTAssertThrowsError(try OpenConnectConfiguration.make(profile: profile, secrets: ProfileSecrets()))
    }
    private var awg: String {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        return """
        [Interface]
        PrivateKey = \(key)
        Address = 10.9.0.2/32
        DNS = 1.1.1.1
        HeaderProtectionKey = \(key)
        S1 = 12
        S2 = 13
        S3 = 14
        S4 = 15
        ContentPaddingAddition = 32-128
        RekeyAfterTime = 100-130
        I1 = <r 10>
        I3 = <rc 20>
        [Peer]
        PublicKey = \(key)
        Endpoint = vpn.example:51820
        AllowedIPs = 0.0.0.0/0, ::/0
        PersistentKeepalive = 22-30
        """
    }
    func testAWG31PreservesRangesAndNoncontiguousSignaturePackets() throws {
        let config = try AmneziaConfiguration(awg)
        XCTAssertTrue(config.deviceConfiguration.contains("PersistentKeepalive = 22-30"))
        XCTAssertTrue(config.deviceConfiguration.contains("I3 = <rc 20>"))
        XCTAssertTrue(config.deviceConfiguration.contains("ContentPaddingAddition = 32-128"))
        XCTAssertFalse(config.deviceConfiguration.contains("Address ="))
        XCTAssertEqual(config.addresses, ["10.9.0.2/32"])
        XCTAssertEqual(config.allowedIPs, ["0.0.0.0/0", "::/0"])
    }
    func testAWGDoesNotExecuteImportedHooksOrAcceptBadCryptoPadding() {
        XCTAssertThrowsError(try AmneziaConfiguration(awg.replacingOccurrences(of: "Address =", with: "PostUp = /bin/echo injected\nAddress =")))
        XCTAssertThrowsError(try AmneziaConfiguration(awg.replacingOccurrences(of: "S1 = 12", with: "S1 = 11")))
        XCTAssertThrowsError(try AmneziaConfiguration(awg.replacingOccurrences(of: "DNS = 1.1.1.1", with: "DNS = not-an-ip")))
    }
    func testVLESSRealityImportAndBootstrapResolutionKeepSNI() throws {
        let link = "vless://28e21f5c-8e82-44a4-bb91-89e412af903b@vpn.example:443?security=reality&pbk=YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE&sid=abcd&sni=cover.example&type=tcp&flow=xtls-rprx-vision#My%20server"
        let config = try XrayConfiguration(link)
        let data = try config.data(tunnelInterface: "utun500", physicalInterface: "en0", resolvedHosts: ["vpn.example": "192.0.2.5"])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let out = try XCTUnwrap((object["outbounds"] as? [[String: Any]])?.first)
        let stream = try XCTUnwrap(out["streamSettings"] as? [String: Any])
        XCTAssertEqual((stream["realitySettings"] as? [String: Any])?["serverName"] as? String, "cover.example")
        XCTAssertNil((stream["sockopt"] as? [String: Any])?["interface"])
        let settings = try XCTUnwrap(out["settings"] as? [String: Any])
        XCTAssertEqual((settings["vnext"] as? [[String: Any]])?.first?["address"] as? String, "192.0.2.5")
        XCTAssertEqual(config.displayName, "My server")
        XCTAssertEqual(config.endpointHosts, ["vpn.example"])
    }
    func testXrayImportedListenersAndLogFilesAreNotRunAsRoot() throws {
        let input = #"{"log":{"error":"/root/overwrite"},"api":{"tag":"api"},"inbounds":[{"port":80,"listen":"0.0.0.0","protocol":"http"}],"outbounds":[{"protocol":"freedom","tag":"direct"}]}"#
        let config = try XrayConfiguration(input)
        let result = String(decoding: try config.data(), as: UTF8.self)
        XCTAssertFalse(result.contains("/root/overwrite"))
        XCTAssertFalse(result.contains("0.0.0.0"))
        XCTAssertFalse(result.contains("api"))
        XCTAssertThrowsError(try XrayConfiguration(#"{"outbounds":[{"protocol":"trojan","streamSettings":{"tlsSettings":{"keyFile":"/root/key"}}}]}"#))
    }
    func testXrayBypassIncludesLiteralIPv4AndIPv6WithoutDNSResolution() throws {
        let config = try XrayConfiguration(#"{"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"192.0.2.5","port":443},{"address":"2001:db8::5","port":443}]}}]}"#)
        XCTAssertEqual(config.endpointRouteAddresses(resolvedHosts: [:]), ["192.0.2.5", "2001:db8::5"])
    }
    func testXrayBypassCoversAllServerAddressesInGeneratedConfiguration() throws {
        let config = try XrayConfiguration(#"{"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"192.0.2.5","port":443}]}},{"protocol":"trojan","settings":{"servers":[{"address":"vpn.example","port":443},{"address":"2001:db8::5","port":443}]}},{"protocol":"freedom"}]}"#)
        let resolved = ["vpn.example": "192.0.2.6", "unrelated.example": "192.0.2.99"]
        let bypass = config.endpointRouteAddresses(resolvedHosts: resolved)
        XCTAssertEqual(bypass, ["192.0.2.5", "192.0.2.6", "2001:db8::5"])

        let data = try config.data(tunnelInterface: "utun500", physicalInterface: "en0", resolvedHosts: resolved)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let outbounds = try XCTUnwrap(object["outbounds"] as? [[String: Any]])
        for outbound in outbounds {
            let settings = outbound["settings"] as? [String: Any] ?? [:]
            for key in ["vnext", "servers"] {
                for server in settings[key] as? [[String: Any]] ?? [] {
                    let address = try XCTUnwrap(server["address"] as? String)
                    XCTAssertTrue(bypass.contains(address), "Missing tunnel bypass for \(address)")
                }
            }
        }
    }
    func testXrayKeepsExplicitSocketOptionsAndProtectsDirectOutbound() throws {
        let config = try XrayConfiguration(#"{"outbounds":[{"protocol":"vless","settings":{"vnext":[{"address":"vpn.example","port":443}]},"streamSettings":{"sockopt":{"interface":"en9","tcpKeepAliveIdle":45}}},{"protocol":"freedom","tag":"direct"}]}"#)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: config.data(
            tunnelInterface: "utun500", physicalInterface: "en0", resolvedHosts: ["vpn.example": "192.0.2.5"])) as? [String: Any])
        let outbounds = try XCTUnwrap(result["outbounds"] as? [[String: Any]])
        let proxy = try XCTUnwrap(outbounds[0]["streamSettings"] as? [String: Any])
        let proxySocket = try XCTUnwrap(proxy["sockopt"] as? [String: Any])
        XCTAssertEqual(proxySocket["interface"] as? String, "en9")
        XCTAssertEqual(proxySocket["tcpKeepAliveIdle"] as? Int, 45)
        XCTAssertEqual(config.endpointRouteAddresses(resolvedHosts: ["vpn.example": "192.0.2.5"]), ["192.0.2.5"])
        let direct = try XCTUnwrap(outbounds[1]["streamSettings"] as? [String: Any])
        XCTAssertEqual((direct["sockopt"] as? [String: Any])?["interface"] as? String, "en0")
    }
    func testXrayProbeOnlyListensOnLoopbackAndKeepsRoutingRules() throws {
        let config = try XrayConfiguration(#"{"inbounds":[{"listen":"0.0.0.0","port":80,"protocol":"http"}],"outbounds":[{"protocol":"freedom","tag":"direct"}],"routing":{"rules":[{"type":"field","inboundTag":["tunneldeck"],"outboundTag":"direct"}]}}"#)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: config.probeData(port: 49152)) as? [String: Any])
        let inbounds = try XCTUnwrap(result["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(inbounds[0]["port"] as? Int, 49152)
        XCTAssertEqual(inbounds[0]["protocol"] as? String, "socks")
        XCTAssertEqual(inbounds[0]["tag"] as? String, "tunneldeck")
        XCTAssertNotNil(result["routing"])
        let combined = try XCTUnwrap(JSONSerialization.jsonObject(with: config.data(tunnelInterface: "utun500", probePort: 49152)) as? [String: Any])
        let listeners = try XCTUnwrap(combined["inbounds"] as? [[String: Any]])
        let tags = listeners.compactMap { $0["tag"] as? String }
        XCTAssertEqual(tags.count, Set(tags).count)
        XCTAssertEqual(tags, ["tunneldeck", "tunneldeck-probe"])
        let routing = try XCTUnwrap(combined["routing"] as? [String: Any])
        let rules = try XCTUnwrap(routing["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["inboundTag"] as? [String], tags)
    }
    func testRealityVisionUsesVerifiedCompatibilityProfileAndKeepsExplicitPresets() throws {
        func fingerprint(flow: String, preset: String, physical: String? = nil) throws -> String? {
            let input: [String: Any] = ["outbounds": [["protocol": "vless",
                "settings": ["vnext": [["address": "192.0.2.5", "port": 443, "users": [["id": "example", "flow": flow]]]]],
                "streamSettings": ["security": "reality", "realitySettings": ["fingerprint": preset, "serverName": "cover.example"]]]]]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
            let config = try XrayConfiguration(text)
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: config.data(physicalInterface: physical)) as? [String: Any])
            let outbound = try XCTUnwrap((result["outbounds"] as? [[String: Any]])?.first)
            let stream = try XCTUnwrap(outbound["streamSettings"] as? [String: Any])
            return (stream["realitySettings"] as? [String: Any])?["fingerprint"] as? String
        }
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "chrome"), "tunneldeck_safari15_5")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "chrome", physical: "en0"), "tunneldeck_safari15_5")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: ""), "tunneldeck_safari15_5")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "safari"), "tunneldeck_safari15_5")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "safari15_5"), "tunneldeck_safari15_5")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "tunneldeck_safari15_5"), "tunneldeck_safari15_5")
        XCTAssertEqual(try fingerprint(flow: "", preset: "chrome"), "chrome")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "hellochrome_131"), "hellochrome_131")
        XCTAssertEqual(try fingerprint(flow: "xtls-rprx-vision", preset: "firefox"), "firefox")
    }
    func testSystemProxyProvidesLoopbackTCPAndUDPInsteadOfNativeTun() throws {
        let config = try XrayConfiguration(#"{"outbounds":[{"protocol":"freedom","tag":"direct"}]}"#)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: config.proxyData(port: 49152, physicalInterface: "en0", resolvedHosts: [:])) as? [String: Any])
        let inbounds = try XCTUnwrap(object["inbounds"] as? [[String: Any]])
        XCTAssertEqual(inbounds.count, 1)
        XCTAssertEqual(inbounds[0]["protocol"] as? String, "socks")
        XCTAssertEqual(inbounds[0]["listen"] as? String, "127.0.0.1")
        let settings = try XCTUnwrap(inbounds[0]["settings"] as? [String: Any])
        XCTAssertEqual(settings["udp"] as? Bool, true)
        XCTAssertEqual(settings["ip"] as? String, "127.0.0.1")
    }
    func testCredentialsNeverAppearInDiagnosticLog() throws {
        var secrets = ProfileSecrets()
        secrets.password = "vpn-password-example"; secrets.camouflage = "camouflage-example"
        secrets.configuration = #"{"outbounds":[{"protocol":"trojan","settings":{"servers":[{"address":"vpn.example","port":443,"password":"xray-secret-example"}]}}]}"#
        let request = TunnelRequest(userID: 501, parentPID: 123, profile: VPNProfile(server: "https://vpn.example/"), secrets: secrets, cookie: "cookie-example")
        let redactor = LogRedactor(request: request)
        let log = redactor.redact("password=vpn-password-example\nPOST https://vpn.example/?camouflage-example\nCookie: cookie-example\nTrojan password invalid: xray-secret-example")
        for value in ["vpn-password-example", "camouflage-example", "cookie-example", "xray-secret-example"] { XCTAssertFalse(log.contains(value)) }
    }
}
