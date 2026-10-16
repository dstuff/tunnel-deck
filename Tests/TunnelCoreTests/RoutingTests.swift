import XCTest
@testable import TunnelCore

final class RoutingTests: XCTestCase {
    func testDomainNormalizationAndBoundaries() throws {
        XCTAssertEqual(try RoutingMatch.domain("https://ExAmPlE.org/path?q=test"), "example.org")
        XCTAssertEqual(try RoutingMatch.domain("пример.рф"), "xn--e1afmkfd.xn--p1ai")
        for value in ["*.example.org", "bad example.org", "example.org/path", "-bad.example", "127.0.0.1", "https://user:pass@example.org"] {
            XCTAssertThrowsError(try RoutingMatch.domain(value), value)
        }
        var policy = RoutingPolicy()
        policy.rules = [.init(match: .init(type: .domainSuffix, value: "example.org"), action: .direct)]
        for host in ["example.org", "sub.example.org"] {
            XCTAssertEqual(try policy.decision(domain: host, addresses: [], country: { _ in nil }).action, .direct)
        }
        XCTAssertEqual(try policy.decision(domain: "otherexample.org", addresses: [], country: { _ in nil }).action, .vpn)
    }
    func testIPv4IPv6MasksAndNormalization() throws {
        XCTAssertEqual(try IPNetwork("10.20.35.40/16").cidr, "10.20.0.0/16")
        XCTAssertEqual(try IPNetwork("2001:db8:1::5/32").cidr, "2001:db8::/32")
        XCTAssertTrue(try IPNetwork("2001:db8::/32").contains("2001:db8:3::1"))
        XCTAssertFalse(try IPNetwork("2001:db8::/32").contains("2001:db9::1"))
        XCTAssertTrue(try IPNetwork("0.0.0.0/0").contains("203.0.113.1"))
        XCTAssertFalse(try IPNetwork("0.0.0.0/0").contains("::1"))
        for value in ["10.0.0.1/33", "::/129", "1.2.3.4/", "1.2.3.4/24/x", "host/32"] { XCTAssertThrowsError(try IPNetwork(value)) }
        XCTAssertEqual(try IPNetwork.prefixLength(netmask: "255.255.240.0"), 20)
        XCTAssertThrowsError(try IPNetwork.prefixLength(netmask: "255.0.255.0"))
    }
    func testFirstMatchAcrossDomainNetworkAndCountryAndDisabledRules() throws {
        var policy = RoutingPolicy()
        policy.rules = [
            .init(match: .init(type: .domain, value: "blocked.example"), action: .block),
            .init(match: .init(type: .ipCIDR, value: "10.0.0.0/8"), action: .vpn),
            .init(match: .init(type: .country, value: "RU"), action: .direct)
        ]
        let addresses = ["10.2.3.4"]
        XCTAssertEqual(try policy.decision(domain: "blocked.example", addresses: addresses, country: { _ in "RU" }).action, .block)
        XCTAssertEqual(try policy.decision(domain: "other.example", addresses: addresses, country: { _ in "RU" }).ruleIndex, 1)
        policy.rules[1].enabled = false
        let decision = try policy.decision(domain: "other.example", addresses: addresses, country: { _ in "RU" })
        XCTAssertEqual(decision.action, .direct); XCTAssertEqual(decision.matchedIP, addresses[0])
        let first = policy.rules.remove(at: 2); policy.rules.insert(first, at: 0)
        XCTAssertEqual(try policy.decision(domain: "blocked.example", addresses: addresses, country: { _ in "RU" }).action, .direct)
    }
    func testStandaloneFormatRoundTripAndStrictImport() throws {
        var policy = RoutingPolicy()
        policy.rules = [.init(match: .init(type: .country, value: "ru"), action: .direct)]
        let data = try policy.exportFile()
        XCTAssertEqual(try RoutingPolicy.importFile(data).rules[0].match.value, "RU")
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["password", "secrets", "outbounds", "file"] {
            var invalid = json; invalid[key] = "synthetic-unused"
            XCTAssertThrowsError(try RoutingPolicy.importFile(JSONSerialization.data(withJSONObject: invalid)))
        }
        json["version"] = 2
        XCTAssertThrowsError(try RoutingPolicy.importFile(JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try RoutingPolicy.importFile(Data(repeating: 32, count: RoutingPolicy.maximumFileSize + 1)))
        XCTAssertThrowsError(try RoutingPolicy.importFile(Data("{}".utf8)))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("profile")); XCTAssertFalse(text.contains("configuration"))
    }
    func testRejectsInvalidCountryDuplicateIDsAndRules() throws {
        var policy = RoutingPolicy()
        policy.rules = [.init(match: .init(type: .country, value: "ZZ"))]
        XCTAssertThrowsError(try policy.validated())
        policy.rules = [.init(match: .init(type: .country, value: "XK"))]
        XCTAssertNoThrow(try policy.validated())
        policy.rules.append(policy.rules[0]); XCTAssertThrowsError(try policy.validated())
        policy.rules = []; policy.defaultAction = .block; XCTAssertThrowsError(try policy.validated())
    }
    func testCompilerKeepsOrderedRulesAndReservesProbeAndDNS() throws {
        var policy = RoutingPolicy()
        policy.defaultAction = .direct
        policy.rules = [.init(match: .init(type: .country, value: "RU"), action: .block),
                        .init(match: .init(type: .domainSuffix, value: "example.org"), action: .vpn)]
        let data = try RoutingConfiguration.make(policy: policy, trafficPort: 20001, probePort: 20002, dnsPort: 20003,
                                                 physicalInterface: "en0", vpnInterface: "utun5", vpnDNS: ["10.0.0.1"])
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules[0]["outboundTag"] as? String, "td-vpn")
        XCTAssertEqual(rules[0]["inboundTag"] as? [String], ["td-probe"])
        let userRules = rules.filter { $0["ruleTag"] != nil }
        XCTAssertEqual(userRules[0]["ip"] as? [String], ["geoip:ru"])
        XCTAssertEqual(userRules[1]["domain"] as? [String], ["domain:example.org", "domain:example.org."])
        XCTAssertEqual(rules.last?["outboundTag"] as? String, "td-direct")
        let outbounds = json["outbounds"] as! [[String: Any]]
        let vpn = outbounds.first { $0["tag"] as? String == "td-vpn" }!
        XCTAssertEqual(((vpn["streamSettings"] as? [String: Any])?["sockopt"] as? [String: Any])?["interface"] as? String, "utun5")
        XCTAssertThrowsError(try RoutingConfiguration.make(policy: policy, trafficPort: 1, probePort: 1, dnsPort: 3, physicalInterface: "en0", vpnInterface: "utun5"))
    }
    func testNativeDomainResolutionUsesAssignedAddressFamilies() throws {
        // A capture/scoped IPv6 route is not evidence of a usable VPN IPv6 source.
        for (addresses, expected) in [
            (["10.9.0.2/24"], "ForceIPv4"),
            (["10.9.0.2/24", "fe80::1/64"], "ForceIPv4"),
            (["fd00:1234::2/64"], "ForceIPv6"),
            (["10.9.0.2/24", "fd00:1234::2/64"], "UseIP")
        ] {
            let data = try RoutingConfiguration.make(policy: .init(), trafficPort: 1, probePort: 2, dnsPort: 3,
                physicalInterface: "en0", vpnInterface: "utun9", vpnAddresses: addresses)
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let outbounds = json["outbounds"] as! [[String: Any]]
            let vpn = outbounds.first { $0["tag"] as? String == "td-vpn" }!
            XCTAssertEqual((vpn["settings"] as? [String: Any])?["domainStrategy"] as? String, expected)
            let direct = outbounds.first { $0["tag"] as? String == "td-direct" }!
            XCTAssertEqual((direct["settings"] as? [String: Any])?["domainStrategy"] as? String, "UseIP")
        }
    }
    func testXraySelectionAndChainsCannotRunImportedRouting() throws {
        let source = """
        {"outbounds":[
          {"tag":"first","protocol":"socks","settings":{"servers":[{"address":"first.example","port":1080}]}},
          {"tag":"chosen","protocol":"socks","settings":{"servers":[{"address":"selected.example","port":1080}]},"streamSettings":{"sockopt":{"dialerProxy":"exit"}}},
          {"tag":"exit","protocol":"freedom"}],
         "routing":{"rules":[{"outboundTag":"first"}]},"dns":{"servers":["192.0.2.1"]}}
        """
        let config = try XrayConfiguration(source)
        XCTAssertThrowsError(try config.selectedOutboundTag(nil))
        XCTAssertEqual(try config.endpointHosts(selected: "chosen"), ["selected.example"])
        let data = try RoutingConfiguration.make(policy: .init(), trafficPort: 1, probePort: 2, dnsPort: 3,
            physicalInterface: "en0", xray: config, selectedOutbound: "chosen", resolvedHosts: ["selected.example":"192.0.2.2"])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("first.example")); XCTAssertFalse(text.contains("192.0.2.1"))
        XCTAssertTrue(text.contains("192.0.2.2")); XCTAssertTrue(text.contains("td-vpn"))
        let cyclic = try XrayConfiguration("""
        {"outbounds":[{"tag":"x","protocol":"socks","settings":{"servers":[{"address":"example.org","port":1}]},"proxySettings":{"tag":"x"}}]}
        """)
        XCTAssertThrowsError(try cyclic.routedOutbounds(selected: nil, physicalInterface: "en0", resolvedHosts: [:]))
    }
    func testSystemProbeUsesReservedPathBeforeUserRules() throws {
        var policy = RoutingPolicy()
        policy.defaultAction = .direct
        policy.rules = [.init(match: .init(type: .ipCIDR, value: "0.0.0.0/0"), action: .block)]
        let data = try RoutingConfiguration.make(policy: policy, trafficPort: 10001, probePort: 10002, dnsPort: 10003,
            physicalInterface: "en0", vpnInterface: "utun9", systemProbePort: 10004)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let rules = (json["routing"] as! [String: Any])["rules"] as! [[String: Any]]
        XCTAssertEqual(rules[0]["inboundTag"] as? [String], ["td-system-probe"])
        XCTAssertEqual(rules[0]["outboundTag"] as? String, "td-vpn")
        XCTAssertEqual(rules[1]["ip"] as? [String], ["198.18.0.3/32"])
        XCTAssertEqual(rules[1]["outboundTag"] as? String, "td-probe-bridge")
        XCTAssertTrue(rules.dropFirst(2).contains { $0["outboundTag"] as? String == "td-block" })
    }
    func testRequestLimitIncludesRoutingAndJSONEscaping() throws {
        let session = try PrivateSession(); defer { session.remove() }
        var secrets = ProfileSecrets(); secrets.configuration = String(repeating: "\u{0001}", count: 90_000)
        let request = TunnelRequest(userID: 501, parentPID: 10, profile: VPNProfile(), secrets: secrets)
        XCTAssertThrowsError(try session.save(request))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.requestFile.path))
    }
    func testShippedExampleAndRuntimeInfoSurviveRoundTrips() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let example = try RoutingPolicy.importFile(Data(contentsOf: root.appendingPathComponent("docs/examples/sites-and-countries.tunneldeck-routing")))
        XCTAssertEqual(example.rules.count, 3)
        XCTAssertEqual(try RoutingPolicy.importFile(example.exportFile()), example)
        let session = try PrivateSession(); defer { session.remove() }
        let handle = try FileHandle(forUpdating: session.eventFile); defer { try? handle.close() }
        let writer = try SessionEventLog.Writer(fileDescriptor: handle.fileDescriptor, maximumBytes: 4096)
        let info = RoutingRuntimeInfo(probePort: 12001, dnsPort: 12002)
        try writer.append(.init(.routingReady, "Synthetic router ready", routing: info))
        for _ in 0..<100 { try writer.append(.init(.log, String(repeating: "fixture", count: 50))) }
        let reader = try SessionEventLog.Reader(file: session.eventFile)
        XCTAssertEqual(try reader.readAvailable().first(where: { $0.kind == .routingReady })?.routing, info)
    }
    func testCountryIndexBoundsIPv4AndIPv6() throws {
        var data = Data("TDGEO0012026-10\0".utf8)
        data.append(contentsOf: [0,0,0,1,0,0,0,1])
        data.append(contentsOf: [10,0,0,0,10,0,0,255]); data.append(Data("RU".utf8))
        data.append(contentsOf: IPNetwork.address("2001:db8::")!); data.append(contentsOf: IPNetwork.address("2001:db8::ffff")!); data.append(Data("US".utf8))
        let db = try CountryDatabase(data: data)
        XCTAssertEqual(db.country(for: "10.0.0.0"), "RU"); XCTAssertEqual(db.country(for: "10.0.0.255"), "RU")
        XCTAssertNil(db.country(for: "10.0.1.0")); XCTAssertEqual(db.country(for: "2001:db8::ab"), "US")
        XCTAssertNil(db.country(for: "2001:db9::1")); XCTAssertThrowsError(try CountryDatabase(data: data.dropLast()))
    }
    func testOpenConnectMetadataNeverImportsCommandsAndKeepsSplitCoverage() throws {
        var env = ["reason":"connect", "TUNDEV":"utun7", "INTERNAL_IP4_ADDRESS":"10.7.0.2",
                   "INTERNAL_IP4_NETMASK":"255.255.255.0", "INTERNAL_IP4_DNS":"10.7.0.1", "VPNGATEWAY":"192.0.2.1",
                   "CISCO_SPLIT_INC":"1", "CISCO_SPLIT_INC_0_ADDR":"10.20.0.0", "CISCO_SPLIT_INC_0_MASKLEN":"16",
                   "CISCO_SPLIT_EXC":"1", "CISCO_SPLIT_EXC_0_ADDR":"10.20.5.0", "CISCO_SPLIT_EXC_0_MASKLEN":"24",
                   "CISCO_PROXY_PAC":"untrusted-unused-value"]
        let network = try OpenConnectNetworkSettings(environment: env)
        XCTAssertEqual(network.routes, ["10.20.0.0/16"]); XCTAssertEqual(network.excludedRoutes, ["10.20.5.0/24"])
        XCTAssertEqual(network.addresses, ["10.7.0.2/24"])
        env["TUNDEV"] = "utun7; unexpected-command"; XCTAssertThrowsError(try OpenConnectNetworkSettings(environment: env))
        env["TUNDEV"] = "utun7"; env["CISCO_SPLIT_INC"] = "10000"; XCTAssertThrowsError(try OpenConnectNetworkSettings(environment: env))
    }
}
