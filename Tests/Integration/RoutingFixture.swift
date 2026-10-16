// Compiled by routing_smoke.py against the application's real TunnelCore objects.
import Foundation
import TunnelCore

let args = CommandLine.arguments
guard args.count == 9, let traffic = UInt16(args[2]), let probe = UInt16(args[3]),
      let dns = UInt16(args[4]), let relay = UInt16(args[5]), let systemProbe = UInt16(args[8]) else { fatalError("Invalid fixture arguments") }
var policy = RoutingPolicy()
policy.rules = [
    .init(match: .init(type: .domain, value: "blocked.example"), action: .block),
    .init(match: .init(type: .domain, value: "vpn.example"), action: .vpn),
    .init(match: .init(type: .domain, value: "direct.example"), action: .direct),
    .init(match: .init(type: .ipCIDR, value: "::1/128"), action: .direct)
]
if args[7] == "country" { policy.rules.append(.init(match: .init(type: .country, value: "RU"), action: .direct)) }
if args[7] == "direct-default" { policy.defaultAction = .direct }
let native = args[6] == "native"
let xray = try XrayConfiguration("""
{"outbounds":[{"protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":\(relay)}]}}]}
""")
let data = try RoutingConfiguration.make(policy: policy, trafficPort: traffic, probePort: probe, dnsPort: dns,
    physicalInterface: "lo0", vpnInterface: native ? "lo0" : nil, vpnDNS: ["127.0.0.1"], directDNS: ["127.0.0.1"],
    vpnAddresses: native ? ["127.0.0.1/8"] : nil, xray: native ? nil : xray, systemProbePort: systemProbe)
try data.write(to: URL(fileURLWithPath: args[1]))
